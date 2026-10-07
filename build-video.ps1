[CmdletBinding()]
param(
    [string] $RtxVideoSdk = '',
    [string] $OpticalFlowSdk = '',
    [ValidateSet('Release','Debug')] [string] $Configuration = 'Release',
    [UInt64] $NgxAppId = 0,
    [switch] $Package,
    [switch] $ValidateHardware
)
$ErrorActionPreference = 'Stop'
if ($ValidateHardware -and !$Package) { throw '-ValidateHardware requires -Package and both NVIDIA SDKs.' }
if ($ValidateHardware -and (!$RtxVideoSdk -or !$OpticalFlowSdk)) { throw 'Hardware validation exercises both effects; supply both SDKs.' }
$backendBuild = Join-Path $PSScriptRoot 'build/video'
$cmakeArgs = @('-S', (Join-Path $PSScriptRoot 'native/video'), '-B', $backendBuild, '-A', 'x64',
    "-DRTX_VIDEO_SDK=$RtxVideoSdk", "-DOPTICAL_FLOW_SDK=$OpticalFlowSdk", "-DELGA_NGX_APP_ID=$NgxAppId")
& cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& cmake --build $backendBuild --config $Configuration
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& ctest --test-dir $backendBuild -C $Configuration --output-on-failure
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($Package) {
    if (!$RtxVideoSdk -and !$OpticalFlowSdk) { throw 'Packaging requires at least one NVIDIA SDK. SDK-free builds only test the transport.' }
    # Fresh staging avoids leaving stale DLLs from an earlier SDK in a package.
    $packagePath = Join-Path $PSScriptRoot ('build/video-package-' + [Guid]::NewGuid().ToString('N') + '/enhancements/nvidia')
    New-Item -ItemType Directory -Force $packagePath | Out-Null
    Copy-Item -LiteralPath (Join-Path $backendBuild "$Configuration/elga-video.dll") -Destination $packagePath
    $sdkRoots = @($RtxVideoSdk, $OpticalFlowSdk) | Where-Object { $_ }
    foreach ($sdkRoot in $sdkRoots) {
        # Only SDK redistributables in x64 release directories; never package
        # test DLLs, development effects, an entire SDK, or files from PATH.
        $runtimeFiles = Get-ChildItem -LiteralPath $sdkRoot -Recurse -File | Where-Object {
            $_.Name -match '^(nvngx_vsr|NvOFFRUC|cudart64_\d+|cublas64_\d+|cublasLt64_\d+)\.dll$' -and
            $_.FullName -notmatch '[\\/](dev|debug|win32|arm64)[\\/]'
        }
        foreach ($runtimeFile in $runtimeFiles) {
            $signature = Get-AuthenticodeSignature -LiteralPath $runtimeFile.FullName
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'NVIDIA') {
                throw "Unverified NVIDIA runtime: $($runtimeFile.FullName)"
            }
            $destination = Join-Path $packagePath $runtimeFile.Name
            if (Test-Path -LiteralPath $destination) {
                if ((Get-FileHash -LiteralPath $destination).Hash -ne (Get-FileHash -LiteralPath $runtimeFile.FullName).Hash) {
                    throw "Conflicting runtime versions: $($runtimeFile.Name)"
                }
            } else { Copy-Item -LiteralPath $runtimeFile.FullName -Destination $destination }
        }
        Get-ChildItem -LiteralPath $sdkRoot -File -Recurse | Where-Object { $_.Name -match '(?i)(license|notice)' -and $_.Extension -in '.pdf','.txt','.md' } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $packagePath }
    }
    if ($RtxVideoSdk -and !(Test-Path -LiteralPath (Join-Path $packagePath 'nvngx_vsr.dll'))) { throw 'RTX Video redistributable was not found' }
    if ($OpticalFlowSdk -and !(Test-Path -LiteralPath (Join-Path $packagePath 'NvOFFRUC.dll'))) { throw 'FRUC redistributable was not found' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'native/video/sdk-versions.json') -Destination $packagePath
    Get-ChildItem -LiteralPath $packagePath -File | Get-FileHash -Algorithm SHA256 |
        Select-Object @{Name='file';Expression={Split-Path $_.Path -Leaf}}, Hash |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $packagePath 'manifest.json') -Encoding utf8
    Write-Host "Optional runtime folder: $packagePath"
    if ($ValidateHardware) {
        & (Join-Path $backendBuild "$Configuration/video-nvidia-test.exe") (Join-Path $packagePath 'elga-video.dll')
        if ($LASTEXITCODE -ne 0) { throw 'NVIDIA hardware validation failed; do not install this package.' }
    }
}
