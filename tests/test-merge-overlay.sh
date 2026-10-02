#!/usr/bin/env bash
set -euo pipefail

merge_script=$1
work_root=$(mktemp -d)
trap 'rm -rf "$work_root"' EXIT
kernel_release=6.18.40.1-microsoft-standard-WSL2

fail() { echo "FAIL: $*" >&2; exit 1; }

# Run the actual embedded merge script with simulated disk and kmod commands.
# File copying and layout selection use the real implementations. No disks are touched.
mount() {
  case "$1" in
    -o)
      case "$3" in
        /dev/fixture-stock) cp -a "$FIXTURE_STOCK"/. "$4"/ ;;
        /dev/fixture-destination) printf '%s\n' "$4" > "$FIXTURE_CASE/destination-mount" ;;
        *) return 1 ;;
      esac
      ;;
    --bind)
      printf '%s\n' "$2" > "$FIXTURE_CASE/bind-source"
      printf '%s\n' "$3" > "$FIXTURE_CASE/bind-target"
      ;;
    *) return 1 ;;
  esac
}
umount() {
  if [ -f "$FIXTURE_CASE/destination-mount" ] && [ "$1" = "$(cat "$FIXTURE_CASE/destination-mount")" ]; then
    mkdir -p "$FIXTURE_CASE/result"
    cp -a "$1"/. "$FIXTURE_CASE/result"/
  fi
}
mkfs.ext4() {
  [ "$*" = '-F -q /dev/fixture-destination' ] || return 1
  touch "$FIXTURE_CASE/formatted"
}
depmod() {
  [ "$1" = '-b' ] && [ "$3" = "$FIXTURE_KERNEL" ] || return 1
  [ "$2/lib/modules/$3" = "$(cat "$FIXTURE_CASE/bind-target")" ] || return 1
  local module_root
  module_root=$(cat "$FIXTURE_CASE/bind-source")
  [ -f "$module_root/kernel/stock.ko" ] && [ -f "$module_root/extra/zfs.ko" ] || return 1
  printf '%s\n' 'extra/zfs.ko: kernel/stock.ko' > "$module_root/modules.dep"
}
modinfo() {
  [ "$1" = '-b' ] && [ "$3" = '-k' ] && [ "$4" = "$FIXTURE_KERNEL" ] && [ "$5" = zfs ] || return 1
  [ "$2/lib/modules/$4" = "$(cat "$FIXTURE_CASE/bind-target")" ] || return 1
  local module_root
  module_root=$(cat "$FIXTURE_CASE/bind-source")
  [ -f "$module_root/extra/zfs.ko" ] && [ -f "$module_root/modules.dep" ] || return 1
  touch "$FIXTURE_CASE/lookup-validated"
}
sync() { :; }
export -f mount umount mkfs.ext4 depmod modinfo sync

run_case() {
  local layout=$1 overlay_layout=$2
  local case_root="$work_root/$layout-$overlay_layout"
  local stock_root="$case_root/stock" overlay_root="$case_root/overlay"
  local stock_module_root=$stock_root overlay_module_root=$overlay_root
  local result_relative=.
  mkdir -p "$stock_root" "$overlay_root"
  case "$layout" in
    artifacts)
      stock_module_root="$stock_root/$kernel_release/modules"
      result_relative="$kernel_release/modules"
      mkdir -p "$stock_root/$kernel_release/linux-headers/include" "$stock_root/$kernel_release/perf/bin"
      printf 'headers\n' > "$stock_root/$kernel_release/linux-headers/include/fixture.h"
      printf 'perf\n' > "$stock_root/$kernel_release/perf/bin/perf"
      printf 'retain\n' > "$stock_root/other-artifact"
      ;;
    legacy-nested) stock_module_root="$stock_root/lib/modules/$kernel_release" ;;
    flat) ;;
  esac
  if [ "$overlay_layout" = nested ]; then
    overlay_module_root="$overlay_root/lib/modules/$kernel_release"
  fi
  mkdir -p "$stock_module_root/kernel" "$overlay_module_root/extra" "$overlay_module_root/.wsl2-zfs"
  printf 'stock\n' > "$stock_module_root/kernel/stock.ko"
  printf 'old index\n' > "$stock_module_root/modules.dep"
  printf 'zfs\n' > "$overlay_module_root/extra/zfs.ko"
  printf '%s\n' "$kernel_release" > "$overlay_module_root/.wsl2-zfs/KERNEL_RELEASE"
  printf '2.4.2\n' > "$overlay_module_root/.wsl2-zfs/ZFS_VERSION"
  FIXTURE_STOCK="$stock_root" FIXTURE_CASE="$case_root" FIXTURE_KERNEL="$kernel_release" \
    bash "$merge_script" "$overlay_root" "$kernel_release" --stock fixture-stock --destination fixture-destination > "$case_root/log" 2>&1 || {
      cat "$case_root/log"; fail "$layout with $overlay_layout overlay"
    }
  local result="$case_root/result/$result_relative"
  [ "$(cat "$result/kernel/stock.ko")" = stock ] || fail 'stock module not preserved'
  [ "$(cat "$result/extra/zfs.ko")" = zfs ] || fail 'ZFS module not merged'
  [ "$(cat "$result/modules.dep")" = 'extra/zfs.ko: kernel/stock.ko' ] || fail 'dependency index not regenerated at module root'
  [ -f "$case_root/lookup-validated" ] || fail 'module lookup not validated'
  [ "$(cat "$stock_module_root/modules.dep")" = 'old index' ] || fail 'stock tree was changed'
  if [ "$layout" = artifacts ]; then
    cmp "$stock_root/$kernel_release/linux-headers/include/fixture.h" "$case_root/result/$kernel_release/linux-headers/include/fixture.h" || fail 'headers not preserved'
    cmp "$stock_root/$kernel_release/perf/bin/perf" "$case_root/result/$kernel_release/perf/bin/perf" || fail 'perf not preserved'
    [ -f "$case_root/result/other-artifact" ] || fail 'other artifacts not preserved'
    [ ! -e "$case_root/result/extra" ] || fail 'overlay was merged at VHD root'
  fi
  echo "PASS: $layout stock image with $overlay_layout overlay"
}

for layout in artifacts flat legacy-nested; do
  for overlay_layout in flat nested; do
    run_case "$layout" "$overlay_layout"
  done
done

for invalid_layout in wrong-release unknown; do
  case_root="$work_root/$invalid_layout"
  mkdir -p "$case_root/stock" "$case_root/overlay"
  if [ "$invalid_layout" = wrong-release ]; then
    mkdir -p "$case_root/stock/6.18.26.1-microsoft-standard-WSL2/modules/kernel"
  fi
  if FIXTURE_STOCK="$case_root/stock" FIXTURE_CASE="$case_root" FIXTURE_KERNEL="$kernel_release" \
    bash "$merge_script" "$case_root/overlay" "$kernel_release" --stock fixture-stock --destination fixture-destination > "$case_root/log" 2>&1; then
    fail "$invalid_layout stock image was accepted"
  fi
  [ ! -e "$case_root/formatted" ] || fail "$invalid_layout image formatted a destination"
  grep -q 'could not find a stock WSL module tree' "$case_root/log" || { cat "$case_root/log"; fail 'unexpected rejection'; }
  echo "PASS: reject $invalid_layout image before formatting"
done
