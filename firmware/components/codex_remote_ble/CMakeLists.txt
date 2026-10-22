idf_component_register(
    SRCS "src/advertising_layout.c" "src/ble_transport.c"
    INCLUDE_DIRS "include"
    REQUIRES codex_remote_core bt
)

if(NOT CONFIG_BT_NIMBLE_NVS_PERSIST)
    message(FATAL_ERROR "codex_remote_ble requires persistent NimBLE bonding keys")
endif()

math(EXPR required_cccds "${CONFIG_BT_NIMBLE_MAX_BONDS} * 8")
if(CONFIG_BT_NIMBLE_MAX_CCCDS LESS required_cccds)
    message(FATAL_ERROR "NimBLE needs at least ${required_cccds} persistent CCCDs for HID and companion bonds")
endif()

target_compile_options(${COMPONENT_LIB} PRIVATE -Werror=stack-usage=2048)
