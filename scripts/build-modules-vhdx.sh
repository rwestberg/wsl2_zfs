#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

copy_if_exists() {
  local source=$1
  local destination=$2

  if [[ -e "$source" ]]; then
    mkdir -p "$destination"
    cp -a "$source" "$destination/"
  fi
}

KERNEL_VER=${KERNEL_VER:?KERNEL_VER must be set, for example 6.18.26.1}
ZFS_VER=${ZFS_VER:?ZFS_VER must be set, for example 2.4.2}
ROOT_DIR=${ROOT_DIR:-"$PWD"}
WORK_DIR=${WORK_DIR:-"$ROOT_DIR/build"}
ARTIFACT_DIR=${ARTIFACT_DIR:-"$ROOT_DIR/artifacts"}
NPROC=${NPROC:-$(nproc)}

require_command curl
require_command depmod
require_command dpkg-deb
require_command make
require_command modinfo
require_command sha256sum
require_command tar

reset_dir() {
  local dir=$1
  [[ -n "$dir" ]] || fail "refusing to reset an empty path"
  [[ "$dir" != "/" ]] || fail "refusing to reset /"
  rm -rf "$dir"
  mkdir -p "$dir"
}

reset_dir "$WORK_DIR"
reset_dir "$ARTIFACT_DIR"

KERNEL_ARCHIVE="$WORK_DIR/wsl2-kernel.tar.gz"
KERNEL_DIR="$WORK_DIR/WSL2-Linux-Kernel-linux-msft-wsl-${KERNEL_VER}"
ZFS_ARCHIVE="$WORK_DIR/zfs.tar.gz"
ZFS_EXTRACTED_DIR="$WORK_DIR/zfs-${ZFS_VER}"
ZFS_MODULE_DIR="$WORK_DIR/zfs-${ZFS_VER}-modules"
ZFS_PACKAGE_DIR="$WORK_DIR/zfs-${ZFS_VER}-packages"
STOCK_MODROOT="$WORK_DIR/stock-modules"
MERGED_MODROOT="$WORK_DIR/merged-modules"

log "Fetching WSL kernel linux-msft-wsl-${KERNEL_VER}"
curl -fL "https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/tags/linux-msft-wsl-${KERNEL_VER}.tar.gz" -o "$KERNEL_ARCHIVE"
tar -xzf "$KERNEL_ARCHIVE" -C "$WORK_DIR"
[[ -d "$KERNEL_DIR" ]] || fail "kernel archive did not extract to $KERNEL_DIR"

CONFIG_FILE="$KERNEL_DIR/Microsoft/config-wsl"
[[ -e "$CONFIG_FILE" ]] || fail "missing WSL kernel config at $CONFIG_FILE"
grep -Eq '^CONFIG_MODULES=y$' "$CONFIG_FILE" || fail "stock WSL config must contain CONFIG_MODULES=y"
grep -Eq '^CONFIG_MODVERSIONS=y$' "$CONFIG_FILE" || fail "stock WSL config must contain CONFIG_MODVERSIONS=y"

log "Building matching WSL kernel"
make -C "$KERNEL_DIR" -j"$NPROC" KCONFIG_CONFIG=Microsoft/config-wsl
[[ -s "$KERNEL_DIR/Module.symvers" ]] || fail "full kernel build did not create Module.symvers"

KERNEL_RELEASE=$(make -C "$KERNEL_DIR" -s KCONFIG_CONFIG=Microsoft/config-wsl kernelrelease)
[[ -n "$KERNEL_RELEASE" ]] || fail "could not determine kernel release"
ARTIFACT_BASE="wsl2-zfs-${KERNEL_RELEASE}-openzfs-${ZFS_VER}"
VHDX_PATH="$ARTIFACT_DIR/${ARTIFACT_BASE}.modules.vhdx"
BUILD_KIT_PATH="$ARTIFACT_DIR/${ARTIFACT_BASE}.build-kit.tar.gz"

log "Installing stock WSL modules into staging tree"
make -C "$KERNEL_DIR" INSTALL_MOD_PATH="$STOCK_MODROOT" modules_install

log "Fetching OpenZFS ${ZFS_VER}"
curl -fL "https://github.com/openzfs/zfs/releases/download/zfs-${ZFS_VER}/zfs-${ZFS_VER}.tar.gz" -o "$ZFS_ARCHIVE"
tar -xzf "$ZFS_ARCHIVE" -C "$WORK_DIR"
[[ -d "$ZFS_EXTRACTED_DIR" ]] || fail "OpenZFS archive did not extract to $ZFS_EXTRACTED_DIR"
mv "$ZFS_EXTRACTED_DIR" "$ZFS_MODULE_DIR"

