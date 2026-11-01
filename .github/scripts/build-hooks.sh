#!/usr/bin/env bash
# Build every C hook in c/ for the machine running this script, twice:
#
#   bin/<name>                       host binary — what tests and local runs execute
#   bin/prebuilt/<os>-<arch>/<name>  release artifact for this runner's platform
#
# Platform tags are the ones the release archive uses:
#   linux-x86_64  linux-arm64  darwin-x86_64  darwin-arm64
#
# Linux reports arm64 as "aarch64", so the tag is normalised here rather than
# being guessed from uname output at package time.
#
# CC overrides the compiler; otherwise clang when present, else cc. The flag set
# is the plugin's contract (C11, -Wall -Wextra, zero warnings), so -Werror is on.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin | linux) ;;
  *)
    echo "build-hooks: unsupported OS '$os'" >&2
    exit 1
    ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64 | amd64) arch=x86_64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *)
    echo "build-hooks: unsupported architecture '$arch'" >&2
    exit 1
    ;;
esac

platform="$os-$arch"

if [ -n "${CC:-}" ]; then
  compiler=$CC
elif command -v clang >/dev/null 2>&1; then
  compiler=clang
else
  compiler=cc
fi

cflags=(-O2 -std=c11 -Wall -Wextra -Werror)

shopt -s nullglob
sources=(c/*.c)
if [ ${#sources[@]} -eq 0 ]; then
  echo "build-hooks: no C sources in c/" >&2
  exit 1
fi

"$compiler" --version | head -1

mkdir -p "bin/prebuilt/$platform"
for src in "${sources[@]}"; do
  name=$(basename "$src" .c)
  "$compiler" "${cflags[@]}" "$src" -o "bin/$name"
  cp "bin/$name" "bin/prebuilt/$platform/$name"
  echo "built bin/$name and bin/prebuilt/$platform/$name"
done

# The directory name is a promise; prove every binary in it matches.
if command -v file >/dev/null 2>&1; then
  case "$platform" in
    darwin-x86_64) want=x86_64 ;;
    darwin-arm64) want=arm64 ;;
    linux-x86_64) want=x86-64 ;;   # file(1) prints "x86-64" for ELF
    linux-arm64) want=aarch64 ;;   # file(1) prints "ARM aarch64" for ELF
  esac
  for bin in "bin/prebuilt/$platform"/*; do
    # No grep -q: it exits early and file(1) dies of SIGPIPE under pipefail.
    if ! file "$bin" | grep -E -- "$want" >/dev/null; then
      echo "build-hooks: $bin does not match $platform" >&2
      file "$bin" >&2
      exit 1
    fi
  done
  echo "verified architecture: $platform"
else
  echo "build-hooks: file(1) not available, skipping architecture check" >&2
fi
