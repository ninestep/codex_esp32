idf_component_register(
    SRCS "src/audio_capture.c"
    INCLUDE_DIRS "include"
    REQUIRES codex_remote_core codex_remote_ble waveshare__esp32_s3_touch_amoled_2_16 espressif__esp_codec_dev
)

target_compile_options(${COMPONENT_LIB} PRIVATE -Wframe-larger-than=1024)
