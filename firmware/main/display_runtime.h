#pragma once

#include <stdbool.h>

#define CR_DISPLAY_WIDTH 480
#define CR_DISPLAY_BUFFER_HEIGHT 10
#define CR_DISPLAY_BUFFER_COUNT 1
#define CR_DISPLAY_BYTES_PER_PIXEL 2
#define CR_DISPLAY_BUFFER_BYTES \
    (CR_DISPLAY_WIDTH * CR_DISPLAY_BUFFER_HEIGHT * CR_DISPLAY_BYTES_PER_PIXEL)
#define CR_DISPLAY_TOTAL_BUFFER_BYTES \
    (CR_DISPLAY_BUFFER_BYTES * CR_DISPLAY_BUFFER_COUNT)
#define CR_DISPLAY_BUFFER_IN_PSRAM 0

#ifdef ESP_PLATFORM
#include "esp_err.h"
#include "lvgl.h"

lv_display_t *cr_display_start(void);
esp_err_t cr_display_set_output_enabled(bool enabled);
#endif
