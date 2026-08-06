idf_component_register(
    SRCS "src/advertising_layout.c" "src/ble_transport.c"
    INCLUDE_DIRS "include"
    REQUIRES codex_remote_core bt
)

if(NOT CONFIG_BT_NIMBLE_NVS_PERSIST)
    message(FATAL_ERROR "codex_remote_ble requires persistent NimBLE bonding keys")
endif()

target_compile_options(${COMPONENT_LIB} PRIVATE -Werror=stack-usage=2048)
