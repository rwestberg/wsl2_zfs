# WSL2 with ZFS

This repository builds OpenZFS install bundles for stock WSL2 kernels. Each bundle targets one exact WSL kernel release and contains a ZFS module overlay plus matching OpenZFS runtime packages. The Windows installer creates a local writable modules VHDX beside Microsoft’s stock WSL files, merges the ZFS modules into it, and updates `.wslconfig` with the stock `kernel` path plus the generated `kernelModules` VHDX.

## Requirements

- Store-delivered WSL new enough to support `[wsl2] kernelModules`.
- Microsoft’s stock WSL kernel at `C:\Program Files\WSL\tools\kernel`. WSL requires a `kernel` setting when `kernelModules` is set.
- x86_64 WSL kernel.
- Administrator access on Windows. The installer uses `wsl --mount` to edit a copied modules VHD.
- An installed WSL distro with `depmod`, `modinfo`, and `mkfs.ext4` available.
- A Debian/Ubuntu-style WSL distro with `apt-get` when using `-InstallDebs`.
- A release artifact matching the exact WSL kernel shown by `uname -r`.

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

- `<artifact-base>`: the install artifact, containing the ZFS module overlay, OpenZFS runtime `.deb` packages, `ARTIFACTS.txt`, and `SHA256SUMS`.

When `publish_release=true`, the release contains the same bundle as a zip file.

## Install

Run the Windows installer from an elevated PowerShell session:

```powershell
.\scripts\install-wsl2-zfs.ps1 -InstallBundle .\wsl2-zfs-6.18.26.1-microsoft-standard-WSL2-openzfs-2.4.2.zip -Distro Debian -InstallDebs
```

The installer creates `C:\Program Files\WSL\tools\modules_zfs-2.4.2.vhdx` by default. It copies Microsoft’s stock module tree from `C:\Program Files\WSL\tools\modules.vhd`, merges the ZFS modules, runs `depmod`, backs up `%UserProfile%\.wslconfig`, updates only the `[wsl2] kernel` and `kernelModules` keys, and runs `wsl --shutdown`. Use `-DestinationDirectory` to place the generated VHDX somewhere else.

With `-InstallDebs`, the installer also installs the bundled runtime `.deb` packages into the selected WSL distro. Use `-Distro <name>` to pick the distro; otherwise the default WSL distro is used. For manual distro package installs, extract the same bundle and run:

```bash
sudo apt install ./*.deb
sudo modprobe zfs
modinfo zfs | head
zfs --version
```

The `zfs --version` output should report the same OpenZFS version for both user space and `zfs-kmod`. If the first line still shows a distro package version, install the runtime debs from the same install bundle.

## Runtime Validation

After installing the bundle on a Windows WSL2 machine, validate manually:

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

Restore the `.wslconfig` backup created by the installer, or remove the `kernel=...` and `kernelModules=...` lines from the `[wsl2]` section, then run:

```powershell
wsl --shutdown
```

That returns WSL to the stock module configuration. You can also remove the generated `C:\Program Files\WSL\tools\modules_zfs-*.vhdx` file and uninstall the generated OpenZFS packages inside a distro with `sudo apt remove` after exporting or destroying any test pools you created.

## Troubleshooting

- `Invalid boolean value for key 'wsl2.kernelModules'`: WSL is too old for `kernelModules`; update WSL first.
- `invalid module format` or unknown symbols: the ZFS overlay does not match the running `uname -r`; rebuild for the exact WSL kernel release.
- `wsl --mount` fails with an access error: run the installer from an elevated PowerShell session.
- `WSL_E_CUSTOM_KERNEL_NOT_FOUND`: `kernelModules` is set without a `kernel` path. Re-run the installer to repair the config, or add `kernel=C:\\Program Files\\WSL\\tools\\kernel` to the `[wsl2]` section.
- `modprobe: FATAL: Module zfs not found`: confirm `.wslconfig` points `kernel` at `C:\Program Files\WSL\tools\kernel` and `kernelModules` at the generated `C:\Program Files\WSL\tools\modules_zfs-*.vhdx`, run `wsl --shutdown`, then verify the matching `.deb` packages are installed inside the distro.
- `zfs --version` shows different user-space and `zfs-kmod` versions: the kernel module loaded, but the distro's ZFS tools are still first on the system. Install the runtime `.deb` packages from the matching install bundle.
