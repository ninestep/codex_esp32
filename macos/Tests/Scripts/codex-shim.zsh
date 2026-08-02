#!/bin/zsh
set -euo pipefail

SCRIPT_PATH=${0:A}
MACOS_DIR=${SCRIPT_PATH:h:h:h}
REPO_ROOT=${MACOS_DIR:h}
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-shim-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

SHIM="$MACOS_DIR/Scripts/codex"
HOOK="$MACOS_DIR/Scripts/codex-remote-hook"
SOCKET="$TMP_DIR/helper.sock"
HELPER="$TMP_DIR/fake-helper"
REAL_CODEX="$TMP_DIR/real-codex"

fail() {
  print -u2 -- "FAIL: $*"
  exit 1
}

assert_file_equals() {
  local expected="$1"
  local actual="$2"
  diff -u "$expected" "$actual" >/dev/null || {
    diff -u "$expected" "$actual" >&2 || true
    fail "file mismatch: $actual"
  }
}

cat > "$HELPER" <<'EOS'
#!/bin/zsh
set -euo pipefail

print -r -- "$@" > "$HELPER_ARGS"
print -r -- "${CODEX_REMOTE_INSTANCE_ID:-}" > "$HELPER_ENV"

if [[ "$1" == "hook" ]]; then
  cat > "$HOOK_STDIN"
  exit "${HELPER_EXIT:-0}"
fi

