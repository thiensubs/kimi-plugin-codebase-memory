#!/usr/bin/env bash
# scripts/build-all.sh — cross-build the darwin prebuilts with clang -target.
#
# Produces bin/prebuilt/darwin-x86_64/ and bin/prebuilt/darwin-arm64/ from c/*.c
# on any host whose clang can link for macOS (macOS with Xcode command line
# tools). Both arches come out of a single machine, so an Intel Mac can publish
# the Apple Silicon binary and the other way round.
#
# A target that clang cannot build is skipped with the compiler's own error and
# nothing is written for it: a half-built or renamed prebuilt would be worse
# than none. Every output is checked with `file` before it is installed.
#
# LINUX IS NOT BUILT HERE. linux-x86_64 and linux-arm64 need a Linux libc at
# link time, so CI builds them on ubuntu-latest and ubuntu-24.04-arm runners.
# This script never copies a darwin binary into a linux-* directory, and never
# marks a target built that it did not produce.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root" || exit 1

if ! command -v clang >/dev/null 2>&1; then
  echo "build-all.sh: clang not found; install clang (or Xcode command line tools)" >&2
  exit 1
fi

shopt -s nullglob
sources=(c/*.c)
shopt -u nullglob
if [ "${#sources[@]}" -eq 0 ]; then
  echo "build-all.sh: no sources matched c/*.c" >&2
  exit 1
fi

host_os=$(uname -s)
if [ "$host_os" != Darwin ]; then
  echo "build-all.sh: host is $host_os, not Darwin — the darwin targets need a macOS SDK and will be skipped."
fi

# <prebuilt dir suffix>:<clang triple>
targets=(darwin-x86_64:x86_64-apple-darwin darwin-arm64:arm64-apple-darwin)

stage=$root/.tmp/build-layer-cross
rm -rf "$stage"
mkdir -p "$stage"

built=()
skipped=()

for entry in "${targets[@]}"; do
  plat=${entry%%:*}
  triple=${entry#*:}
  want=${plat#darwin-}          # x86_64 | arm64, the arch `file` must report
  dir=$stage/$plat
  mkdir -p "$dir"

  ok=1
  detail=
  for src in "${sources[@]}"; do
    tool=${src##*/}
    tool=${tool%.c}
    if output=$(clang -target "$triple" -O2 -std=c11 -Wall -Wextra \
                  "$src" -o "$dir/$tool" 2>&1); then
      [ -n "$output" ] && printf '  %s %s: %s\n' "$plat" "$tool" "$output"
    else
      ok=0
      detail=$(printf '%s\n' "$output" | grep -m1 -E 'error|fatal error' || true)
      [ -n "$detail" ] || detail=$(printf '%s\n' "$output" | head -1)
      break
    fi
  done

  if [ "$ok" -eq 1 ] && command -v file >/dev/null 2>&1; then
    for binary in "$dir"/*; do
      desc=$(file -b "$binary")
      case $desc in
        *Mach-O*"$want"*) ;;
        *) ok=0; detail="file reports '$desc' for $(basename "$binary")"; break ;;
      esac
    done
  fi

  if [ "$ok" -ne 1 ]; then
    skipped+=("$plat")
    printf 'skip %-15s (%s): %s\n' "$plat" "$triple" "${detail:-clang could not build it}"
    rm -rf "$dir"
    continue
  fi

  mkdir -p "bin/prebuilt/$plat"
  for binary in "$dir"/*; do
    mv -f "$binary" "bin/prebuilt/$plat/"
  done
  built+=("$plat")
  printf 'built %-14s (%s): %s\n' "$plat" "$triple" "$(cd "bin/prebuilt/$plat" && echo *)"
done

rm -rf "$stage"

echo
if [ "${#built[@]}" -gt 0 ]; then
  echo "built:   ${built[*]}"
else
  echo "built:   nothing"
fi
if [ "${#skipped[@]}" -gt 0 ]; then
  echo "skipped: ${skipped[*]}"
fi
echo "note: linux-x86_64 and linux-arm64 prebuilts are produced by CI on Linux"
echo "      runners (they need a Linux libc at link time); this script never"
echo "      writes them."

[ "${#built[@]}" -gt 0 ]
