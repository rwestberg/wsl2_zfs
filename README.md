# WSL2 with ZFS

This repository builds OpenZFS for modern WSL2 without replacing the Microsoft WSL kernel. The primary artifact is a merged `modules.vhdx` for one exact WSL kernel release. It contains the stock WSL module tree plus OpenZFS kernel modules, and it is loaded through `.wslconfig` `kernelModules`.

## Requirements

- Store-delivered WSL new enough to support `[wsl2] kernelModules`.
- x86_64 WSL kernel. ARM64 is not built yet.
- A release artifact matching the exact WSL kernel shown by `uname -r`.
- OpenZFS user-space `.deb` packages from the same workflow run as the `modules.vhdx`.

Check the running kernel inside WSL:

```bash
uname -r
# Example: 6.18.26.1-microsoft-standard-WSL2
```

For that example, run the build workflow with `kernel_ver=6.18.26.1`. A module VHDX built for another kernel release will not load reliably.

## Build

Run the `Build` workflow manually.

Inputs:

- `kernel_ver`: exact WSL kernel version suffix, default `6.18.26.1`.
- `zfs_ver`: OpenZFS release, default `2.4.2`.
- `publish_release`: when true, publish a GitHub release named after the generated artifact.

The workflow produces:

- `wsl2-zfs-<kernel-release>-openzfs-<zfs-version>.modules.vhdx`
- OpenZFS user-space `.deb` packages
- `wsl2-zfs-<kernel-release>-openzfs-<zfs-version>.build-kit.tar.gz`
- `SHA256SUMS`

## Install

On Windows, install the module VHDX:

```powershell
.\scripts\install-wsl2-zfs.ps1 -ModulesVhdx .\wsl2-zfs-6.18.26.1-microsoft-standard-WSL2-openzfs-2.4.2.modules.vhdx
```

The installer copies the VHDX to `C:\WSL\wsl2_zfs\modules.vhdx`, backs up `%UserProfile%\.wslconfig` when it exists, updates only the `[wsl2] kernelModules` key, and runs `wsl --shutdown`.

Inside each WSL distro that should use ZFS, install the matching user-space packages from the same artifact:

```bash
sudo apt install ./*.deb
sudo modprobe zfs
modinfo zfs | head
```

## Runtime Validation

There is no hosted GitHub Actions smoke test for WSL runtime behavior. Loading a custom WSL module VHDX requires a real Windows WSL2 environment, and GitHub-hosted runners are not a dependable target for that kind of nested virtualization test.

After installing the VHDX and packages on a Windows machine, validate manually:

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

That returns WSL to the stock module configuration. You can also remove the generated OpenZFS packages inside a distro with `sudo apt remove` after exporting or destroying any test pools you created.

## Troubleshooting

- `Invalid boolean value for key 'wsl2.kernelModules'`: WSL is too old for `kernelModules`; update WSL first.
- `invalid module format` or unknown symbols: the VHDX does not match the running `uname -r`; rebuild for the exact WSL kernel release.
- `E_ACCESSDENIED` while loading the VHDX: keep the modules VHDX outside the user profile, for example under `C:\WSL\wsl2_zfs`.
- `modprobe: FATAL: Module zfs not found`: confirm `.wslconfig` points at the copied VHDX, run `wsl --shutdown`, then verify the matching `.deb` packages are installed inside the distro.
