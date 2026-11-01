#!/usr/bin/env bash
# Run the plugin's test suite. Called by ci.yml and release.yml.
#
# Contract: tests/run-tests.sh, when it exists, is the canonical runner and must
# itself execute every tests/test-*.sh. When it does not exist, every
# tests/test-*.sh is executed here. A checkout with no tests at all exits 0 with
# a notice, so the pipeline stays green while the suite lands in parallel.
#
# KIMI_CODE_HOME is honoured but never required: the hook binary only writes
# there when it cannot parse a payload, and CI points it at a temp directory.
set -uo pipefail
shopt -s nullglob

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

if [ -n "${KIMI_CODE_HOME:-}" ]; then
  mkdir -p "$KIMI_CODE_HOME/logs"
fi

ran=0
failed=0

run_file() {
  echo "::group::$1"
  if bash "$1"; then
    echo "::endgroup::"
  else
    failed=$((failed + 1))
    echo "::endgroup::"
  fi
  ran=$((ran + 1))
}

if [ -f tests/run-tests.sh ]; then
  echo "tests/run-tests.sh present — using it as the canonical runner"
  run_file tests/run-tests.sh
else
  for t in tests/test-*.sh; do
    run_file "$t"
  done
fi

if [ "$ran" -eq 0 ]; then
  echo "No tests yet (tests/run-tests.sh and tests/test-*.sh are both absent) — nothing to run."
  exit 0
fi

echo "test files run: $ran, failed: $failed"
if [ "$failed" -ne 0 ]; then
  echo "::error::$failed test file(s) failed"
  exit 1
fi
