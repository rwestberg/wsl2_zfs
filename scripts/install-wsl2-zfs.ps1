[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('InstallBundle', 'Bundle')]
    [ValidateNotNullOrEmpty()]
    [string] $ZfsModules,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $StockModulesVhd = 'C:\Program Files\WSL\tools\modules.vhd',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $KernelPath = 'C:\Program Files\WSL\tools\kernel',

    [Parameter()]
    [string] $DestinationDirectory,

    [Parameter()]
    [ValidateRange(268435456, [UInt64]::MaxValue)]
    [UInt64] $ModulesVhdSizeBytes = 1GB,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Distro,

    [Parameter()]
    [switch] $InstallDebs
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    Write-Host ''
    Write-Host "==> $Message"
}

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

function New-EmptyVhd {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [UInt64] $SizeBytes
    )

    $newVhd = Get-Command New-VHD -ErrorAction SilentlyContinue
    if ($newVhd) {
        New-VHD -Path $Path -Dynamic -SizeBytes $SizeBytes | Out-Null
        return
    }

    $diskpart = Get-Command diskpart.exe -ErrorAction SilentlyContinue
    if (-not $diskpart) {
        throw 'Neither New-VHD nor diskpart.exe is available to create the modules VHD.'
    }

    $sizeMb = [Math]::Ceiling($SizeBytes / 1MB)
    $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) "wsl2-zfs-diskpart-$([System.Guid]::NewGuid().ToString('N')).txt"
    try {
        [System.IO.File]::WriteAllText($scriptPath, "create vdisk file=`"$Path`" maximum=$sizeMb type=expandable`r`n", [System.Text.Encoding]::ASCII)
        Invoke-CheckedCommand -FilePath $diskpart.Source -Arguments @('/s', $scriptPath)
    } finally {
        if (Test-Path -LiteralPath $scriptPath) {
            Remove-Item -LiteralPath $scriptPath -Force
        }
    }
}

function ConvertTo-WslPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $WindowsPath
    )

    $pathForWsl = $WindowsPath -replace '\\', '/'
    $arguments = @()
    $arguments += Get-WslPrefix
    $arguments += @('--user', 'root', '--exec', 'wslpath', '-a', $pathForWsl)
    $output = @(Invoke-WslCapture -Arguments $arguments)
    if ($output.Count -eq 0 -or -not $output[0]) {
        throw "Could not convert path for WSL: $WindowsPath"
    }

    return $output[0].Trim()
}

function Get-WslBlockDeviceNames {
    $arguments = @()
    $arguments += Get-WslPrefix
    $arguments += @('--user', 'root', '--exec', 'cat', '/proc/partitions')
    $output = @(Invoke-WslCapture -Arguments $arguments)

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $output) {
        $fields = @($line.Trim() -split '\s+')
        if ($fields.Count -lt 4 -or $fields[0] -eq 'major') {
            continue
        }

        $name = $fields[3]
        if ($name -match '^(loop|ram)') {
            continue
        }

        $names.Add($name)
    }

    return @($names)
}

function Set-WslKernelConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string] $KernelPath,

        [Parameter(Mandatory = $true)]
        [string] $ModulesPath
    )

    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if (-not $userProfile) {
        throw 'Could not determine the Windows user profile path.'
    }

    $configPath = Join-Path $userProfile '.wslconfig'
    $kernelValue = $KernelPath -replace '\\', '\\'
    $kernelModulesValue = $ModulesPath -replace '\\', '\\'
    $kernelLine = "kernel=$kernelValue"
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
    $setKernel = $false
    $setKernelModules = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        $isSection = $trimmed -match '^\[[^\]]+\]$'

        if ($isSection) {
            if ($inWsl2 -and -not $setKernel) {
                $output.Add($kernelLine)
                $setKernel = $true
            }
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

        if ($inWsl2 -and $line -match '^\s*kernel\s*=') {
            if (-not $setKernel) {
                $output.Add($kernelLine)
                $setKernel = $true
            }
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

    if ($inWsl2 -and -not $setKernel) {
        $output.Add($kernelLine)
        $setKernel = $true
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
        $output.Add($kernelLine)
        $output.Add($kernelModulesLine)
    }

    Set-Content -LiteralPath $configPath -Value $output -Encoding Ascii
    Write-Host "Updated $configPath with $kernelLine"
    Write-Host "Updated $configPath with $kernelModulesLine"
}

function Repair-WslKernelForExistingModules {
    param(
        [Parameter(Mandatory = $true)]
        [string] $KernelPath
    )

    $userProfile = [Environment]::GetFolderPath('UserProfile')
    if (-not $userProfile) {
        throw 'Could not determine the Windows user profile path.'
    }

    $configPath = Join-Path $userProfile '.wslconfig'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return
    }

    $lines = @(Get-Content -LiteralPath $configPath)
    $inWsl2 = $false
    $hasKernel = $false
    $hasKernelModules = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[[^\]]+\]$') {
            $inWsl2 = $trimmed -ieq '[wsl2]'
            continue
        }

        if ($inWsl2 -and $line -match '^\s*kernel\s*=') {
            $hasKernel = $true
        }

        if ($inWsl2 -and $line -match '^\s*kernelModules\s*=') {
            $hasKernelModules = $true
        }
    }

    if (-not $hasKernelModules -or $hasKernel) {
        return
    }

    Write-Step "Repairing existing WSL configuration"
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backupPath = "$configPath.wsl2-zfs.$timestamp.bak"
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    Write-Host "Backed up existing .wslconfig to $backupPath"

    $kernelValue = $KernelPath -replace '\\', '\\'
    $kernelLine = "kernel=$kernelValue"
    $output = [System.Collections.Generic.List[string]]::new()
    $inWsl2 = $false
    $insertedKernel = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        $isSection = $trimmed -match '^\[[^\]]+\]$'

        if ($isSection) {
            if ($inWsl2 -and -not $insertedKernel) {
                $output.Add($kernelLine)
                $insertedKernel = $true
            }

            $inWsl2 = $trimmed -ieq '[wsl2]'
            $output.Add($line)
            continue
        }

        if ($inWsl2 -and -not $insertedKernel -and $line -match '^\s*kernelModules\s*=') {
            $output.Add($kernelLine)
            $insertedKernel = $true
        }

        $output.Add($line)
    }

    if ($inWsl2 -and -not $insertedKernel) {
        $output.Add($kernelLine)
    }

    Set-Content -LiteralPath $configPath -Value $output -Encoding Ascii
    Write-Host "Added $kernelLine to $configPath"
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
    $runtimeDebs = @()
    if ($resolvedArtifact.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Step "Extracting install artifact"
        Expand-Archive -LiteralPath $resolvedArtifact -DestinationPath $packageDirectory -Force
        $candidates = @(Get-ChildItem -LiteralPath $packageDirectory -Recurse -File -Filter '*.zfs-modules.tar.gz')
        if ($candidates.Count -ne 1) {
            throw "Expected exactly one .zfs-modules.tar.gz in artifact zip, found $($candidates.Count): $resolvedArtifact"
        }
        $tarball = $candidates[0].FullName
        $runtimeDebs = @(
            Get-ChildItem -LiteralPath $packageDirectory -Recurse -File -Filter '*.deb' |
                Sort-Object -Property Name |
                ForEach-Object { $_.FullName }
        )
    } elseif (-not ($resolvedArtifact.EndsWith('.tar.gz', [StringComparison]::OrdinalIgnoreCase) -or $resolvedArtifact.EndsWith('.tgz', [StringComparison]::OrdinalIgnoreCase))) {
        throw "Install artifact must be a .zip, .zfs-modules.tar.gz, or .tgz file: $resolvedArtifact"
    }

    Write-Step "Extracting ZFS kernel modules"
    Invoke-CheckedCommand -FilePath 'tar.exe' -Arguments @('-xzf', $tarball, '-C', $overlayDirectory)

    $kernelReleasePath = Join-Path $overlayDirectory '.wsl2-zfs\KERNEL_RELEASE'
    if (-not (Test-Path -LiteralPath $kernelReleasePath -PathType Leaf)) {
        throw "ZFS module overlay is missing .wsl2-zfs\KERNEL_RELEASE"
    }

    $kernelRelease = (Get-Content -LiteralPath $kernelReleasePath -TotalCount 1).Trim()
    if (-not $kernelRelease) {
        throw 'ZFS module overlay has an empty KERNEL_RELEASE marker.'
    }

    $zfsVersionPath = Join-Path $overlayDirectory '.wsl2-zfs\ZFS_VERSION'
    if (-not (Test-Path -LiteralPath $zfsVersionPath -PathType Leaf)) {
        throw "ZFS module overlay is missing .wsl2-zfs\ZFS_VERSION"
    }

    $zfsVersion = (Get-Content -LiteralPath $zfsVersionPath -TotalCount 1).Trim()
    if (-not $zfsVersion) {
        throw 'ZFS module overlay has an empty ZFS_VERSION marker.'
    }

    return [PSCustomObject]@{
        OverlayDirectory = $overlayDirectory
        KernelRelease = $kernelRelease
        ZfsVersion = $zfsVersion
        RuntimeDebs = $runtimeDebs
    }
}

function Install-OpenZfsRuntimeDebs {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $DebPaths,

        [Parameter(Mandatory = $true)]
        [string] $WorkRoot
    )

    if ($DebPaths.Count -eq 0) {
        throw 'InstallDebs was requested, but the selected install artifact does not contain runtime .deb packages.'
    }

    $debDirectory = Join-Path $WorkRoot 'runtime-debs'
    New-Item -ItemType Directory -Force -Path $debDirectory | Out-Null
    foreach ($debPath in $DebPaths) {
        Copy-Item -LiteralPath $debPath -Destination $debDirectory -Force
    }

    $installScript = @'
set -euo pipefail

deb_dir=$1

if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get is required to install the generated OpenZFS runtime .deb packages" >&2
  exit 1
fi

shopt -s nullglob
debs=("$deb_dir"/*.deb)
if [ "${#debs[@]}" -eq 0 ]; then
  echo "no .deb packages found in $deb_dir" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get install -y "${debs[@]}"
modprobe zfs
zfs --version
'@

    $installScriptPath = Join-Path $WorkRoot 'install-runtime-debs.sh'
    [System.IO.File]::WriteAllText($installScriptPath, $installScript, [System.Text.Encoding]::ASCII)

    $debWslPath = ConvertTo-WslPath -WindowsPath $debDirectory
    $installScriptWslPath = ConvertTo-WslPath -WindowsPath $installScriptPath

    $installArguments = @()
    $installArguments += Get-WslPrefix
    $installArguments += @('--user', 'root', '--exec', 'bash', $installScriptWslPath, $debWslPath)
    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments $installArguments
}

if (-not (Test-Administrator)) {
    throw 'The overlay installer must run from an elevated PowerShell session because wsl --mount requires Administrator access.'
}

if (-not (Test-Path -LiteralPath $ZfsModules -PathType Leaf)) {
    throw "Install artifact does not exist: $ZfsModules"
}

if (-not (Test-Path -LiteralPath $StockModulesVhd -PathType Leaf)) {
    throw "Stock WSL modules VHD does not exist: $StockModulesVhd"
}

$resolvedStockModulesVhd = (Resolve-Path -LiteralPath $StockModulesVhd).Path

if (-not (Test-Path -LiteralPath $KernelPath -PathType Leaf)) {
    throw "Stock WSL kernel does not exist: $KernelPath"
}

Repair-WslKernelForExistingModules -KernelPath $KernelPath

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wsl2-zfs-overlay-$([System.Guid]::NewGuid().ToString('N'))"
$stockMountPath = Join-Path $workRoot 'stock-modules.vhd'
$stockMounted = $false
$destinationMounted = $false

try {
    Write-Step "Preparing temporary workspace"
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
    $overlay = Expand-ZfsModules -ArtifactPath $ZfsModules -WorkRoot $workRoot
    if ($InstallDebs -and $overlay.RuntimeDebs.Count -eq 0) {
        throw 'InstallDebs was requested, but no runtime .deb packages were found in the install artifact.'
    }

    Write-Step "Checking running WSL kernel"
    $unameArguments = @()
    $unameArguments += Get-WslPrefix
    $unameArguments += @('--user', 'root', '--exec', 'uname', '-r')
    $runningKernel = (@(Invoke-WslCapture -Arguments $unameArguments)[0]).Trim()
    if ($runningKernel -ne $overlay.KernelRelease) {
        throw "ZFS modules were built for $($overlay.KernelRelease), but WSL is running $runningKernel."
    }
    Write-Host "Matched WSL kernel $runningKernel"

    Write-Step "Creating writable modules VHD"
    if (-not $DestinationDirectory) {
        $DestinationDirectory = Split-Path -Path $resolvedStockModulesVhd -Parent
    }

    $safeZfsVersion = $overlay.ZfsVersion -replace '[^A-Za-z0-9._-]', '_'
    $destinationFileName = "modules_zfs-$safeZfsVersion.vhdx"
    New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
    $destinationPath = Join-Path $DestinationDirectory $destinationFileName
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        $destinationBackupPath = "$destinationPath.wsl2-zfs.$timestamp.bak"
        Copy-Item -LiteralPath $destinationPath -Destination $destinationBackupPath -Force
        Write-Host "Backed up existing modules VHD to $destinationBackupPath"
        Remove-Item -LiteralPath $destinationPath -Force
    }

    New-EmptyVhd -Path $destinationPath -SizeBytes $ModulesVhdSizeBytes
    Set-ItemProperty -LiteralPath $destinationPath -Name IsReadOnly -Value $false

    Write-Step "Shutting down WSL before mounting modules VHD"
    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments @('--shutdown')

    Write-Step "Copying stock modules VHD for merge"
    Copy-Item -LiteralPath $resolvedStockModulesVhd -Destination $stockMountPath -Force
    Set-ItemProperty -LiteralPath $stockMountPath -Name IsReadOnly -Value $false

    Write-Step "Recording existing WSL block devices"
    $blockDevicesBefore = @(Get-WslBlockDeviceNames)

    Write-Step "Attaching stock modules VHD copy read-only"
    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments @('--mount', $stockMountPath, '--vhd', '--bare')
    $stockMounted = $true

    Start-Sleep -Seconds 1
    $blockDevicesAfterStock = @(Get-WslBlockDeviceNames)
    $stockBlockDevices = @($blockDevicesAfterStock | Where-Object { $blockDevicesBefore -notcontains $_ })
    if ($stockBlockDevices.Count -eq 0) {
        throw 'Could not identify the WSL block device for the stock modules VHD.'
    }
    Write-Host "Attached stock modules VHD as: $($stockBlockDevices -join ', ')"

    Write-Step "Attaching writable modules VHD"
    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments @('--mount', $destinationPath, '--vhd', '--bare')
    $destinationMounted = $true

    Start-Sleep -Seconds 1
    $blockDevicesAfterDestination = @(Get-WslBlockDeviceNames)
    $destinationBlockDevices = @($blockDevicesAfterDestination | Where-Object { $blockDevicesAfterStock -notcontains $_ })
    if ($destinationBlockDevices.Count -eq 0) {
        throw 'Could not identify the WSL block device for the writable modules VHD.'
    }
    Write-Host "Attached writable modules VHD as: $($destinationBlockDevices -join ', ')"

    $mergeScript = @'
set -euo pipefail

overlay_dir=$1
kernel_release=$2
shift 2

stock_devices=()
destination_devices=()
mode=
for arg in "$@"; do
  case "$arg" in
    --stock)
      mode=stock
      ;;
    --destination)
      mode=destination
      ;;
    *)
      case "$mode" in
        stock)
          stock_devices+=("$arg")
          ;;
        destination)
          destination_devices+=("$arg")
          ;;
        *)
          echo "unexpected argument before device group marker: $arg" >&2
          exit 1
          ;;
      esac
      ;;
  esac
done

if [ "${#stock_devices[@]}" -eq 0 ] || [ "${#destination_devices[@]}" -eq 0 ]; then
  echo "stock and destination block device candidates are required" >&2
  exit 1
fi

if ! command -v mkfs.ext4 >/dev/null 2>&1; then
  echo "mkfs.ext4 is required inside WSL to create the writable modules VHD" >&2
  exit 1
fi

stock_mount=$(mktemp -d)
destination_mount=$(mktemp -d)
stock_mounted=0
destination_mounted=0
cleanup() {
  set +e
  if [ "$destination_mounted" -eq 1 ]; then
    umount "$destination_mount" 2>/dev/null || true
  fi
  if [ "$stock_mounted" -eq 1 ]; then
    umount "$stock_mount" 2>/dev/null || true
  fi
  rm -rf "$stock_mount" "$destination_mount"
}
trap cleanup EXIT

for candidate in "${stock_devices[@]}"; do
  device="/dev/$candidate"
  if mount -o ro "$device" "$stock_mount" 2>/dev/null; then
    stock_module_root="$stock_mount"
    if [ -d "$stock_mount/lib/modules/$kernel_release" ]; then
      stock_module_root="$stock_mount/lib/modules/$kernel_release"
    fi

    if [ -d "$stock_module_root/kernel" ] || [ -f "$stock_module_root/modules.dep" ]; then
      stock_mounted=1
      echo "Mounted stock modules VHD block device $device at $stock_mount"
      break
    fi

    umount "$stock_mount" 2>/dev/null || true
  fi
done

if [ "$stock_mounted" -ne 1 ]; then
  echo "could not find a stock WSL module tree in candidates: ${stock_devices[*]}" >&2
  exit 1
fi

for candidate in "${destination_devices[@]}"; do
  device="/dev/$candidate"
  if mkfs.ext4 -F -q "$device" && mount -o rw "$device" "$destination_mount"; then
    destination_mounted=1
    echo "Formatted and mounted writable modules VHD block device $device at $destination_mount"
    break
  fi
done

if [ "$destination_mounted" -ne 1 ]; then
  echo "could not format and mount writable modules VHD from candidates: ${destination_devices[*]}" >&2
  exit 1
fi

echo "Using stock module tree: $stock_module_root"

destination_module_root="$destination_mount"

if ! touch "$destination_module_root/.wsl2-zfs-write-test" 2>/dev/null; then
  echo "writable modules VHD is read-only after formatting: $destination_module_root" >&2
  exit 1
fi
rm -f "$destination_module_root/.wsl2-zfs-write-test"

echo "Copying stock modules into writable VHD"
cp -a "$stock_module_root"/. "$destination_module_root"/

src="$overlay_dir"
if [ -d "$overlay_dir/lib/modules/$kernel_release" ]; then
  src="$overlay_dir/lib/modules/$kernel_release"
fi

if [ "$(cat "$src/.wsl2-zfs/KERNEL_RELEASE")" != "$kernel_release" ]; then
  echo "overlay kernel marker does not match $kernel_release" >&2
  exit 1
fi

echo "Copying ZFS modules from overlay"
cp -a "$src"/. "$destination_module_root"/

depmod_root=$(mktemp -d)
cleanup() {
  set +e
  umount "$depmod_root/lib/modules/$kernel_release" 2>/dev/null || true
  if [ "$destination_mounted" -eq 1 ]; then
    umount "$destination_mount" 2>/dev/null || true
  fi
  if [ "$stock_mounted" -eq 1 ]; then
    umount "$stock_mount" 2>/dev/null || true
  fi
  rm -rf "$depmod_root"
  rm -rf "$stock_mount" "$destination_mount"
}
trap cleanup EXIT

mkdir -p "$depmod_root/lib/modules/$kernel_release"
mount --bind "$destination_module_root" "$depmod_root/lib/modules/$kernel_release"
echo "Regenerating module dependency indexes"
depmod -b "$depmod_root" "$kernel_release"
echo "Validating zfs module lookup"
modinfo -b "$depmod_root" -k "$kernel_release" zfs >/dev/null
echo "Syncing modules VHD"
sync
'@

    $mergeScriptPath = Join-Path $workRoot 'merge-overlay.sh'
    [System.IO.File]::WriteAllText($mergeScriptPath, $mergeScript, [System.Text.Encoding]::ASCII)

    Write-Step "Resolving temporary paths inside WSL"
    $overlayWslPath = ConvertTo-WslPath -WindowsPath $overlay.OverlayDirectory
    $mergeScriptWslPath = ConvertTo-WslPath -WindowsPath $mergeScriptPath

    Write-Step "Merging ZFS modules into copied modules VHD"
    $mergeArguments = @()
    $mergeArguments += Get-WslPrefix
    $mergeArguments += @('--user', 'root', '--exec', 'bash', $mergeScriptWslPath, $overlayWslPath, $overlay.KernelRelease)
    $mergeArguments += '--stock'
    $mergeArguments += $stockBlockDevices
    $mergeArguments += '--destination'
    $mergeArguments += $destinationBlockDevices
    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments $mergeArguments

    Write-Step "Unmounting modules VHD"
    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments @('--unmount', $destinationPath)
    $destinationMounted = $false
    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments @('--unmount', $stockMountPath)
    $stockMounted = $false

    Write-Step "Updating WSL configuration"
    Set-WslKernelConfiguration -KernelPath $KernelPath -ModulesPath $destinationPath

    Write-Step "Shutting down WSL to apply modules VHD"
    Invoke-CheckedCommand -FilePath 'wsl.exe' -Arguments @('--shutdown')

    if ($InstallDebs) {
        if ($Distro) {
            Write-Step "Installing OpenZFS runtime packages in WSL distro $Distro"
        } else {
            Write-Step "Installing OpenZFS runtime packages in the default WSL distro"
        }
        Install-OpenZfsRuntimeDebs -DebPaths $overlay.RuntimeDebs -WorkRoot $workRoot
    }

    Write-Host "Installed merged WSL kernel modules VHD at $destinationPath"
} finally {
    if ($destinationMounted) {
        & wsl.exe --unmount $destinationPath | Out-Null
    }
    if ($stockMounted) {
        & wsl.exe --unmount $stockMountPath | Out-Null
    }

    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
