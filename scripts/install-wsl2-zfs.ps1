[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ZfsModules,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $StockModulesVhd = 'C:\Program Files\WSL\tools\modules.vhd',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $DestinationDirectory = 'C:\WSL\wsl2_zfs',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Distro
)

$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter()]
        [string[]] $Arguments = @()
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Get-WslPrefix {
    if ($Distro) {
        return @('--distribution', $Distro)
    }

    return @()
}

function Invoke-WslCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = & wsl.exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "wsl.exe failed with exit code $LASTEXITCODE"
    }

    return $output
}

function ConvertTo-WslPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $WindowsPath
    )

    $arguments = @()
    $arguments += Get-WslPrefix
    $arguments += @('--user', 'root', '--', 'wslpath', '-a', $WindowsPath)
    $output = @(Invoke-WslCapture -Arguments $arguments)
    if ($output.Count -eq 0 -or -not $output[0]) {
        throw "Could not convert path for WSL: $WindowsPath"
    }

    return $output[0].Trim()
}

function Set-WslKernelModules {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ModulesPath
    )

    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if (-not $userProfile) {
        throw 'Could not determine the Windows user profile path.'
    }

    $configPath = Join-Path $userProfile '.wslconfig'
    $kernelModulesValue = $ModulesPath -replace '\\', '\\'
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
    Write-Host "Updated $configPath with $kernelModulesLine"
}

function Expand-ZfsModules {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ArtifactPath,

        [Parameter(Mandatory = $true)]
        [string] $WorkRoot
    )

    $resolvedArtifact = (Resolve-Path -LiteralPath $ArtifactPath).Path
    $packageDirectory = Join-Path $WorkRoot 'package'
    $overlayDirectory = Join-Path $WorkRoot 'overlay'
    New-Item -ItemType Directory -Force -Path $packageDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $overlayDirectory | Out-Null

    $tarball = $resolvedArtifact
    if ($resolvedArtifact.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
        Expand-Archive -LiteralPath $resolvedArtifact -DestinationPath $packageDirectory -Force
        $candidates = @(Get-ChildItem -LiteralPath $packageDirectory -Recurse -File -Filter '*.zfs-modules.tar.gz')
        if ($candidates.Count -ne 1) {
            throw "Expected exactly one .zfs-modules.tar.gz in artifact zip, found $($candidates.Count): $resolvedArtifact"
        }
        $tarball = $candidates[0].FullName
    } elseif (-not ($resolvedArtifact.EndsWith('.tar.gz', [StringComparison]::OrdinalIgnoreCase) -or $resolvedArtifact.EndsWith('.tgz', [StringComparison]::OrdinalIgnoreCase))) {
        throw "ZfsModules must point to a .zfs-modules.tar.gz file or a GitHub artifact .zip: $resolvedArtifact"
    }

    Invoke-CheckedCommand -FilePath 'tar.exe' -Arguments @('-xzf', $tarball, '-C', $overlayDirectory)

    $kernelReleasePath = Join-Path $overlayDirectory '.wsl2-zfs\KERNEL_RELEASE'
    if (-not (Test-Path -LiteralPath $kernelReleasePath -PathType Leaf)) {
        throw "ZFS module overlay is missing .wsl2-zfs\KERNEL_RELEASE"
    }

    $kernelRelease = (Get-Content -LiteralPath $kernelReleasePath -TotalCount 1).Trim()
    if (-not $kernelRelease) {
        throw 'ZFS module overlay has an empty KERNEL_RELEASE marker.'
    }

    return [PSCustomObject]@{
        OverlayDirectory = $overlayDirectory
        KernelRelease = $kernelRelease
    }
}

if (-not (Test-Administrator)) {
    throw 'The overlay installer must run from an elevated PowerShell session because wsl --mount requires Administrator access.'
}

if (-not (Test-Path -LiteralPath $ZfsModules -PathType Leaf)) {
    throw "ZFS module overlay artifact does not exist: $ZfsModules"
}

