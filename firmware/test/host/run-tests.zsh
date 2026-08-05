#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h:h}
core_dir=${repo_root}/firmware/components/codex_remote_core
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-remote-firmware-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT

targets=("$@")
if (( ${#targets} == 0 )); then
    targets=(all)
fi
if [[ ${targets[1]} == all ]]; then
    targets=(test_codec test_message_codec test_device_state test_input_state test_audio_frame test_asset_state test_power_state)
fi

source_files=(${core_dir}/src/*.c(N))

cd "$repo_root"
for target in "${targets[@]}"; do
    test_file=${script_dir}/${target}.c
    if [[ ! -f "$test_file" ]]; then
        print -u2 "missing test target: $test_file"
        exit 66
    fi

    xcrun clang \
        -std=c17 \
        -Wall -Wextra -Werror -Wpedantic \
        -fsanitize=address,undefined \
        -fno-omit-frame-pointer \
        -I "${core_dir}/include" \
        "$test_file" "${source_files[@]}" \
        -o "${build_dir}/${target}"
    "${build_dir}/${target}"
done