log "Configuring OpenZFS kernel modules for ${KERNEL_RELEASE}"
(
  cd "$ZFS_MODULE_DIR"
  export KVERS="$KERNEL_RELEASE"
  export KSRC="$KERNEL_DIR"
  export KOBJ="$KERNEL_DIR"
  ./configure --with-linux="$KERNEL_DIR" --with-linux-obj="$KERNEL_DIR"
)

log "Preparing merged stock module tree"
mkdir -p "$MERGED_MODROOT"
cp -a "$STOCK_MODROOT"/. "$MERGED_MODROOT"/

log "Building and installing OpenZFS kernel modules into merged tree"
make -C "$ZFS_MODULE_DIR/module" -j"$NPROC"
make -C "$ZFS_MODULE_DIR/module" INSTALL_MOD_PATH="$MERGED_MODROOT" modules_install

find "$MERGED_MODROOT/lib/modules/$KERNEL_RELEASE" -type f -name 'zfs.ko*' -print -quit | grep -q . ||
  fail "zfs kernel module was not installed into merged module tree"

depmod -b "$MERGED_MODROOT" "$KERNEL_RELEASE"

log "Validating staged zfs module"
ZFS_MODINFO=$(modinfo -b "$MERGED_MODROOT" -k "$KERNEL_RELEASE" zfs)
printf '%s\n' "$ZFS_MODINFO"
printf '%s\n' "$ZFS_MODINFO" | grep -E '^vermagic:' | grep -F "$KERNEL_RELEASE" >/dev/null ||
  fail "zfs module vermagic does not match $KERNEL_RELEASE"

log "Building OpenZFS user-space Debian packages"
tar -xzf "$ZFS_ARCHIVE" -C "$WORK_DIR"
[[ -d "$ZFS_EXTRACTED_DIR" ]] || fail "OpenZFS package archive did not extract to $ZFS_EXTRACTED_DIR"
mv "$ZFS_EXTRACTED_DIR" "$ZFS_PACKAGE_DIR"
(
  cd "$ZFS_PACKAGE_DIR"
  ./configure
  make -j1 native-deb-utils
)

log "Generating merged modules VHDX"
SUDO_CMD=()
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO_CMD=("${SUDO:-sudo}")
fi
"${SUDO_CMD[@]}" "$KERNEL_DIR/Microsoft/scripts/gen_modules_vhdx.sh" "$MERGED_MODROOT" "$KERNEL_RELEASE" "$VHDX_PATH"
[[ -s "$VHDX_PATH" ]] || fail "modules VHDX was not created at $VHDX_PATH"

log "Packaging kernel build metadata"
BUILD_KIT_DIR="$WORK_DIR/build-kit"
mkdir -p "$BUILD_KIT_DIR"
copy_if_exists "$KERNEL_DIR/Module.symvers" "$BUILD_KIT_DIR"
copy_if_exists "$KERNEL_DIR/.config" "$BUILD_KIT_DIR"
copy_if_exists "$KERNEL_DIR/Makefile" "$BUILD_KIT_DIR"
copy_if_exists "$KERNEL_DIR/Kbuild" "$BUILD_KIT_DIR"
copy_if_exists "$KERNEL_DIR/include/config" "$BUILD_KIT_DIR/include"
copy_if_exists "$KERNEL_DIR/include/generated" "$BUILD_KIT_DIR/include"
copy_if_exists "$KERNEL_DIR/arch/x86/include/generated" "$BUILD_KIT_DIR/arch/x86/include"
copy_if_exists "$KERNEL_DIR/scripts/basic" "$BUILD_KIT_DIR/scripts"
copy_if_exists "$KERNEL_DIR/scripts/mod" "$BUILD_KIT_DIR/scripts"
copy_if_exists "$KERNEL_DIR/scripts/module.lds" "$BUILD_KIT_DIR/scripts"
tar -C "$BUILD_KIT_DIR" -czf "$BUILD_KIT_PATH" .

log "Collecting OpenZFS Debian packages"
while IFS= read -r -d '' deb; do
  deb_name=$(basename "$deb")
  case "$deb_name" in
    *dkms*.deb|*dracut*.deb)
      log "Skipping source/rebuild package $deb_name"
      ;;
    *)
      cp "$deb" "$ARTIFACT_DIR/"
      ;;
  esac
done < <(find "$WORK_DIR" -maxdepth 2 -type f -name '*.deb' -print0)

log "Writing checksums"
(
  cd "$ARTIFACT_DIR"
  sha256sum ./* > SHA256SUMS
)

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'kernel_release=%s\n' "$KERNEL_RELEASE"
    printf 'artifact_base=%s\n' "$ARTIFACT_BASE"
    printf 'artifact_dir=%s\n' "$ARTIFACT_DIR"
    printf 'modules_vhdx=%s\n' "$VHDX_PATH"
  } >> "$GITHUB_OUTPUT"
fi

log "Artifacts written to $ARTIFACT_DIR"
