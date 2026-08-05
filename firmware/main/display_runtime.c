#include "display_runtime.h"

#include "esp_err.h"
#include "bsp/display.h"
#include "bsp/esp-bsp.h"
#include "bsp/touch.h"
#include "esp_check.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_touch.h"
#include "esp_log.h"
#include "esp_lv_adapter.h"
#include "esp_lv_adapter_display.h"
#include "esp_lv_adapter_input.h"

static const char *TAG = "display_runtime";

static bool result_ok(esp_err_t result, const char *message)
{
    if (result == ESP_OK) return true;
    ESP_LOGE(TAG, "%s: %s", message, esp_err_to_name(result));
    return false;
}

static void rounder_event_cb(lv_event_t *event)
{
    lv_area_t *area = lv_event_get_param(event);
    area->x1 = (area->x1 >> 1) << 1;
    area->y1 = (area->y1 >> 1) << 1;
    area->x2 = ((area->x2 >> 1) << 1) + 1;
    area->y2 = ((area->y2 >> 1) << 1) + 1;
}

lv_display_t *cr_display_start(void)
{
    const esp_lv_adapter_config_t adapter_config = ESP_LV_ADAPTER_DEFAULT_CONFIG();
    if (!result_ok(esp_lv_adapter_init(&adapter_config), "LVGL adapter init failed")) return NULL;

    esp_lcd_panel_handle_t panel = NULL;
    esp_lcd_panel_io_handle_t panel_io = NULL;
    const bsp_display_config_t panel_config = {
        .max_transfer_sz = CR_DISPLAY_BUFFER_BYTES,
    };
    if (!result_ok(bsp_display_new(&panel_config, &panel, &panel_io), "panel init failed")) {
        return NULL;
    }

    const esp_lv_adapter_display_config_t display_config = {
        .panel = panel,
        .panel_io = panel_io,
        .profile = {
            .interface = ESP_LV_ADAPTER_PANEL_IF_OTHER,
            .rotation = ESP_LV_ADAPTER_ROTATE_0,
            .hor_res = CR_DISPLAY_WIDTH,
            .ver_res = 480,
            .buffer_height = CR_DISPLAY_BUFFER_HEIGHT,
            .use_psram = CR_DISPLAY_BUFFER_IN_PSRAM,
            .enable_ppa_accel = false,
            .require_double_buffer = CR_DISPLAY_BUFFER_COUNT == 2,
        },
        .tear_avoid_mode = ESP_LV_ADAPTER_TEAR_AVOID_MODE_NONE,
    };
    lv_display_t *display = esp_lv_adapter_register_display(&display_config);
    ESP_RETURN_ON_FALSE(display != NULL, NULL, TAG, "display registration failed");
    lv_display_add_event_cb(display, rounder_event_cb, LV_EVENT_INVALIDATE_AREA, NULL);

    const bsp_display_cfg_t touch_config = {
        .lv_adapter_cfg = ESP_LV_ADAPTER_DEFAULT_CONFIG(),
        .rotation = ESP_LV_ADAPTER_ROTATE_0,
        .tear_avoid_mode = ESP_LV_ADAPTER_TEAR_AVOID_MODE_NONE,
        .touch_flags = {
            .swap_xy = 1,
            .mirror_x = 0,
            .mirror_y = 1,
        },
    };
    esp_lcd_touch_handle_t touch = NULL;
    if (!result_ok(bsp_touch_new(&touch_config, &touch), "touch init failed")) return NULL;
    const esp_lv_adapter_touch_config_t input_config =
        ESP_LV_ADAPTER_TOUCH_DEFAULT_CONFIG(display, touch);
    ESP_RETURN_ON_FALSE(
        esp_lv_adapter_register_touch(&input_config) != NULL, NULL, TAG, "touch registration failed");

    if (!result_ok(bsp_display_brightness_init(), "backlight init failed")) return NULL;
    if (!result_ok(esp_lv_adapter_start(), "LVGL adapter start failed")) return NULL;
    ESP_LOGI(TAG, "display buffers: %u x %u bytes, internal RAM",
             CR_DISPLAY_BUFFER_COUNT, CR_DISPLAY_BUFFER_BYTES);
    return display;
}
