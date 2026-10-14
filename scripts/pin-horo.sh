#!/usr/bin/env bash
# Pins horo: reads a horopter release's checksums.txt on stdin and writes the version and each
# supported platform's sha256 to the given file, which src/record.sh verifies downloads against.
#   gh release download v0.12.0 -R horopter-dev/horopter -p checksums.txt -O - |
#     scripts/pin-horo.sh v0.12.0 horo.env
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: pin-horo.sh <version> <file> < checksums.txt" >&2
  exit 2
fi
version="${1#v}" out="$2" sums="$(cat)"
pin="HORO_VERSION=$version"
for platform in linux_amd64 linux_arm64 darwin_arm64; do
  asset="horo_${version}_${platform}.tar.gz"
  sha="$(awk -v asset="$asset" '$2 == asset { print $1 }' <<< "$sums")"
  if [[ -z "$sha" ]]; then
    echo "pin-horo.sh: checksums.txt has no line for $asset" >&2
    exit 1
  fi
  pin+=$'\n'"HORO_SHA256_$platform=$sha"
done
printf '%s\n' "$pin" > "$out"
