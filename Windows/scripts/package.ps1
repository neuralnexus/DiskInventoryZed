[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime,

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$OutputDirectory = "artifacts/windows",

    [ValidateSet("Unsigned", "Test", "Release")]
    [string]$SignaturePolicy = "Unsigned",

    [string]$CertificateThumbprint,

    [string]$ExpectedPublisherSubject,

    [string]$TimestampUrl
)

$ErrorActionPreference = "Stop"
$script:SignToolPath = $null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-PeDetails {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $headers = $reader.PEHeaders
        $corHeader = $headers.CorHeader
        $corFlags = if ($null -eq $corHeader) { 0 } else { [int]$corHeader.Flags }
        $hasManagedNativeHeader = $null -ne $corHeader -and $corHeader.ManagedNativeHeaderDirectory.Size -ne 0
        return [pscustomobject]@{
            Machine = [int]$headers.CoffHeader.Machine
            IsManaged = $null -ne $corHeader
            IsIlOnly = ($corFlags -band 0x00000001) -ne 0
            Requires32Bit = ($corFlags -band 0x00000002) -ne 0
            HasManagedNativeHeader = $hasManagedNativeHeader
            HasEmbeddedSignature = $null -ne $headers.PEHeader -and
                $headers.PEHeader.CertificateTableDirectory.Size -gt 0
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-SignTool {
    if ($null -ne $script:SignToolPath) {
        return $script:SignToolPath
    }

    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $script:SignToolPath = $command.Source
        return $script:SignToolPath
    }

    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits/10/bin"
    if (Test-Path $kitsRoot) {
        $candidate = Get-ChildItem $kitsRoot -Filter signtool.exe -File -Recurse |
            Where-Object { $_.FullName -match '[\\/]x64[\\/]signtool\.exe$' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($null -ne $candidate) {
            $script:SignToolPath = $candidate.FullName
            return $script:SignToolPath
        }
    }

    throw "SignTool could not be located in PATH or the Windows SDK."
}

function Get-SigningCertificate {
    param(
        [Parameter(Mandatory = $true)][string]$Thumbprint,
        [Parameter(Mandatory = $true)][string]$PublisherSubject,
        [Parameter(Mandatory = $true)][string]$Policy
    )

    if (-not $IsWindows) {
        throw "$Policy signing requires Windows."
    }
    $normalizedThumbprint = $Thumbprint.Replace(" ", "").ToUpperInvariant()
    if ($normalizedThumbprint -notmatch '^[0-9A-F]{40,64}$') {
        throw "The signing certificate thumbprint is invalid."
    }

    $certificate = Get-Item "Cert:/CurrentUser/My/$normalizedThumbprint" -ErrorAction SilentlyContinue
    if ($null -eq $certificate -or -not $certificate.HasPrivateKey) {
        throw "The signing certificate was not found with an accessible private key."
    }
    if ($certificate.Subject -cne $PublisherSubject) {
        throw "The signing certificate subject '$($certificate.Subject)' does not equal '$PublisherSubject'."
    }
    if ($certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
        $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) {
        throw "The signing certificate is not currently valid."
    }

    $ekuExtension = $certificate.Extensions |
        Where-Object { $_.Oid.Value -eq '2.5.29.37' } |
        Select-Object -First 1
    if ($null -eq $ekuExtension) {
        throw "The signing certificate does not contain an enhanced key usage extension."
    }
    $enhancedKeyUsage = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
        $ekuExtension.RawData,
        $ekuExtension.Critical)
    if (-not ($enhancedKeyUsage.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' })) {
        throw "The signing certificate is not authorized for code signing."
    }

    if ($Policy -eq "Release") {
        $timestampUri = $null
        if (-not [Uri]::TryCreate($TimestampUrl, [UriKind]::Absolute, [ref]$timestampUri) -or
            $timestampUri.Scheme -cne "https") {
            throw "Release signing requires an absolute HTTPS RFC 3161 timestamp URL."
        }
    }

    return $certificate
}

function Set-FirstPartySignatures {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$Policy,
        [Parameter(Mandatory = $true)]$Certificate
    )

    $signTool = Get-SignTool
    foreach ($name in @("DiskInventoryZed.exe", "DiskInventoryZed.dll", "DiskInventoryZed.Core.dll")) {
        $path = Join-Path $PackageRoot $name
        $arguments = @("sign", "/sha1", $Certificate.Thumbprint, "/fd", "SHA256")
        if ($Policy -eq "Release") {
            $arguments += @("/tr", $TimestampUrl, "/td", "SHA256")
        }
        $arguments += $path
        & $signTool @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Authenticode signing failed for $name."
        }
    }
}

