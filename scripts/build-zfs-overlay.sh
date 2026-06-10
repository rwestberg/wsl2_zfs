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

KERNEL_VER=${KERNEL_VER:?KERNEL_VER must be set, for example 6.18.26.1}
ZFS_VER=${ZFS_VER:?ZFS_VER must be set, for example 2.4.2}
ROOT_DIR=${ROOT_DIR:-"$PWD"}
WORK_DIR=${WORK_DIR:-"$ROOT_DIR/build"}
ARTIFACT_DIR=${ARTIFACT_DIR:-"$ROOT_DIR/artifacts"}
NPROC=${NPROC:-$(nproc)}

require_command curl
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
ZFS_MODROOT="$WORK_DIR/zfs-modules"
ZFS_OVERLAY_ROOT="$WORK_DIR/zfs-module-overlay"

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
ZFS_MODULES_PATH="$ARTIFACT_DIR/${ARTIFACT_BASE}.zfs-modules.tar.gz"

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

log "Building OpenZFS kernel modules"
make -C "$ZFS_MODULE_DIR/module" -j"$NPROC"

log "Installing OpenZFS kernel modules into overlay tree"
make -C "$ZFS_MODULE_DIR/module" INSTALL_MOD_PATH="$ZFS_MODROOT" INSTALL_MOD_STRIP=1 DEPMOD=true modules_install
[[ -d "$ZFS_MODROOT/lib/modules/$KERNEL_RELEASE" ]] ||
  fail "zfs module install did not create $ZFS_MODROOT/lib/modules/$KERNEL_RELEASE"
ZFS_KO=$(find "$ZFS_MODROOT/lib/modules/$KERNEL_RELEASE" -type f -name 'zfs.ko*' -print -quit)
[[ -n "$ZFS_KO" ]] || fail "zfs kernel module was not installed into overlay module tree"

log "Packaging OpenZFS module overlay"
mkdir -p "$ZFS_OVERLAY_ROOT/.wsl2-zfs"
cp -a "$ZFS_MODROOT/lib/modules/$KERNEL_RELEASE"/. "$ZFS_OVERLAY_ROOT"/
find "$ZFS_OVERLAY_ROOT" -maxdepth 1 -type f -name 'modules.*' -delete
rm -f "$ZFS_OVERLAY_ROOT/build" "$ZFS_OVERLAY_ROOT/source"
printf '%s\n' "$KERNEL_RELEASE" > "$ZFS_OVERLAY_ROOT/.wsl2-zfs/KERNEL_RELEASE"
printf '%s\n' "$ZFS_VER" > "$ZFS_OVERLAY_ROOT/.wsl2-zfs/ZFS_VERSION"
tar -C "$ZFS_OVERLAY_ROOT" -czf "$ZFS_MODULES_PATH" .

log "Validating staged zfs module"
ZFS_MODINFO=$(modinfo "$ZFS_KO")
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

log "Collecting OpenZFS Debian packages"
RUNTIME_DEBS=()
while IFS= read -r -d '' deb; do
  deb_name=$(basename "$deb")
  case "$deb_name" in
    openzfs-libnvpair3_*.deb|openzfs-libuutil3_*.deb|openzfs-libzfs7_*.deb|openzfs-libzfsbootenv1_*.deb|openzfs-libzpool7_*.deb|openzfs-python3-pyzfs_*.deb|openzfs-zfs-zed_*.deb|openzfs-zfsutils_*.deb)
      cp "$deb" "$ARTIFACT_DIR/"
      RUNTIME_DEBS+=("$deb_name")
      ;;
    *)
      log "Skipping non-runtime package $deb_name"
      ;;
  esac
done < <(find "$WORK_DIR" -maxdepth 2 -type f -name '*.deb' -print0)
(( ${#RUNTIME_DEBS[@]} > 0 )) || fail "no OpenZFS runtime Debian packages were collected"

write_artifact_index() {
  local manifest="ARTIFACTS.txt"
  local sums="SHA256SUMS"

  log "Writing artifact manifest and checksums"
  (
    cd "$ARTIFACT_DIR"
    : > "$manifest"
    for artifact in "$@"; do
      [[ -f "$artifact" ]] || fail "missing artifact: $artifact"
      printf '%s  %s\n' "$(stat -c '%s' "$artifact")" "$artifact"
    done | sort -n > "$manifest"
    cat "$manifest"
    sha256sum "$@" > "$sums"
  )
}

write_artifact_index "$(basename "$ZFS_MODULES_PATH")" "${RUNTIME_DEBS[@]}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'kernel_release=%s\n' "$KERNEL_RELEASE"
    printf 'artifact_base=%s\n' "$ARTIFACT_BASE"
    printf 'artifact_dir=%s\n' "$ARTIFACT_DIR"
    printf 'zfs_modules=%s\n' "$ZFS_MODULES_PATH"
  } >> "$GITHUB_OUTPUT"
fi

log "Artifacts written to $ARTIFACT_DIR"
