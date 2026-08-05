idf_component_register(
    SRCS "app_main.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES nvs_flash codex_remote_core codex_remote_ble codex_remote_ui codex_remote_audio esp_driver_gpio
)
