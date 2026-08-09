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
    targets=(test_codec test_message_codec test_device_state test_input_state test_interaction_policy test_connection_mode test_codex_micro_vendor_frame test_codex_micro_state test_codex_micro_agent_status test_audio_frame test_audio_runtime test_asset_state test_power_state test_ble_advertising test_ble_connection_order test_display_runtime)
fi

source_files=(${core_dir}/src/*.c(N))

cd "$repo_root"
for target in "${targets[@]}"; do
    test_file=${script_dir}/${target}.c
    if [[ ! -f "$test_file" ]]; then
        print -u2 "missing test target: $test_file"
        exit 66
    fi

    include_dirs=(-I "${core_dir}/include")
    target_sources=("${source_files[@]}")
    extra_flags=()
    if [[ ${target} == test_device_state ]]; then
        xcrun clang \
            -std=c17 \
            -Wall -Wextra -Werror -Wpedantic \
            -Wframe-larger-than=1024 \
            "${include_dirs[@]}" \
            -c "${core_dir}/src/device_state.c" \
            -o "${build_dir}/device_state-stack-check.o"
    fi
    if [[ ${target} == test_codex_micro_vendor_frame || ${target} == test_codex_micro_state || ${target} == test_codex_micro_agent_status ]]; then
        micro_dir=${repo_root}/firmware/components/codex_micro_hid
        cjson_dir=/Users/wj/esp/esp-idf-v5.5.4/components/json/cJSON
        include_dirs+=(-I "${micro_dir}/include" -I "${cjson_dir}")
        target_sources+=("${micro_dir}/src/vendor_frame.c" "${micro_dir}/src/rpc_codec.c" "${micro_dir}/src/micro_state.c" "${micro_dir}/src/agent_status.c" "${cjson_dir}/cJSON.c")
        extra_flags+=(-Wno-deprecated-declarations)
    elif [[ ${target} == test_ble_advertising ]]; then
        ble_dir=${repo_root}/firmware/components/codex_remote_ble
        include_dirs+=(-I "${ble_dir}/include")
        target_sources+=("${ble_dir}/src/advertising_layout.c")
    elif [[ ${target} == test_display_runtime ]]; then
        include_dirs+=(-I "${repo_root}/firmware/main")
    fi

    xcrun clang \
        -std=c17 \
        -Wall -Wextra -Werror -Wpedantic \
        -fsanitize=address,undefined \
        -fno-omit-frame-pointer \
        "${extra_flags[@]}" \
        "${include_dirs[@]}" \
        "$test_file" "${target_sources[@]}" \
        -o "${build_dir}/${target}"
    "${build_dir}/${target}"
done
