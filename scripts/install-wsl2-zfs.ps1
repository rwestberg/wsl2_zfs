[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ModulesVhdx,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $DestinationDirectory = 'C:\WSL\wsl2_zfs'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ModulesVhdx -PathType Leaf)) {
    throw "Modules VHDX does not exist: $ModulesVhdx"
}

$resolvedModulesVhdx = (Resolve-Path -LiteralPath $ModulesVhdx).Path
if ([System.IO.Path]::GetExtension($resolvedModulesVhdx) -ne '.vhdx') {
    throw "ModulesVhdx must point to a .vhdx file: $resolvedModulesVhdx"
}

New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
$destinationPath = Join-Path $DestinationDirectory 'modules.vhdx'
Copy-Item -LiteralPath $resolvedModulesVhdx -Destination $destinationPath -Force

$userProfile = [Environment]::GetFolderPath('UserProfile')
if (-not $userProfile) {
    throw 'Could not determine the Windows user profile path.'
}

$configPath = Join-Path $userProfile '.wslconfig'
$kernelModulesValue = $destinationPath -replace '\\', '\\'
$kernelModulesLine = "kernelModules=$kernelModulesValue"

if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backupPath = "$configPath.wsl2-zfs.$timestamp.bak"
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    $lines = @(Get-Content -LiteralPath $configPath)
    Write-Host "Backed up existing .wslconfig to $backupPath"
} else {
    $lines = @()
}

$output = [System.Collections.Generic.List[string]]::new()
$inWsl2 = $false
$sawWsl2 = $false
$setKernelModules = $false

foreach ($line in $lines) {
    $trimmed = $line.Trim()
    $isSection = $trimmed -match '^\[[^\]]+\]$'

    if ($isSection) {
        if ($inWsl2 -and -not $setKernelModules) {
            $output.Add($kernelModulesLine)
            $setKernelModules = $true
        }

        $inWsl2 = $trimmed -ieq '[wsl2]'
        if ($inWsl2) {
            $sawWsl2 = $true
        }

        $output.Add($line)
        continue
    }

    if ($inWsl2 -and $line -match '^\s*kernelModules\s*=') {
        if (-not $setKernelModules) {
            $output.Add($kernelModulesLine)
            $setKernelModules = $true
        }
        continue
    }

    $output.Add($line)
}

if ($inWsl2 -and -not $setKernelModules) {
    $output.Add($kernelModulesLine)
    $setKernelModules = $true
}

if (-not $sawWsl2) {
    if ($output.Count -gt 0 -and $output[$output.Count - 1].Trim() -ne '') {
        $output.Add('')
    }
    $output.Add('[wsl2]')
    $output.Add($kernelModulesLine)
}

Set-Content -LiteralPath $configPath -Value $output -Encoding Ascii

& wsl.exe --shutdown
if ($LASTEXITCODE -ne 0) {
    throw 'wsl --shutdown failed. Check that WSL is installed and available on PATH.'
}

Write-Host "Installed WSL kernel modules VHDX at $destinationPath"
Write-Host "Updated $configPath with $kernelModulesLine"
