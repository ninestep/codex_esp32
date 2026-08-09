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

cjson_include_dirs=()
cjson_sources=()
cjson_link_flags=()

resolve_cjson() {
    local source_dir=""
    if [[ -n ${CJSON_DIR:-} ]]; then
        source_dir=${CJSON_DIR}
        if [[ ! -f ${source_dir}/cJSON.c || ! -f ${source_dir}/cJSON.h ]]; then
            print -u2 "CJSON_DIR must contain cJSON.c and cJSON.h: ${source_dir}"
            exit 69
        fi
    elif [[ -n ${IDF_PATH:-} && -f ${IDF_PATH}/components/json/cJSON/cJSON.c ]]; then
        source_dir=${IDF_PATH}/components/json/cJSON
    elif command -v brew >/dev/null 2>&1; then
        local brew_prefix
        if ! brew_prefix=$(brew --prefix cjson 2>/dev/null) \
            || [[ ! -f ${brew_prefix}/include/cjson/cJSON.h ]] \
            || [[ ! -e ${brew_prefix}/lib/libcjson.dylib && ! -e ${brew_prefix}/lib/libcjson.a ]]; then
            print -u2 "cJSON is unavailable; set CJSON_DIR or IDF_PATH, or install Homebrew cjson"
            exit 69
        fi
        cjson_include_dirs=(-I "${brew_prefix}/include/cjson")
        cjson_link_flags=(-L "${brew_prefix}/lib" -lcjson)
        return
    else
        print -u2 "cJSON is unavailable; set CJSON_DIR or IDF_PATH"
        exit 69
    fi

    cjson_include_dirs=(-I "${source_dir}")
    cjson_sources=("${source_dir}/cJSON.c")
}

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
    link_flags=()
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
        if (( ${#cjson_include_dirs} == 0 )); then
            resolve_cjson
        fi
        include_dirs+=(-I "${micro_dir}/include" "${cjson_include_dirs[@]}")
        target_sources+=("${micro_dir}/src/vendor_frame.c" "${micro_dir}/src/rpc_codec.c" "${micro_dir}/src/micro_state.c" "${micro_dir}/src/agent_status.c" "${cjson_sources[@]}")
        link_flags+=("${cjson_link_flags[@]}")
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
        "${link_flags[@]}" \
        -o "${build_dir}/${target}"
    "${build_dir}/${target}"
done
