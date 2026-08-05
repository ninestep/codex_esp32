idf_component_register(
    SRCS
        "src/audio_frame.c"
        "src/asset_state.c"
        "src/codec.c"
        "src/crc32.c"
        "src/device_state.c"
        "src/fragment.c"
        "src/input_state.c"
        "src/message.c"
        "src/power_state.c"
    INCLUDE_DIRS "include"
)

target_compile_features(${COMPONENT_LIB} PUBLIC c_std_17)
