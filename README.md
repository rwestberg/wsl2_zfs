# WSL2 with ZFS

This repository builds OpenZFS modules for modern WSL2 without replacing the Microsoft WSL kernel. The primary artifact is a ZFS-only module overlay for one exact WSL kernel release. The Windows installer copies the stock WSL `modules.vhd`, merges the ZFS modules into that copy, and points `.wslconfig` `kernelModules` at the merged local VHD.

## Requirements

- Store-delivered WSL new enough to support `[wsl2] kernelModules`.
- x86_64 WSL kernel. ARM64 is not built yet.
- Administrator access on Windows. The installer uses `wsl --mount` to edit a copied modules VHD.
- An installed WSL distro with `depmod` and `modinfo` available.
- A release artifact matching the exact WSL kernel shown by `uname -r`.
- OpenZFS user-space `.deb` packages from the same workflow run as the module overlay.

Check the running kernel inside WSL:

```bash
uname -r
# Example: 6.18.26.1-microsoft-standard-WSL2
```

For that example, run the build workflow with `kernel_ver=6.18.26.1`. ZFS modules built for another kernel release will not load reliably.

## Build

Run the `Build` workflow manually.

Inputs:

- `kernel_ver`: exact WSL kernel version suffix, default `6.18.26.1`.
- `zfs_ver`: OpenZFS release, default `2.4.2`.
- `publish_release`: when true, publish a GitHub release named after the generated artifact.

The workflow produces:

- `<artifact-base>-zfs-module-overlay`: the ZFS kernel module overlay.
- `<artifact-base>-runtime-debs`: the OpenZFS runtime `.deb` packages needed inside a WSL distro.
- `<artifact-base>-build-kit`: kernel build metadata for maintainers and advanced local rebuilds.
- `ARTIFACTS.txt` and `SHA256SUMS` in the package/build-kit artifacts.

When `publish_release=true`, the release contains the same groups as zip files.

## Install

Run the Windows installer from an elevated PowerShell session:

```powershell
.\scripts\install-wsl2-zfs.ps1 -ZfsModules .\wsl2-zfs-6.18.26.1-microsoft-standard-WSL2-openzfs-2.4.2-zfs-module-overlay.zip
```

The installer accepts either the downloaded `*-zfs-module-overlay.zip` artifact or an extracted `.zfs-modules.tar.gz` file. It copies `C:\Program Files\WSL\tools\modules.vhd` to `C:\WSL\wsl2_zfs\modules.vhd`, mounts the copy through WSL, merges the ZFS modules, runs `depmod`, backs up `%UserProfile%\.wslconfig` when it exists, updates only the `[wsl2] kernelModules` key, and runs `wsl --shutdown`.

Inside each WSL distro that should use ZFS, install the matching user-space packages from the same artifact:

```bash
sudo apt install ./*.deb
sudo modprobe zfs
modinfo zfs | head
```

## Runtime Validation

There is no hosted GitHub Actions smoke test for WSL runtime behavior. Editing and loading a custom WSL module VHD requires a real Windows WSL2 environment with administrator access, and GitHub-hosted runners are not a dependable target for that kind of nested virtualization test.

After installing the overlay and packages on a Windows machine, validate manually:

```bash
sudo modprobe zfs
lsmod | grep '^zfs'
truncate -s 1G /tmp/wsl2-zfs-smoke.img
sudo zpool create -f wsl2zfstest /tmp/wsl2-zfs-smoke.img
sudo zfs create wsl2zfstest/data
sudo dd if=/dev/urandom of=/wsl2zfstest/data/blob bs=1M count=64 status=none
sudo zpool scrub wsl2zfstest
sudo zpool status -x
sudo zpool destroy -f wsl2zfstest
rm -f /tmp/wsl2-zfs-smoke.img
```

## Rollback

Restore the `.wslconfig` backup created by the installer, or remove the `kernelModules=...` line from the `[wsl2]` section, then run:

```powershell
wsl --shutdown
```

That returns WSL to the stock module configuration. You can also remove `C:\WSL\wsl2_zfs\modules.vhd` and uninstall the generated OpenZFS packages inside a distro with `sudo apt remove` after exporting or destroying any test pools you created.

## Troubleshooting

- `Invalid boolean value for key 'wsl2.kernelModules'`: WSL is too old for `kernelModules`; update WSL first.
- `invalid module format` or unknown symbols: the ZFS overlay does not match the running `uname -r`; rebuild for the exact WSL kernel release.
- `wsl --mount` fails with an access error: run the installer from an elevated PowerShell session.
- `modprobe: FATAL: Module zfs not found`: confirm `.wslconfig` points at `C:\WSL\wsl2_zfs\modules.vhd`, run `wsl --shutdown`, then verify the matching `.deb` packages are installed inside the distro.
