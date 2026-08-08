idf_component_register(
    SRCS "src/hid_transport.c" "src/vendor_frame.c" "src/rpc_codec.c" "src/micro_state.c"
    INCLUDE_DIRS "include"
    REQUIRES bt esp_event esp_hid json nvs_flash
)

target_compile_features(${COMPONENT_LIB} PUBLIC c_std_17)
target_compile_options(${COMPONENT_LIB} PRIVATE -Werror=stack-usage=2048)
