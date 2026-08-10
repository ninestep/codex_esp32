idf_component_register(
    SRCS "app_main.c" "display_runtime.c" "power_telemetry.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES nvs_flash codex_remote_core codex_remote_platform codex_remote_ble codex_remote_ui codex_remote_audio codex_micro_hid esp_driver_gpio esp_driver_i2c waveshare__esp32_s3_touch_amoled_2_16
)
