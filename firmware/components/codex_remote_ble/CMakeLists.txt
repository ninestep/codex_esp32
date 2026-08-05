idf_component_register(
    SRCS "src/advertising_layout.c" "src/ble_transport.c"
    INCLUDE_DIRS "include"
    REQUIRES codex_remote_core bt
)
