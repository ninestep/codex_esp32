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

static void read_prefix(const char *path, char *buffer, size_t capacity)
{
    FILE *file = fopen(path, "rb");
    assert(file != NULL);
    size_t length = fread(buffer, 1, capacity - 1, file);
    assert(!ferror(file));
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

    char app_source[32768];
    read_source("firmware/main/app_main.c", app_source, sizeof(app_source));
    assert(strstr(app_source, "bsp_display_backlight_on()") == NULL);
    assert(strstr(app_source, "xQueueOverwrite(ui_state_queue, state)") != NULL);
    assert(strstr(app_source, "xTaskCreate(ui_state_task, \"ui_state\"") != NULL);
    const char *display_start = strstr(app_source, "if (cr_display_start() == NULL)");
    const char *ui_update = strstr(app_source, "cr_ui_update(&device_state)");
    const char *mode_ui = ui_update == NULL ? NULL : strstr(ui_update, "refresh_connection_mode_ui()");
    const char *ble_start = strstr(app_source, "ESP_ERROR_CHECK(cr_ble_start(&device_state, &ble_config))");
    assert(display_start != NULL && mode_ui != NULL && ble_start != NULL);
    assert(display_start < mode_ui && mode_ui < ble_start);
    assert(strstr(app_source, "connection_mode_state.active == CR_CONNECTION_MODE_MAC_COMPANION") != NULL);
    assert(strstr(app_source, "waiting for first connection mode selection; BLE is disabled") != NULL);
    assert(strstr(app_source, "cr_codex_micro_hid_send_control_key") != NULL);
    assert(strstr(app_source, "cr_codex_micro_hid_send_keyboard_action") != NULL);
    assert(strstr(app_source, ".micro_control_key = ui_micro_control_key") != NULL);
    assert(strstr(app_source, ".micro_keyboard_action = ui_micro_keyboard_action") != NULL);
    assert(strstr(app_source, "cr_codex_micro_hid_send_encoder_press") != NULL);
    assert(strstr(app_source, "cr_codex_micro_hid_send_encoder") != NULL);
    assert(strstr(app_source, "cr_codex_micro_hid_send_direction") != NULL);
    assert(strstr(app_source, "ui_micro_keyboard_action(CR_MICRO_KEYBOARD_ENTER, NULL)") != NULL);
    assert(strstr(app_source, "ui_micro_keyboard_action(CR_MICRO_KEYBOARD_ESCAPE, NULL)") != NULL);
    assert(strstr(app_source, "send_micro_control_click") == NULL);
    assert(strstr(app_source, "cr_codex_micro_hid_send_control_key(CR_MICRO_CONTROL_PTT, true)") != NULL);
    assert(strstr(app_source, "cr_codex_micro_hid_send_control_key(CR_MICRO_CONTROL_PTT, false)") != NULL);
    assert(strstr(app_source, "input_context.detail_active = true") != NULL);
    assert(strstr(app_source, "input_context.session_selected = true") != NULL);
    assert(strstr(app_source, ".micro_encoder_press = ui_micro_encoder_press") != NULL);
    assert(strstr(app_source, ".micro_encoder_turn = ui_micro_encoder_turn") != NULL);
    assert(strstr(app_source, ".micro_direction = ui_micro_direction") != NULL);

    char hid_transport_source[65536];
    read_source(
        "firmware/components/codex_micro_hid/src/hid_transport.c",
        hid_transport_source,
        sizeof(hid_transport_source)
    );
    assert(strstr(hid_transport_source, "subscribed_report->id == CR_MICRO_REPORT_ID") != NULL);
    assert(strstr(hid_transport_source, "subscribed_report->type == BLE_SVC_HID_RPT_TYPE_INPUT") != NULL);

    char ui_source[65536];
    read_source("firmware/components/codex_remote_ui/src/ui.c", ui_source, sizeof(ui_source));
    assert(strstr(ui_source, "LV_EVENT_PRESSED") != NULL);
    assert(strstr(ui_source, "LV_EVENT_RELEASED") != NULL);
    assert(strstr(ui_source, "LV_EVENT_GESTURE") == NULL);
    assert(strstr(ui_source, "codex_remote_font_16") != NULL);
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
    assert(strstr(ui_source, "删除") != NULL);
    assert(strstr(ui_source, "LV_EVENT_SHORT_CLICKED") != NULL);
    assert(strstr(ui_source, "LV_EVENT_LONG_PRESSED") != NULL);
    assert(strstr(ui_source, "CR_TERMINAL_KEY_BACKSPACE") != NULL);
    assert(strstr(ui_source, "CR_TERMINAL_KEY_CLEAR_LINE") != NULL);
    assert(strstr(ui_source, "CONNECTION MODE") != NULL);
    assert(strstr(ui_source, "CODEX MICRO") != NULL);
    assert(strstr(ui_source, "micro_light_state") != NULL);
    assert(strstr(ui_source, "micro_action_page") != NULL);
    assert(strstr(ui_source, "micro_control_key") != NULL);
    assert(strstr(ui_source, "pressed_micro_control") != NULL);
    assert(strstr(ui_source, "批准") != NULL);
    assert(strstr(ui_source, "拒绝") != NULL);
    assert(strstr(ui_source, "继续") != NULL);
    assert(strstr(ui_source, "make_micro_action_button(\"快速\"") == NULL);
    assert(strstr(ui_source, "make_micro_action_button(\"按住说话\"") == NULL);
    assert(strstr(ui_source, "make_micro_action_button(\"发送\"") == NULL);
    assert(strstr(ui_source, "CR_MICRO_KEYBOARD_DELETE") != NULL);
    assert(strstr(ui_source, "CR_MICRO_KEYBOARD_CLEAR") != NULL);
    assert(strstr(ui_source, "micro_keyboard_action") != NULL);
    assert(strstr(ui_source, "旋钮") != NULL);
    assert(strstr(ui_source, "摇杆") != NULL);
    assert(strstr(ui_source, "micro_encoder_panel") != NULL);
    assert(strstr(ui_source, "micro_joystick_panel") != NULL);
    assert(strstr(ui_source, "micro_encoder_press") != NULL);
    assert(strstr(ui_source, "micro_encoder_turn") != NULL);
    assert(strstr(ui_source, "micro_direction") != NULL);
    assert(strstr(ui_source, "micro_encoder_ring") != NULL);
    assert(strstr(ui_source, "LV_RADIUS_CIRCLE") != NULL);
    assert(strstr(ui_source, "LV_EVENT_SHORT_CLICKED") != NULL);
    assert(strstr(ui_source, "LV_EVENT_LONG_PRESSED_REPEAT") != NULL);
    assert(strstr(ui_source, "点击 / 长按") != NULL);
    assert(strstr(ui_source, "lv_obj_set_size(card->card, 214, 116)") != NULL);
    assert(strstr(ui_source, "lv_obj_add_flag(card->directory, LV_OBJ_FLAG_HIDDEN)") != NULL);
    assert(strstr(ui_source, "#%06lX") == NULL);
    assert(strstr(ui_source, "lv_label_set_text(card->status, \"就绪\")") == NULL);
    assert(strstr(ui_source, "MAC APP") != NULL);
    assert(strstr(ui_source, "DEVICE WILL RESTART") != NULL);

    char font_source[32768];
    read_prefix(
        "firmware/components/codex_remote_ui/src/codex_remote_font_16.c",
        font_source,
        sizeof(font_source)
    );
    const char *required_glyphs[] = {
        "处", "态", "捷", "确", "离", "线", "认",
        "误", "输", "连", "错", "键", "闲", "快",
        "速", "批", "准", "拒", "绝", "继", "续",
        "按", "住", "说", "话", "发", "送", "返", "回",
        "旋", "钮", "摇", "杆", "向", "左", "右", "转", "长", "点", "清", "除",
    };
    for (size_t index = 0; index < sizeof(required_glyphs) / sizeof(required_glyphs[0]); index++) {
        assert(strstr(font_source, required_glyphs[index]) != NULL);
    }
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
    assert(strstr(sdkconfig_defaults, "CONFIG_LV_FONT_SOURCE_HAN_SANS_SC_16_CJK=y") == NULL);
    assert(strstr(sdkconfig_defaults, "CONFIG_BT_NIMBLE_SVC_HID_MAX_RPTS=3") != NULL);

    char hid_source[32768];
    read_source(
        "firmware/components/codex_micro_hid/src/hid_transport.c",
        hid_source,
        sizeof(hid_source)
    );
    assert(strstr(hid_source, "CR_MICRO_RELEASE UINT16_C(0x0102)") != NULL);
    assert(strstr(hid_source, "ble_svc_gatt_changed(UINT16_C(0x0001), UINT16_C(0xffff))") != NULL);
    return 0;
}