if (-not (Test-Path -LiteralPath $StockModulesVhd -PathType Leaf)) {
    throw "Stock WSL modules VHD does not exist: $StockModulesVhd"
}

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wsl2-zfs-overlay-$([System.Guid]::NewGuid().ToString('N'))"
$mountName = "wsl2-zfs-modules-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
$mounted = $false

try {
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
    $overlay = Expand-ZfsModules -ArtifactPath $ZfsModules -WorkRoot $workRoot

    $unameArguments = @()
    $unameArguments += Get-WslPrefix
    $unameArguments += @('--user', 'root', '--', 'uname', '-r')
    $runningKernel = (@(Invoke-WslCapture -Arguments $unameArguments)[0]).Trim()
    if ($runningKernel -ne $overlay.KernelRelease) {
        throw "ZFS modules were built for $($overlay.KernelRelease), but WSL is running $runningKernel."
    }

    New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
    $destinationPath = Join-Path $DestinationDirectory 'modules.vhd'
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        Copy-Item -LiteralPath $destinationPath -Destination "$destinationPath.wsl2-zfs.$timestamp.bak" -Force
    }

    Copy-Item -LiteralPath (Resolve-Path -LiteralPath $StockModulesVhd).Path -Destination $destinationPath -Force

    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments @('--shutdown')
    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments @('--mount', $destinationPath, '--vhd', '--name', $mountName)
    $mounted = $true

    $mergeScript = @'
set -euo pipefail

overlay_dir=$1
kernel_release=$2
mount_name=$3
mount_root="/mnt/wsl/${mount_name}"

if [ ! -d "$mount_root" ]; then
  echo "mounted modules VHD is not visible at $mount_root" >&2
  exit 1
fi

module_root="$mount_root"
if [ -d "$mount_root/lib/modules/$kernel_release" ]; then
  module_root="$mount_root/lib/modules/$kernel_release"
fi

if [ ! -d "$module_root/kernel" ] && [ ! -f "$module_root/modules.dep" ]; then
  echo "mounted VHD does not look like a WSL module tree: $module_root" >&2
  exit 1
fi

src="$overlay_dir"
if [ -d "$overlay_dir/lib/modules/$kernel_release" ]; then
  src="$overlay_dir/lib/modules/$kernel_release"
fi

if [ "$(cat "$src/.wsl2-zfs/KERNEL_RELEASE")" != "$kernel_release" ]; then
  echo "overlay kernel marker does not match $kernel_release" >&2
  exit 1
fi

cp -a "$src"/. "$module_root"/

depmod_root=$(mktemp -d)
cleanup() {
  set +e
  umount "$depmod_root/lib/modules/$kernel_release" 2>/dev/null || true
  rm -rf "$depmod_root"
}
trap cleanup EXIT

mkdir -p "$depmod_root/lib/modules/$kernel_release"
mount --bind "$module_root" "$depmod_root/lib/modules/$kernel_release"
depmod -b "$depmod_root" "$kernel_release"
modinfo -b "$depmod_root" -k "$kernel_release" zfs >/dev/null
sync
'@

    $mergeScriptPath = Join-Path $workRoot 'merge-overlay.sh'
    [System.IO.File]::WriteAllText($mergeScriptPath, $mergeScript, [System.Text.Encoding]::ASCII)

    $overlayWslPath = ConvertTo-WslPath -WindowsPath $overlay.OverlayDirectory
    $mergeScriptWslPath = ConvertTo-WslPath -WindowsPath $mergeScriptPath
    $mergeArguments = @()
    $mergeArguments += Get-WslPrefix
    $mergeArguments += @('--user', 'root', '--', 'bash', $mergeScriptWslPath, $overlayWslPath, $overlay.KernelRelease, $mountName)
    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments $mergeArguments

    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments @('--unmount', $destinationPath)
    $mounted = $false

    Set-WslKernelModules -ModulesPath $destinationPath
    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments @('--shutdown')

    Write-Host "Installed merged WSL kernel modules VHD at $destinationPath"
} finally {
    if ($mounted) {
        & wsl.exe --unmount $destinationPath | Out-Null
    }

    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
