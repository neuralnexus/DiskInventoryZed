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

[xml]$projectDocument = Get-Content $project
$version = ($projectDocument.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1)
if (-not $version) {
    throw "The Windows project does not define a Version property."
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

dotnet publish $project `
    --configuration $Configuration `
    --runtime $Runtime `
    --self-contained true `
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

Copy-Item (Join-Path $repositoryRoot "LICENSE") (Join-Path $publishDirectory "LICENSE.txt")
Copy-Item (Join-Path $windowsRoot "README.md") (Join-Path $publishDirectory "README-Windows.md")
Compress-Archive -Path (Join-Path $publishDirectory "*") -DestinationPath $archivePath -CompressionLevel Optimal

Write-Output $archivePath
