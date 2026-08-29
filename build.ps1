[CmdletBinding()]
param(
    [ValidateSet("Release", "Debug")]
    [string] $Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$odinCommand = Get-Command odin -ErrorAction SilentlyContinue
$odinPath = if ($null -ne $odinCommand) {
    $odinCommand.Source
} else {
    Join-Path $env:ProgramFiles "Odin\odin.exe"
}

if (-not (Test-Path -LiteralPath $odinPath -PathType Leaf)) {
    throw "Odin was not found. Add odin.exe to PATH or install it in '$odinPath'."
}

$sourcePath = Join-Path $PSScriptRoot "src"
$outputDirectory = Join-Path $PSScriptRoot "build"
$outputPath = Join-Path $outputDirectory "elga-camera.exe"
$debugSymbolsPath = [System.IO.Path]::ChangeExtension($outputPath, ".pdb")
$odinArguments = @(
    "build"
    $sourcePath
    "-out:$outputPath"
    "-subsystem:windows"
    "-vet"
    "-strict-style"
)

if ($Configuration -eq "Release") {
    if (Test-Path -LiteralPath $debugSymbolsPath) {
        Remove-Item -LiteralPath $debugSymbolsPath -Force
    }
    $odinArguments += "-o:speed"
} else {
    $odinArguments += "-debug"
}

New-Item -ItemType Directory -Force $outputDirectory | Out-Null
& $odinPath @odinArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Built $outputPath ($Configuration)"