function Assert-AuthenticodeSignature {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Policy,
        [string]$Thumbprint,
        [string]$PublisherSubject
    )

    $signTool = Get-SignTool
    & $signTool verify /pa /all $Path | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "$(Split-Path $Path -Leaf) failed embedded Authenticode verification."
    }

    $signature = Get-AuthenticodeSignature $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "$(Split-Path $Path -Leaf) has invalid Authenticode status $($signature.Status)."
    }
    if ($Thumbprint -and $signature.SignerCertificate.Thumbprint -cne $Thumbprint) {
        throw "$(Split-Path $Path -Leaf) was signed by an unexpected certificate."
    }
    if ($PublisherSubject -and $signature.SignerCertificate.Subject -cne $PublisherSubject) {
        throw "$(Split-Path $Path -Leaf) was signed by an unexpected publisher."
    }
    if ($Policy -eq "Release" -and $null -eq $signature.TimeStamperCertificate) {
        throw "$(Split-Path $Path -Leaf) does not contain a trusted timestamp."
    }
}

function Assert-PePayload {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][int]$ExpectedMachine,
        [Parameter(Mandatory = $true)][string]$Policy,
        [string]$Thumbprint,
        [string]$PublisherSubject
    )

    $firstPartyNames = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@("DiskInventoryZed.exe", "DiskInventoryZed.dll", "DiskInventoryZed.Core.dll"),
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($file in Get-ChildItem $PackageRoot -File -Recurse | Where-Object { $_.Extension -in @(".exe", ".dll") }) {
        $details = Get-PeDetails $file.FullName
        $isAnyCpu = $details.Machine -eq 0x014c -and
            $details.IsManaged -and
            $details.IsIlOnly -and
            -not $details.Requires32Bit -and
            -not $details.HasManagedNativeHeader
        if ($details.Machine -ne $ExpectedMachine -and -not $isAnyCpu) {
            throw "$($file.Name) has PE machine 0x$($details.Machine.ToString('x4')); expected native machine 0x$($ExpectedMachine.ToString('x4')) or IL-only AnyCPU."
        }

        if ($Policy -ne "Unsigned") {
            if (-not $details.HasEmbeddedSignature) {
                throw "$($file.Name) does not contain a portable embedded Authenticode signature."
            }
            if ($firstPartyNames.Contains($file.Name)) {
                Assert-AuthenticodeSignature $file.FullName $Policy $Thumbprint $PublisherSubject
            }
            else {
                Assert-AuthenticodeSignature $file.FullName $Policy
                $signature = Get-AuthenticodeSignature $file.FullName
                if ($signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
                    throw "$($file.Name) has an unexpected third-party Authenticode publisher."
                }
            }
        }
    }
}

