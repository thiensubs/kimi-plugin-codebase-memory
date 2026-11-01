#!/usr/bin/env bash
# build-c.sh — build every C hook tool for this host.
#
# One command, no arguments: compiles each c/*.c with -O2 -std=c11 -Wall -Wextra
# into bin/prebuilt/<os>-<arch>/<tool>, which bin/run loads first. It also
# refreshes bin/<tool>, the path the manifest named before the dispatcher
# existed, so either manifest keeps working.
#
# The host's own platform only. scripts/build-all.sh cross-builds the two
# darwin targets; linux-* prebuilts come from CI on Linux runners.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

case "$(uname -sm)" in
  "Darwin x86_64")                plat=darwin-x86_64 ;;
  "Darwin arm64"|"Darwin arm64e") plat=darwin-arm64 ;;
  "Linux x86_64")                 plat=linux-x86_64 ;;
  "Linux aarch64"|"Linux arm64"|"Linux arm64e") plat=linux-arm64 ;;
  *) echo "build-c.sh: unsupported platform: $(uname -sm)" >&2; exit 1 ;;
esac

cc=
for candidate in "${CC:-}" cc clang; do
  [ -n "$candidate" ] || continue
  if command -v "$candidate" >/dev/null 2>&1; then
    cc=$candidate
    break
  fi
done
if [ -z "$cc" ]; then
  echo "build-c.sh: no C compiler found; install clang or set CC=/path/to/cc" >&2
  exit 1
fi

shopt -s nullglob
sources=(c/*.c)
shopt -u nullglob
if [ "${#sources[@]}" -eq 0 ]; then
  echo "build-c.sh: no sources matched c/*.c" >&2
  exit 1
fi

outdir=bin/prebuilt/"$plat"
mkdir -p "$outdir" bin

echo "build-c.sh: $cc for $plat"
for src in "${sources[@]}"; do
  tool=${src##*/}
  tool=${tool%.c}
  "$cc" -O2 -std=c11 -Wall -Wextra "$src" -o "$outdir/$tool"
  cp -f "$outdir/$tool" "bin/$tool"
  echo "  $outdir/$tool  (also bin/$tool)"
done