while (( $# > 0 )); do
  case "$1" in
    --launcher)
      print -r -- "$2" > "$HELPER_LAUNCHER"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

exit "${HELPER_EXIT:-0}"
EOS
chmod +x "$HELPER"

cat > "$REAL_CODEX" <<'EOS'
#!/bin/zsh
set -euo pipefail

print -r -- "${CODEX_REMOTE_INSTANCE_ID:-}" > "$REAL_ENV"
for arg in "$@"; do
  print -r -- "$arg"
done > "$REAL_ARGS"
print -r -- "real stdout"
print -u2 -r -- "real stderr"
exit "${REAL_EXIT:-0}"
EOS
chmod +x "$REAL_CODEX"

HELPER_ARGS="$TMP_DIR/helper-args" \
HELPER_ENV="$TMP_DIR/helper-env" \
HELPER_LAUNCHER="$TMP_DIR/helper-launcher" \
HOOK_STDIN="$TMP_DIR/hook-stdin" \
REAL_ARGS="$TMP_DIR/real-args" \
REAL_ENV="$TMP_DIR/real-env" \
CODEX_REMOTE_HELPER="$HELPER" \
CODEX_REMOTE_SOCKET="$SOCKET" \
CODEX_REMOTE_REAL_CODEX="$REAL_CODEX" \
zsh "$SHIM" --model test-model "prompt with spaces" > "$TMP_DIR/stdout" 2> "$TMP_DIR/stderr"

print -r -- "real stdout" > "$TMP_DIR/expected-stdout"
print -r -- "real stderr" > "$TMP_DIR/expected-stderr"
assert_file_equals "$TMP_DIR/expected-stdout" "$TMP_DIR/stdout"
assert_file_equals "$TMP_DIR/expected-stderr" "$TMP_DIR/stderr"

{
  print -r -- "--model"
  print -r -- "test-model"
  print -r -- "prompt with spaces"
} > "$TMP_DIR/expected-real-args"
assert_file_equals "$TMP_DIR/expected-real-args" "$TMP_DIR/real-args"

launcher=$(<"$TMP_DIR/helper-launcher")
[[ "$launcher" == ${launcher:l} ]] || fail "launcher is not lowercase: $launcher"
[[ "$launcher" == ????????-????-????-????-???????????? ]] || fail "launcher is not UUID-like: $launcher"
assert_file_equals "$TMP_DIR/helper-launcher" "$TMP_DIR/helper-env"
assert_file_equals "$TMP_DIR/helper-launcher" "$TMP_DIR/real-env"

mkdir -p "$TMP_DIR/trailing-tmp"
HELPER_ARGS="$TMP_DIR/default-helper-args" \
HELPER_ENV="$TMP_DIR/default-helper-env" \
HELPER_LAUNCHER="$TMP_DIR/default-helper-launcher" \
REAL_ARGS="$TMP_DIR/default-real-args" \
REAL_ENV="$TMP_DIR/default-real-env" \
TMPDIR="$TMP_DIR/trailing-tmp/" \
CODEX_REMOTE_SOCKET="" \
CODEX_REMOTE_HELPER="$HELPER" \
CODEX_REMOTE_REAL_CODEX="$REAL_CODEX" \
zsh "$SHIM" "default socket" > "$TMP_DIR/default-stdout" 2> "$TMP_DIR/default-stderr"
expected_default_socket="$TMP_DIR/trailing-tmp/codex-remote-$UID/events.sock"
grep -q -- "--socket $expected_default_socket" "$TMP_DIR/default-helper-args" || fail "shim default socket path mismatch"

set +e
HELPER_ARGS="$TMP_DIR/no-real-helper-args" \
HELPER_ENV="$TMP_DIR/no-real-helper-env" \
HELPER_LAUNCHER="$TMP_DIR/no-real-helper-launcher" \
CODEX_REMOTE_HELPER="$HELPER" \
CODEX_REMOTE_SOCKET="$SOCKET" \
CODEX_REMOTE_REAL_CODEX="$TMP_DIR/no-real-codex" \
zsh "$SHIM" "no real" > "$TMP_DIR/no-real-stdout" 2> "$TMP_DIR/no-real-stderr"
exit_status=$?
set -e
[[ "$exit_status" == 127 ]] || fail "expected missing real codex exit 127, got $exit_status"
grep -q "real codex not found" "$TMP_DIR/no-real-stderr" || fail "missing real codex diagnostic"
[[ ! -e "$TMP_DIR/no-real-helper-args" ]] || fail "helper should not be contacted when real codex is missing"

set +e
HELPER_ARGS="$TMP_DIR/missing-helper-args" \
HELPER_ENV="$TMP_DIR/missing-helper-env" \
HELPER_LAUNCHER="$TMP_DIR/missing-helper-launcher" \
REAL_ARGS="$TMP_DIR/missing-real-args" \
REAL_ENV="$TMP_DIR/missing-real-env" \
CODEX_REMOTE_HELPER="$TMP_DIR/not-executable-helper" \
CODEX_REMOTE_SOCKET="$SOCKET" \
CODEX_REMOTE_REAL_CODEX="$REAL_CODEX" \
REAL_EXIT=23 \
zsh "$SHIM" "still runs" > "$TMP_DIR/missing-stdout" 2> "$TMP_DIR/missing-stderr"
exit_status=$?
set -e
[[ "$exit_status" == 23 ]] || fail "expected real codex exit 23, got $exit_status"
grep -q "helper unavailable" "$TMP_DIR/missing-stderr" || fail "missing helper warning"
grep -q "real stderr" "$TMP_DIR/missing-stderr" || fail "real stderr not preserved"

set +e
HELPER_ARGS="$TMP_DIR/failing-helper-args" \
HELPER_ENV="$TMP_DIR/failing-helper-env" \
HELPER_LAUNCHER="$TMP_DIR/failing-helper-launcher" \
REAL_ARGS="$TMP_DIR/failing-real-args" \
REAL_ENV="$TMP_DIR/failing-real-env" \
CODEX_REMOTE_HELPER="$HELPER" \
CODEX_REMOTE_SOCKET="$SOCKET" \
CODEX_REMOTE_REAL_CODEX="$REAL_CODEX" \
HELPER_EXIT=69 \
zsh "$SHIM" "register fails but still runs" > "$TMP_DIR/failing-stdout" 2> "$TMP_DIR/failing-stderr"
exit_status=$?
set -e
[[ "$exit_status" == 0 ]] || fail "expected real codex exit 0 after helper failure, got $exit_status"
grep -q "helper register-launch failed" "$TMP_DIR/failing-stderr" || fail "missing helper failure warning"
grep -q "real stderr" "$TMP_DIR/failing-stderr" || fail "real stderr missing after helper failure"

HOOK_INPUT='{"hook_event_name":"Stop","session_id":"codex-1"}'
printf '%s' "$HOOK_INPUT" | env \
  HELPER_ARGS="$TMP_DIR/default-hook-helper-args" \
  HELPER_ENV="$TMP_DIR/default-hook-helper-env" \
  HELPER_LAUNCHER="$TMP_DIR/default-hook-helper-launcher" \
  HOOK_STDIN="$TMP_DIR/default-hook-stdin" \
  TMPDIR="$TMP_DIR/trailing-tmp/" \
  CODEX_REMOTE_SOCKET="" \
  CODEX_REMOTE_HELPER="$HELPER" \
  zsh "$HOOK"
grep -q -- "--socket $expected_default_socket" "$TMP_DIR/default-hook-helper-args" || fail "hook default socket path mismatch"

printf '%s' "$HOOK_INPUT" | env \
  HELPER_ARGS="$TMP_DIR/hook-helper-args" \
  HELPER_ENV="$TMP_DIR/hook-helper-env" \
  HELPER_LAUNCHER="$TMP_DIR/hook-helper-launcher" \
  HOOK_STDIN="$TMP_DIR/hook-stdin" \
  CODEX_REMOTE_HELPER="$HELPER" \
  CODEX_REMOTE_SOCKET="$SOCKET" \
  zsh "$HOOK"

print -r -- "hook --socket $SOCKET" > "$TMP_DIR/expected-hook-args"
assert_file_equals "$TMP_DIR/expected-hook-args" "$TMP_DIR/hook-helper-args"
printf '%s' "$HOOK_INPUT" > "$TMP_DIR/expected-hook-stdin"
assert_file_equals "$TMP_DIR/expected-hook-stdin" "$TMP_DIR/hook-stdin"

set +e
env \
  CODEX_REMOTE_HELPER="$TMP_DIR/not-executable-helper" \
  CODEX_REMOTE_SOCKET="$SOCKET" \
  zsh "$HOOK" > "$TMP_DIR/hook-missing-stdout" 2> "$TMP_DIR/hook-missing-stderr"
exit_status=$?
set -e
[[ "$exit_status" == 69 ]] || fail "expected hook missing helper exit 69, got $exit_status"
grep -q "helper unavailable" "$TMP_DIR/hook-missing-stderr" || fail "missing hook helper warning"
