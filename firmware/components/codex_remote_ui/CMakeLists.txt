idf_component_register(
    SRCS "src/ui.c" "src/codex_remote_font_16.c"
    INCLUDE_DIRS "include"
    REQUIRES codex_remote_core codex_micro_hid lvgl__lvgl
)
