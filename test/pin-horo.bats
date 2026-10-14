#!/usr/bin/env bats
# shellcheck disable=SC2154 # BATS_* are set by bats
# scripts/pin-horo.sh: a release's checksums.txt on stdin becomes horo.env.

bats_require_minimum_version 1.5.0

setup() {
  ACTION_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  OUT="$BATS_TEST_TMPDIR/horo.env"
  SUMS="aaaa  horo_1.2.3_darwin_arm64.tar.gz
bbbb  horo_1.2.3_linux_amd64.tar.gz
cccc  horo_1.2.3_linux_arm64.tar.gz
dddd  horoctl_1.2.3_linux_amd64.tar.gz"
}

pin() {
  run bash "$ACTION_ROOT/scripts/pin-horo.sh" "$@"
}

@test "each platform's sha256 is pinned with the version, without its v" {
  pin v1.2.3 "$OUT" <<< "$SUMS"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$OUT")" = "$(printf '%s\n' HORO_VERSION=1.2.3 HORO_SHA256_linux_amd64=bbbb \
    HORO_SHA256_linux_arm64=cccc HORO_SHA256_darwin_arm64=aaaa)" ]]
}

@test "a platform missing from checksums.txt fails and leaves the pin alone" {
  echo HORO_VERSION=1.0.0 > "$OUT"
  pin 1.2.3 "$OUT" <<< "$(grep -v linux_arm64 <<< "$SUMS")"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"horo_1.2.3_linux_arm64.tar.gz"* ]]
  [[ "$(cat "$OUT")" = HORO_VERSION=1.0.0 ]]
}

@test "a missing argument is a usage error" {
  pin 1.2.3 < /dev/null
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"usage"* ]]
}