function Assert-FirstPartyVersions {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $expectedFileVersion = "$Version.0"
    if ($IsWindows) {
        foreach ($name in @("DiskInventoryZed.exe", "DiskInventoryZed.dll", "DiskInventoryZed.Core.dll")) {
            $path = Join-Path $PackageRoot $name
            $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            if ($versionInfo.FileVersion -cne $expectedFileVersion) {
                throw "$name has file version '$($versionInfo.FileVersion)'; expected '$expectedFileVersion'."
            }
            $productVersion = [string]$versionInfo.ProductVersion
            if ($productVersion -cne $Version -and
                -not $productVersion.StartsWith("$Version+", [StringComparison]::Ordinal)) {
                throw "$name has product version '$productVersion'; expected '$Version'."
            }
        }
    }

    foreach ($name in @("DiskInventoryZed.dll", "DiskInventoryZed.Core.dll")) {
        $assemblyVersion = [Reflection.AssemblyName]::GetAssemblyName(
            (Join-Path $PackageRoot $name)).Version.ToString()
        if ($assemblyVersion -cne $expectedFileVersion) {
            throw "$name has assembly version '$assemblyVersion'; expected '$expectedFileVersion'."
        }
    }
}

function Write-PackageManifest {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $manifestPath = Join-Path $PackageRoot "PACKAGE-MANIFEST.sha256"
    $relativePaths = [string[]]@(Get-ChildItem $PackageRoot -File -Recurse |
        Where-Object { $_.FullName -cne $manifestPath } |
        ForEach-Object { [IO.Path]::GetRelativePath($PackageRoot, $_.FullName).Replace('\', '/') })
    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    $lines = foreach ($relativePath in $relativePaths) {
        if ($relativePath.Contains("`n") -or $relativePath.Contains("`r")) {
            throw "Package paths cannot contain line breaks."
        }
        $hash = (Get-FileHash (Join-Path $PackageRoot $relativePath) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $relativePath"
    }
    [IO.File]::WriteAllLines($manifestPath, $lines, [Text.UTF8Encoding]::new($false))
}

function Assert-PackageManifest {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $manifestPath = Join-Path $PackageRoot "PACKAGE-MANIFEST.sha256"
    $expected = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($line in [IO.File]::ReadAllLines($manifestPath)) {
        if ($line -notmatch '^([0-9a-f]{64})  ([^\r\n]+)$') {
            throw "The package manifest contains an invalid line."
        }
        if (-not $expected.TryAdd($Matches[2], $Matches[1])) {
            throw "The package manifest contains a duplicate path: $($Matches[2])"
        }
    }

    $actualPaths = [string[]]@(Get-ChildItem $PackageRoot -File -Recurse |
        Where-Object { $_.FullName -cne $manifestPath } |
        ForEach-Object { [IO.Path]::GetRelativePath($PackageRoot, $_.FullName).Replace('\', '/') })
    if ($actualPaths.Count -ne $expected.Count) {
        throw "The package manifest does not cover the exact payload file set."
    }
    foreach ($relativePath in $actualPaths) {
        if (-not $expected.ContainsKey($relativePath)) {
            throw "The package manifest does not cover $relativePath."
        }
        $actualHash = (Get-FileHash (Join-Path $PackageRoot $relativePath) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -cne $expected[$relativePath]) {
            throw "The package manifest hash does not match $relativePath."
        }
    }
}

function New-DeterministicArchive {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Timestamp
    )

    $archive = [IO.Compression.ZipFile]::Open($DestinationPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $relativePaths = [string[]]@(Get-ChildItem $PackageRoot -File -Recurse |
            ForEach-Object { [IO.Path]::GetRelativePath($PackageRoot, $_.FullName).Replace('\', '/') })
        [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
        $rootName = Split-Path $PackageRoot -Leaf
        foreach ($relativePath in $relativePaths) {
            $entry = $archive.CreateEntry(
                "$rootName/$relativePath",
                [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $Timestamp
            $source = [IO.File]::OpenRead((Join-Path $PackageRoot $relativePath))
            $destination = $entry.Open()
            try {
                $source.CopyTo($destination)
            }
            finally {
                $destination.Dispose()
                $source.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Assert-ArchiveLayout {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ExpectedRoot
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($archive.Entries.Count -eq 0) {
            throw "The package archive is empty."
        }
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.Contains('\')) {
                throw "The package archive contains a non-canonical path separator: $($entry.FullName)"
            }
            $name = $entry.FullName
            if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or
                -not $name.StartsWith("$ExpectedRoot/", [StringComparison]::Ordinal)) {
                throw "The package archive contains an entry outside its versioned root: $name"
            }
            $segments = $name.Split('/', [StringSplitOptions]::RemoveEmptyEntries)
            if ($segments | Where-Object { $_ -in @('.', '..') -or $_.Contains(':') -or $_.EndsWith('.') -or $_.EndsWith(' ') }) {
                throw "The package archive contains an unsafe Windows path: $name"
            }
            if (-not $seen.Add($name)) {
                throw "The package archive contains a case-insensitive duplicate path: $name"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repositoryRoot = (Resolve-Path (Join-Path $windowsRoot "..")).Path
$project = Join-Path $windowsRoot "src/DiskInventoryZed.Windows/DiskInventoryZed.Windows.csproj"
$buildProperties = Join-Path $windowsRoot "Directory.Build.props"
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory, $repositoryRoot)
$expectedSdk = (Get-Content (Join-Path $repositoryRoot "global.json") | ConvertFrom-Json).sdk.version
$actualSdk = (& dotnet --version)
if ($LASTEXITCODE -ne 0 -or $actualSdk -ne $expectedSdk) {
    throw "Packaging requires .NET SDK $expectedSdk, but dotnet reported '$actualSdk'."
}

[xml]$buildPropertiesDocument = Get-Content $buildProperties
$version = ($buildPropertiesDocument.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1)
if (-not $version) {
    throw "Windows/Directory.Build.props does not define a Version property."
}
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "The Windows project Version must use major.minor.patch format; found '$version'."
}
$assemblyVersion = ($buildPropertiesDocument.Project.PropertyGroup.AssemblyVersion |
    Where-Object { $_ } | Select-Object -First 1)
$fileVersion = ($buildPropertiesDocument.Project.PropertyGroup.FileVersion |
    Where-Object { $_ } | Select-Object -First 1)
if ($assemblyVersion -cne '$(Version).0' -or $fileVersion -cne '$(Version).0') {
    throw 'AssemblyVersion and FileVersion must both derive from Version as $(Version).0.'
}
[xml]$applicationManifest = Get-Content (Join-Path $windowsRoot "src/DiskInventoryZed.Windows/app.manifest")
if ($applicationManifest.assembly.assemblyIdentity.version -cne "$version.0") {
    throw "The Windows application manifest version must equal $version.0."
}

$artifactName = "DiskInventoryZed-Windows-v$version-$Runtime"
$publishDirectory = Join-Path $outputRoot $artifactName
$archivePath = Join-Path $outputRoot "$artifactName.zip"
$temporaryArchivePath = Join-Path $outputRoot ".$artifactName.$([Guid]::NewGuid().ToString('N')).zip"

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

$sourceRevision = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceRevision -notmatch '^[0-9a-f]{40}$') {
    throw "The package source revision could not be resolved."
}
$sourceTimestampText = (& git -C $repositoryRoot show -s --format=%cI HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "The package source timestamp could not be resolved."
}
$sourceTimestamp = [DateTimeOffset]::Parse(
    $sourceTimestampText,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
if ($sourceTimestamp.Year -lt 1980) {
    throw "The source timestamp predates the ZIP format's supported range."
}

$packageMetadata = [ordered]@{
    schemaVersion = 1
    product = "Disk Inventory Zed"
    version = $version
    runtimeIdentifier = $Runtime
    sourceRevision = $sourceRevision
    dotnetSdkVersion = $actualSdk
    signaturePolicy = $SignaturePolicy
}
[IO.File]::WriteAllText(
    (Join-Path $publishDirectory "PACKAGE-METADATA.json"),
    ($packageMetadata | ConvertTo-Json) + "`n",
    [Text.UTF8Encoding]::new($false))

$certificate = $null
if ($SignaturePolicy -ne "Unsigned") {
    $certificate = Get-SigningCertificate $CertificateThumbprint $ExpectedPublisherSubject $SignaturePolicy
    Set-FirstPartySignatures $publishDirectory $SignaturePolicy $certificate
}

$expectedMachine = if ($Runtime -eq "win-x64") { 0x8664 } else { 0xaa64 }
$signerThumbprint = if ($null -eq $certificate) { "" } else { $certificate.Thumbprint }
Assert-FirstPartyVersions $publishDirectory $version
Assert-PePayload $publishDirectory $expectedMachine $SignaturePolicy $signerThumbprint $ExpectedPublisherSubject
Write-PackageManifest $publishDirectory
Assert-PackageManifest $publishDirectory
New-DeterministicArchive $publishDirectory $temporaryArchivePath $sourceTimestamp
Assert-ArchiveLayout $temporaryArchivePath $artifactName

$verificationDirectory = Join-Path $outputRoot ".$artifactName.verify"
if (Test-Path $verificationDirectory) {
    Remove-Item $verificationDirectory -Recurse -Force
}
try {
    Expand-Archive -Path $temporaryArchivePath -DestinationPath $verificationDirectory
    $verifiedPackageDirectory = Join-Path $verificationDirectory $artifactName
    @(
        "DiskInventoryZed.exe",
        "DiskInventoryZed.dll",
        "DiskInventoryZed.Core.dll",
        "DiskInventoryZed.deps.json",
        "DiskInventoryZed.runtimeconfig.json",
        "coreclr.dll",
        "hostfxr.dll",
        "hostpolicy.dll",
        "clrjit.dll",
        "LICENSE.txt",
        "README-Windows.md",
        "DOTNET-LICENSE.txt",
        "DOTNET-THIRD-PARTY-NOTICES.txt",
        "PACKAGE-METADATA.json",
        "PACKAGE-MANIFEST.sha256"
    ) | ForEach-Object {
        $requiredPath = Join-Path $verifiedPackageDirectory $_
        if (-not (Test-Path $requiredPath) -or (Get-Item $requiredPath).Length -eq 0) {
            throw "The package is missing required non-empty file: $_"
        }
    }

    Assert-PackageManifest $verifiedPackageDirectory
    Assert-FirstPartyVersions $verifiedPackageDirectory $version
    Assert-PePayload $verifiedPackageDirectory $expectedMachine $SignaturePolicy $signerThumbprint $ExpectedPublisherSubject

    if ($Runtime -eq "win-x64" -and $IsWindows -and $env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
        $process = Start-Process `
            -FilePath (Join-Path $verifiedPackageDirectory "DiskInventoryZed.exe") `
            -ArgumentList "--smoke-test" `
            -WorkingDirectory $verifiedPackageDirectory `
            -PassThru
        try {
            if (-not $process.WaitForExit(15000)) {
                try {
                    $process.Kill($true)
                }
                catch [System.InvalidOperationException] {
                    # The process exited after the timeout was observed.
                }
                if (-not $process.WaitForExit(5000)) {
                    throw "The packaged x64 application timed out and could not be terminated within 5 seconds."
                }
                throw "The packaged x64 application did not finish its startup smoke test within 15 seconds."
            }
            if ($process.ExitCode -ne 0) {
                throw "The packaged x64 application startup smoke test exited with $($process.ExitCode)."
            }
        }
        finally {
            $process.Dispose()
        }
    }

    Move-Item $temporaryArchivePath $archivePath
}
finally {
    if (Test-Path $verificationDirectory) {
        Remove-Item $verificationDirectory -Recurse -Force
    }
    if (Test-Path $temporaryArchivePath) {
        Remove-Item $temporaryArchivePath -Force
    }
}

Write-Output $archivePath
