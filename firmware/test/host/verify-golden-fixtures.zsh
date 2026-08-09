#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h:h}

cd "$repo_root"
zsh firmware/test/host/run-tests.zsh test_codec test_message_codec >/dev/null
zsh macos/Tests/Scripts/ble-golden-fixtures.zsh

declared_count=$(rg -c '"file" : ".+\.hex"' macos/Fixtures/ble-v1/manifest.json)
actual_count=$(find macos/Fixtures/ble-v1 -maxdepth 1 -type f -name '*.hex' | wc -l | tr -d ' ')
if [[ "$declared_count" != 18 || "$actual_count" != 18 ]]; then
    print -u2 "expected 18 declared fixtures, found declared=$declared_count actual=$actual_count"
    exit 65
fi
