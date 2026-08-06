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

    char ui_source[16384];
    read_source("firmware/components/codex_remote_ui/src/ui.c", ui_source, sizeof(ui_source));
    assert(strstr(ui_source, "LV_EVENT_PRESSED") != NULL);
    assert(strstr(ui_source, "LV_EVENT_RELEASED") != NULL);
    assert(strstr(ui_source, "LV_EVENT_GESTURE") == NULL);
    return 0;
}
