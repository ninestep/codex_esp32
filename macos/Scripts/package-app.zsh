#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
macos_dir=${script_dir:h}
configuration=${1:-release}
output_dir=${2:-"$macos_dir/dist"}
app_dir="$output_dir/Codex Remote.app"
local_signing_identity="Codex Remote Local Code Signing"
signing_identity=${CODE_SIGN_IDENTITY:-$local_signing_identity}

case "$configuration" in
  debug|release) ;;
  *) print -u2 "usage: package-app.zsh [debug|release] [output-dir]"; exit 64 ;;
esac

if [[ "$signing_identity" != "-" ]]; then
  if ! security find-identity -v -p codesigning | grep -Fq "$signing_identity"; then
    print -u2 "package signing identity unavailable: $signing_identity"
    print -u2 "set CODE_SIGN_IDENTITY=- only for disposable ad-hoc builds"
    exit 69
  fi
fi

swift build --package-path "$macos_dir" --disable-sandbox -c "$configuration"
bin_dir=$(swift build --package-path "$macos_dir" --disable-sandbox -c "$configuration" --show-bin-path)

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$macos_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
cp "$bin_dir/codex-remote-app" "$app_dir/Contents/MacOS/codex-remote-app"
cp "$bin_dir/codex-remote-helper" "$app_dir/Contents/MacOS/codex-remote-helper"
cp "$macos_dir/Scripts/codex" "$app_dir/Contents/Resources/codex"
cp "$macos_dir/Scripts/codex-remote-hook" "$app_dir/Contents/Resources/codex-remote-hook"
cp "$macos_dir/App/codex-remote-hooks.json" "$app_dir/Contents/Resources/codex-remote-hooks.json"
cp "$macos_dir/App/CodexRemote.icns" "$app_dir/Contents/Resources/CodexRemote.icns"
chmod 755 \
  "$app_dir/Contents/MacOS/codex-remote-app" \
  "$app_dir/Contents/MacOS/codex-remote-helper" \
  "$app_dir/Contents/Resources/codex" \
  "$app_dir/Contents/Resources/codex-remote-hook"
chmod 644 "$app_dir/Contents/Resources/codex-remote-hooks.json"
chmod 644 "$app_dir/Contents/Resources/CodexRemote.icns"

required_resources=(
  "$app_dir/Contents/Resources/codex"
  "$app_dir/Contents/Resources/codex-remote-hook"
  "$app_dir/Contents/Resources/codex-remote-hooks.json"
  "$app_dir/Contents/Resources/CodexRemote.icns"
)
for resource in $required_resources; do
  if [[ ! -f "$resource" || ! -r "$resource" ]]; then
    print -u2 "package validation failed: required readable resource missing: $resource"
    exit 66
  fi
done

codesign --force --deep --sign "$signing_identity" "$app_dir"
print -r -- "$app_dir"
