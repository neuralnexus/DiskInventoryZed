[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime,

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$OutputDirectory = "artifacts/windows"
)

$ErrorActionPreference = "Stop"
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repositoryRoot = (Resolve-Path (Join-Path $windowsRoot "..")).Path
$project = Join-Path $windowsRoot "src/DiskInventoryZed.Windows/DiskInventoryZed.Windows.csproj"
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory, $repositoryRoot)
$expectedSdk = (Get-Content (Join-Path $repositoryRoot "global.json") | ConvertFrom-Json).sdk.version
$actualSdk = (& dotnet --version)
if ($LASTEXITCODE -ne 0 -or $actualSdk -ne $expectedSdk) {
    throw "Packaging requires .NET SDK $expectedSdk, but dotnet reported '$actualSdk'."
}

[xml]$projectDocument = Get-Content $project
$version = ($projectDocument.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1)
if (-not $version) {
    throw "The Windows project does not define a Version property."
}
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "The Windows project Version must use major.minor.patch format; found '$version'."
}

$artifactName = "DiskInventoryZed-Windows-v$version-$Runtime"
$publishDirectory = Join-Path $outputRoot $artifactName
$archivePath = Join-Path $outputRoot "$artifactName.zip"

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
if (Test-Path $publishDirectory) {
    Remove-Item $publishDirectory -Recurse -Force
}
if (Test-Path $archivePath) {
    Remove-Item $archivePath -Force
}

dotnet restore $project --locked-mode
if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore failed or the dependency lock is stale."
}

dotnet publish $project `
    --configuration $Configuration `
    --runtime $Runtime `
    --self-contained true `
    --no-restore `
    --output $publishDirectory `
    -p:PublishSingleFile=false `
    -p:PublishTrimmed=false `
    -p:DebugType=None `
    -p:DebugSymbols=false
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed for $Runtime."
}

$executable = Join-Path $publishDirectory "DiskInventoryZed.exe"
if (-not (Test-Path $executable)) {
    throw "The published application does not contain DiskInventoryZed.exe."
}

$licensePath = Join-Path $repositoryRoot "LICENSE"
if (-not (Select-String -Path $licensePath -SimpleMatch "TERMS AND CONDITIONS" -Quiet)) {
    throw "LICENSE does not contain the full GPL terms."
}
Copy-Item $licensePath (Join-Path $publishDirectory "LICENSE.txt")
Copy-Item (Join-Path $windowsRoot "README.md") (Join-Path $publishDirectory "README-Windows.md")
$dotnetDirectory = Split-Path (Get-Command dotnet).Source
$dotnetLicense = Join-Path $dotnetDirectory "LICENSE.txt"
$dotnetNotices = Join-Path $dotnetDirectory "ThirdPartyNotices.txt"
if (-not (Test-Path $dotnetLicense) -or -not (Test-Path $dotnetNotices)) {
    throw "The .NET SDK license and third-party notices could not be located next to the dotnet host."
}
Copy-Item $dotnetLicense (Join-Path $publishDirectory "DOTNET-LICENSE.txt")
Copy-Item $dotnetNotices (Join-Path $publishDirectory "DOTNET-THIRD-PARTY-NOTICES.txt")
Compress-Archive -Path (Join-Path $publishDirectory "*") -DestinationPath $archivePath -CompressionLevel Optimal

$verificationDirectory = Join-Path $outputRoot ".$artifactName.verify"
if (Test-Path $verificationDirectory) {
    Remove-Item $verificationDirectory -Recurse -Force
}
try {
    Expand-Archive -Path $archivePath -DestinationPath $verificationDirectory
    @(
        "DiskInventoryZed.exe",
        "LICENSE.txt",
        "README-Windows.md",
        "DOTNET-LICENSE.txt",
        "DOTNET-THIRD-PARTY-NOTICES.txt"
    ) | ForEach-Object {
        $requiredPath = Join-Path $verificationDirectory $_
        if (-not (Test-Path $requiredPath) -or (Get-Item $requiredPath).Length -eq 0) {
            throw "The package is missing required non-empty file: $_"
        }
    }
}
finally {
    if (Test-Path $verificationDirectory) {
        Remove-Item $verificationDirectory -Recurse -Force
    }
}

Write-Output $archivePath
