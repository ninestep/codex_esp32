#!/bin/zsh
set -eu

repo_root=${0:A:h:h:h:h}
fixture_dir="$repo_root/macos/Fixtures/ble-v1"
generated_dir=$(mktemp -d "${TMPDIR%/}/codex-remote-ble-fixtures.XXXXXX")
log_file="$generated_dir/swift-test.log"

cleanup() {
  rm -rf "$generated_dir"
}
trap cleanup EXIT

if ! BLE_FIXTURE_OUTPUT_DIR="$generated_dir/output" swift test \
  --package-path "$repo_root/macos" \
  --filter BLEGoldenFixtureTests/testGenerateFixtures >"$log_file" 2>&1; then
  cat "$log_file" >&2
  exit 1
fi

if ! diff -ru "$fixture_dir" "$generated_dir/output" >/dev/null; then
  diff -ru "$fixture_dir" "$generated_dir/output" >&2 || true
  exit 1
fi
