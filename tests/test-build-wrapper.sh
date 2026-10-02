#!/usr/bin/env bash
set -euo pipefail

container_script=$1
work_root=$(mktemp -d)
trap 'rm -rf "$work_root"' EXIT

# Simulate dependencies, compilation, and ownership changes while running the
# workflow's actual shell body. No packages, builds, or ownership changes occur.
apt-get() {
  printf 'apt-%s\n' "$1" >> "$FIXTURE_LOG"
  case "$1" in
    update) return "$UPDATE_EXIT" ;;
    install) return "$INSTALL_EXIT" ;;
    *) return 99 ;;
  esac
}
bash() {
  printf 'build\n' >> "$FIXTURE_LOG"
  return "$BUILD_EXIT"
}
chown() {
  printf 'chown\n' >> "$FIXTURE_LOG"
  return "$CHOWN_EXIT"
}
export -f apt-get bash chown

run_case() {
  local name=$1 update_exit=$2 install_exit=$3 build_exit=$4 chown_exit=$5 expected_exit=$6 expected_commands=$7
  local log="$work_root/$name.log" actual_exit=0
  FIXTURE_LOG="$log" UPDATE_EXIT="$update_exit" INSTALL_EXIT="$install_exit" \
    BUILD_EXIT="$build_exit" CHOWN_EXIT="$chown_exit" HOST_UID=1000 HOST_GID=1000 \
    command bash "$container_script" || actual_exit=$?
  if [ "$actual_exit" -ne "$expected_exit" ]; then
    echo "FAIL: $name expected exit $expected_exit, got $actual_exit" >&2
    exit 1
  fi
  if [ "$(cat "$log")" != "$expected_commands" ]; then
    echo "FAIL: $name ran unexpected commands" >&2
    cat "$log" >&2
    exit 1
  fi
  echo "PASS: container $name"
}

run_case update-failure 31 0 0 0 31 'apt-update'
run_case install-failure 0 32 0 0 32 $'apt-update\napt-install'
run_case build-failure 0 0 42 0 42 $'apt-update\napt-install\nbuild'
run_case ownership-failure 0 0 0 43 43 $'apt-update\napt-install\nbuild\nchown'
run_case success 0 0 0 0 0 $'apt-update\napt-install\nbuild\nchown'
