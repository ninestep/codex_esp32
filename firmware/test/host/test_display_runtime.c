#include "display_runtime.h"

#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static void read_source(const char *path, char *buffer, size_t capacity)
{
    FILE *file = fopen(path, "rb");
    assert(file != NULL);
    size_t length = fread(buffer, 1, capacity - 1, file);
    assert(!ferror(file));
    assert(feof(file));
    buffer[length] = '\0';
    fclose(file);
}

int main(void)
{
    assert(CR_DISPLAY_WIDTH == 480);
    assert(CR_DISPLAY_BUFFER_HEIGHT == 10);
    assert(CR_DISPLAY_BUFFER_COUNT == 1);
    assert(CR_DISPLAY_BUFFER_BYTES == 9600);
    assert(CR_DISPLAY_TOTAL_BUFFER_BYTES == 9600);
    assert(CR_DISPLAY_BUFFER_IN_PSRAM == 0);

    char display_source[8192];
    read_source("firmware/main/display_runtime.c", display_source, sizeof(display_source));
    const char *brightness_init = strstr(display_source, "bsp_display_brightness_init()");
    const char *adapter_start = strstr(display_source, "esp_lv_adapter_start()");
    assert(brightness_init != NULL && adapter_start != NULL && brightness_init < adapter_start);

    char app_source[16384];
    read_source("firmware/main/app_main.c", app_source, sizeof(app_source));
    assert(strstr(app_source, "bsp_display_backlight_on()") == NULL);
    assert(strstr(app_source, "xQueueOverwrite(ui_state_queue, state)") != NULL);
    assert(strstr(app_source, "xTaskCreate(ui_state_task, \"ui_state\"") != NULL);
    const char *ble_start = strstr(app_source, "ESP_ERROR_CHECK(cr_ble_start(&device_state, &ble_config))");
    const char *display_start = strstr(app_source, "if (cr_display_start() == NULL)");
    assert(ble_start != NULL && display_start != NULL && ble_start < display_start);

    char ui_source[32768];
    read_source("firmware/components/codex_remote_ui/src/ui.c", ui_source, sizeof(ui_source));
    assert(strstr(ui_source, "LV_EVENT_PRESSED") != NULL);
    assert(strstr(ui_source, "LV_EVENT_RELEASED") != NULL);
    assert(strstr(ui_source, "LV_EVENT_GESTURE") == NULL);
    assert(strstr(ui_source, "lv_font_source_han_sans_sc_16_cjk") != NULL);
    assert(strstr(ui_source, "card->dot") == NULL);
    assert(strstr(ui_source, "state_background_color") != NULL);
    assert(strstr(ui_source, "state_border_color") != NULL);
    assert(strstr(ui_source, "空闲") != NULL);
    assert(strstr(ui_source, "正在处理") != NULL);
    assert(strstr(ui_source, "已完成") != NULL);
    assert(strstr(ui_source, "需要输入") != NULL);
    assert(strstr(ui_source, "错误") != NULL);
    assert(strstr(ui_source, "离线") != NULL);
    assert(strstr(ui_source, "Mac 已连接") != NULL);
    assert(strstr(ui_source, "快捷键 >") != NULL);
    assert(strstr(ui_source, "< 状态") != NULL);
    assert(strstr(ui_source, "确认  ENTER") != NULL);
    assert(strstr(ui_source, "LV_SYMBOL_UP") != NULL);
    assert(strstr(ui_source, "LV_SYMBOL_DOWN") != NULL);
    assert(strstr(ui_source, "LV_SYMBOL_LEFT") != NULL);
    assert(strstr(ui_source, "LV_SYMBOL_RIGHT") != NULL);
    assert(strstr(ui_source, "LV_FONT_DEFAULT") != NULL);
    assert(strstr(ui_source, "Mac 已接") == NULL);
    assert(strstr(ui_source, "同意  ENTER") == NULL);
    assert(strstr(ui_source, "terminal_shortcut") != NULL);
    assert(strstr(ui_source, "detail_content_page") != NULL);
    assert(strstr(ui_source, "shortcut_page") != NULL);
    assert(strstr(ui_source, "CR_TERMINAL_KEY_RIGHT") != NULL);

    char sdkconfig_defaults[8192];
    read_source("firmware/sdkconfig.defaults", sdkconfig_defaults, sizeof(sdkconfig_defaults));
    assert(strstr(sdkconfig_defaults, "CONFIG_LV_FONT_SOURCE_HAN_SANS_SC_16_CJK=y") != NULL);
    return 0;
}
