#include "codex_remote/ble_transport.h"
#include "codex_remote/audio_capture.h"
#include "codex_remote/connection_mode.h"
#include "codex_remote/connection_mode_store.h"
#include "codex_remote/device_state.h"
#include "codex_remote/input_state.h"
#include "codex_remote/power_state.h"
#include "codex_remote/ui.h"
#include "codex_micro/hid_transport.h"
#include "display_runtime.h"

#include "bsp/display.h"
#include "bsp/esp-bsp.h"
#include "driver/gpio.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_lv_adapter.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#define USER_BUTTON_GPIO GPIO_NUM_18

static const char *TAG = "codex_remote";
static cr_device_state_t device_state;
static cr_connection_mode_state_t connection_mode_state;
static cr_input_state_t input_state;
static cr_power_state_t power_state;
static cr_power_mode_t current_power_mode;
static portMUX_TYPE power_lock = portMUX_INITIALIZER_UNLOCKED;
static uint32_t pending_first_audio_sequence;
static bool audio_available;
static bool audio_prepared;
static bool companion_transport_started;
static bool micro_button_ptt_active;
static QueueHandle_t ui_state_queue;
static StaticQueue_t ui_state_queue_storage;
static uint8_t ui_state_queue_buffer[sizeof(cr_device_state_t)];
static cr_device_state_t ui_state_snapshot;
static QueueHandle_t micro_state_queue;
static StaticQueue_t micro_state_queue_storage;
static uint8_t micro_state_queue_buffer[sizeof(cr_micro_state_t)];
static cr_micro_state_t micro_state_snapshot;

static uint64_t now_ms(void)
{
    return (uint64_t)(esp_timer_get_time() / 1000);
}

static void note_interaction(void *context)
{
    (void)context;
    portENTER_CRITICAL(&power_lock);
    cr_power_note_interaction(&power_state, now_ms());
    portEXIT_CRITICAL(&power_lock);
}

static esp_err_t initialize_nvs(void)
{
    esp_err_t result = nvs_flash_init();
    if (result == ESP_ERR_NVS_NO_FREE_PAGES || result == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_RETURN_ON_ERROR(nvs_flash_erase(), TAG, "failed to erase NVS");
        result = nvs_flash_init();
    }
    return result;
}

static void ui_select(uint16_t session_key, void *context)
{
    (void)context;
    if (cr_ble_send_select(session_key) != ESP_OK) {
        ESP_LOGW(TAG, "session selection unavailable");
    }
}

static void ui_scroll(uint16_t session_key, int16_t delta, void *context)
{
    (void)context;
    if (cr_ble_send_scroll(session_key, delta) != ESP_OK) {
        ESP_LOGW(TAG, "scroll unavailable");
    }
}

static void ui_key(uint16_t session_key, uint8_t key, void *context)
{
    (void)context;
    if (cr_ble_send_terminal_key(session_key, key) != ESP_OK) {
        ESP_LOGW(TAG, "terminal key unavailable");
    }
}

static void ui_shortcut(uint16_t session_key, uint8_t shortcut, void *context)
{
    (void)context;
    if (cr_ble_send_terminal_shortcut(session_key, shortcut) != ESP_OK) {
        ESP_LOGW(TAG, "terminal shortcut unavailable");
    }
}

static void ui_micro_agent_key(uint8_t agent_index, bool pressed, void *context)
{
    (void)context;
    esp_err_t result = cr_codex_micro_hid_send_agent_key(agent_index, pressed);
    if (result != ESP_OK) {
        ESP_LOGW(TAG, "Codex Micro agent key unavailable: %s", esp_err_to_name(result));
    }
}

static void ui_micro_control_key(cr_micro_control_t control, bool pressed, void *context)
{
    (void)context;
    esp_err_t result = cr_codex_micro_hid_send_control_key(control, pressed);
    if (result != ESP_OK) {
        ESP_LOGW(TAG, "Codex Micro control key unavailable: %s", esp_err_to_name(result));
    }
}

static void ui_micro_keyboard_action(cr_micro_keyboard_action_t action, void *context)
{
    (void)context;
    esp_err_t result = cr_codex_micro_hid_send_keyboard_action(action);
    if (result != ESP_OK) {
        ESP_LOGW(TAG, "Codex Micro keyboard action unavailable: %s", esp_err_to_name(result));
    }
}

static void ui_micro_encoder_press(bool pressed, void *context)
{
    (void)context;
    esp_err_t result = cr_codex_micro_hid_send_encoder_press(pressed);
    if (result != ESP_OK) {
        ESP_LOGW(TAG, "Codex Micro encoder press unavailable: %s", esp_err_to_name(result));
    }
}

static void ui_micro_encoder_turn(cr_micro_encoder_action_t action, void *context)
{
    (void)context;
    esp_err_t result = cr_codex_micro_hid_send_encoder(action);
    if (result != ESP_OK) {
        ESP_LOGW(TAG, "Codex Micro encoder turn unavailable: %s", esp_err_to_name(result));
    }
}

static void ui_micro_direction(cr_micro_direction_t direction, bool pressed, void *context)
{
    (void)context;
    esp_err_t result = cr_codex_micro_hid_send_direction(direction, pressed);
    if (result != ESP_OK) {
        ESP_LOGW(TAG, "Codex Micro direction unavailable: %s", esp_err_to_name(result));
    }
}

static void send_micro_control_click(cr_micro_control_t control)
{
    esp_err_t result = cr_codex_micro_hid_send_control_key(control, true);
    if (result == ESP_OK) {
        result = cr_codex_micro_hid_send_control_key(control, false);
    }
    if (result != ESP_OK) {
        ESP_LOGW(TAG, "Codex Micro physical button unavailable: %s", esp_err_to_name(result));
    }
}

static void refresh_connection_mode_ui(void)
{
    cr_ui_set_connection_mode(&connection_mode_state);
}

static void ui_request_connection_mode(cr_connection_mode_t mode, void *context)
{
    (void)context;
    if (cr_connection_mode_request(&connection_mode_state, (uint8_t)mode)) {
        refresh_connection_mode_ui();
    }
}

static void ui_cancel_connection_mode(void *context)
{
    (void)context;
    cr_connection_mode_cancel(&connection_mode_state);
    refresh_connection_mode_ui();
}

static void stop_active_ptt_for_mode_change(void)
{
    if (micro_button_ptt_active) {
        (void)cr_codex_micro_hid_send_control_key(CR_MICRO_CONTROL_PTT, false);
        micro_button_ptt_active = false;
    }
    if (audio_prepared) {
        cr_audio_capture_discard();
        audio_prepared = false;
    }
    if (!device_state.ptt_active) return;

    uint32_t last_sequence = 0;
    cr_audio_capture_stop(&last_sequence);
    if (companion_transport_started) {
        (void)cr_ble_send_ptt_end(device_state.selected_session_key, last_sequence);
    }
    device_state.ptt_active = false;
}

static void ui_confirm_connection_mode(void *context)
{
    (void)context;
    cr_connection_mode_state_t previous = connection_mode_state;
    stop_active_ptt_for_mode_change();
    if (!cr_connection_mode_confirm(&connection_mode_state)) return;

    esp_err_t result = cr_connection_mode_store_save(connection_mode_state.active);
    if (result != ESP_OK) {
        ESP_LOGE(TAG, "failed to save connection mode: %s", esp_err_to_name(result));
        connection_mode_state = previous;
        refresh_connection_mode_ui();
        return;
    }

    ESP_LOGI(TAG, "connection mode saved; restarting");
    esp_restart();
}

static void ble_state_changed(const cr_device_state_t *state, void *context)
{
    (void)context;
    xQueueOverwrite(ui_state_queue, state);
}

static void ui_state_task(void *context)
{
    (void)context;
    while (true) {
        if (xQueueReceive(ui_state_queue, &ui_state_snapshot, portMAX_DELAY) != pdTRUE) continue;
        for (size_t index = 0; index < ui_state_snapshot.session_count; index++) {
            if (ui_state_snapshot.sessions[index].state != 3
                && ui_state_snapshot.sessions[index].state != 4) continue;
            portENTER_CRITICAL(&power_lock);
            cr_power_note_urgent(&power_state, now_ms());
            portEXIT_CRITICAL(&power_lock);
            break;
        }
        if (esp_lv_adapter_lock(200) != ESP_OK) {
            ESP_LOGW(TAG, "display busy while applying BLE state");
            continue;
        }
        cr_ui_update(&ui_state_snapshot);
        esp_lv_adapter_unlock();
    }
}

static void micro_state_changed(const cr_micro_state_t *state, void *context)
{
    (void)context;
    xQueueOverwrite(micro_state_queue, state);
}

static void micro_state_task(void *context)
{
    (void)context;
    while (true) {
        if (xQueueReceive(
                micro_state_queue, &micro_state_snapshot, portMAX_DELAY
            ) != pdTRUE) continue;
        if (esp_lv_adapter_lock(200) != ESP_OK) {
            ESP_LOGW(TAG, "display busy while applying Codex Micro state");
            continue;
        }
        cr_ui_update_micro(&micro_state_snapshot);
        esp_lv_adapter_unlock();
    }
}

static void execute_input_action(cr_input_action_t action)
{
    if (action == CR_INPUT_WAKE) {
        note_interaction(NULL);
        return;
    }
    if (!cr_connection_mode_can_accept_input(&connection_mode_state)) return;
    if (connection_mode_state.active == CR_CONNECTION_MODE_NATIVE_MICRO) {
        switch (action) {
        case CR_INPUT_ENTER:
            note_interaction(NULL);
            send_micro_control_click(CR_MICRO_CONTROL_SEND);
            break;
        case CR_INPUT_ESCAPE:
            note_interaction(NULL);
            send_micro_control_click(CR_MICRO_CONTROL_DECLINE);
            break;
        case CR_INPUT_PTT_BEGIN: {
            note_interaction(NULL);
            esp_err_t result = cr_codex_micro_hid_send_control_key(CR_MICRO_CONTROL_PTT, true);
            if (result == ESP_OK) {
                micro_button_ptt_active = true;
            } else {
                ESP_LOGW(TAG, "Codex Micro PTT unavailable: %s", esp_err_to_name(result));
            }
            break;
        }
        case CR_INPUT_PTT_END:
            if (micro_button_ptt_active) {
                esp_err_t result = cr_codex_micro_hid_send_control_key(CR_MICRO_CONTROL_PTT, false);
                if (result != ESP_OK) {
                    ESP_LOGW(TAG, "Codex Micro PTT release unavailable: %s", esp_err_to_name(result));
                }
                micro_button_ptt_active = false;
            }
            note_interaction(NULL);
            break;
        default:
            break;
        }
        return;
    }
    if (!device_state.has_selection) return;
    switch (action) {
    case CR_INPUT_PRE_ROLL_BEGIN:
        audio_prepared = false;
        if (!audio_available) {
            ESP_LOGW(TAG, "PTT unavailable: microphone not initialized");
            break;
        }
        if (cr_audio_capture_prepare(&pending_first_audio_sequence) != ESP_OK) {
            ESP_LOGW(TAG, "PTT unavailable: audio pre-roll failed");
            break;
        }
        audio_prepared = true;
        break;
    case CR_INPUT_PRE_ROLL_DISCARD:
        cr_audio_capture_discard();
        audio_prepared = false;
        break;
    case CR_INPUT_ENTER:
        note_interaction(NULL);
        (void)cr_ble_send_terminal_key(device_state.selected_session_key, CR_TERMINAL_KEY_ENTER);
        break;
    case CR_INPUT_ESCAPE:
        note_interaction(NULL);
        (void)cr_ble_send_terminal_key(device_state.selected_session_key, CR_TERMINAL_KEY_ESCAPE);
        break;
    case CR_INPUT_PTT_BEGIN:
        note_interaction(NULL);
        if (!audio_prepared) {
            ESP_LOGW(TAG, "PTT begin ignored: audio pre-roll is not ready");
            break;
        }
        if (cr_ble_send_ptt_begin(device_state.selected_session_key, pending_first_audio_sequence) == ESP_OK) {
            if (cr_audio_capture_commit() != ESP_OK) {
                ESP_LOGW(TAG, "PTT aborted: audio commit failed");
                (void)cr_ble_send_ptt_end(device_state.selected_session_key, 0);
                cr_audio_capture_discard();
                audio_prepared = false;
                break;
            }
            portENTER_CRITICAL(&power_lock);
            device_state.ptt_active = true;
            portEXIT_CRITICAL(&power_lock);
            audio_prepared = false;
            ble_state_changed(&device_state, NULL);
        } else {
            cr_audio_capture_discard();
            audio_prepared = false;
        }
        break;
    case CR_INPUT_PTT_END: {
        uint32_t last_sequence = 0;
        cr_audio_capture_stop(&last_sequence);
        (void)cr_ble_send_ptt_end(device_state.selected_session_key, last_sequence);
        portENTER_CRITICAL(&power_lock);
        device_state.ptt_active = false;
        portEXIT_CRITICAL(&power_lock);
        note_interaction(NULL);
        ble_state_changed(&device_state, NULL);
        break;
    }
    default:
        break;
    }
}

static void button_task(void *context)
{
    (void)context;
    int previous_level = gpio_get_level(USER_BUTTON_GPIO);
    while (true) {
        int level = gpio_get_level(USER_BUTTON_GPIO);
        uint64_t event_ms = now_ms();
        cr_input_context_t input_context = {
            .detail_active = device_state.has_selection,
            .session_selected = device_state.has_selection,
            .screen_on = true,
            .interaction_locked = device_state.ptt_active || micro_button_ptt_active,
        };
        if (connection_mode_state.active == CR_CONNECTION_MODE_NATIVE_MICRO) {
            input_context.detail_active = true;
            input_context.session_selected = true;
        }
        if (!cr_connection_mode_can_accept_input(&connection_mode_state)) {
            input_context.interaction_locked = true;
        }
        portENTER_CRITICAL(&power_lock);
        input_context.screen_on = current_power_mode != CR_POWER_OFF;
        portEXIT_CRITICAL(&power_lock);
        if (level != previous_level) {
            cr_input_event_t edge = level == 0 ? CR_INPUT_BUTTON_DOWN : CR_INPUT_BUTTON_UP;
            execute_input_action(cr_input_reduce(&input_state, input_context, edge, event_ms));
            previous_level = level;
        }
        execute_input_action(cr_input_reduce(&input_state, input_context, CR_INPUT_TICK, event_ms));
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

static void power_task(void *context)
{
    (void)context;
    while (true) {
        cr_power_output_t output;
        bool mode_changed;
        portENTER_CRITICAL(&power_lock);
        output = cr_power_update(&power_state, now_ms(), device_state.ptt_active, 0);
        mode_changed = output.mode != current_power_mode;
        current_power_mode = output.mode;
        portEXIT_CRITICAL(&power_lock);
        if (mode_changed) {
            int brightness = output.mode == CR_POWER_NORMAL ? 100
                : output.mode == CR_POWER_DIM ? 25
                : output.mode == CR_POWER_SCREENSAVER ? 40 : 0;
            if (esp_lv_adapter_lock(200) == ESP_OK) {
                cr_ui_set_power(output.mode, output.asset_index);
                (void)bsp_display_brightness_set(brightness);
                esp_lv_adapter_unlock();
            }
        }
        vTaskDelay(pdMS_TO_TICKS(250));
    }
}

void app_main(void)
{
    ESP_ERROR_CHECK(initialize_nvs());
    cr_connection_mode_t stored_mode = CR_CONNECTION_MODE_UNCONFIGURED;
    esp_err_t mode_result = cr_connection_mode_store_load(&stored_mode);
    if (mode_result != ESP_OK) {
        ESP_LOGE(TAG, "invalid connection mode configuration: %s", esp_err_to_name(mode_result));
        stored_mode = CR_CONNECTION_MODE_UNCONFIGURED;
    }
    cr_connection_mode_init(&connection_mode_state, (uint8_t)stored_mode);
    cr_device_state_init(&device_state);
    cr_input_state_init(&input_state);
    cr_power_init(&power_state, now_ms());

    ui_state_queue = xQueueCreateStatic(
        1,
        sizeof(cr_device_state_t),
        ui_state_queue_buffer,
        &ui_state_queue_storage
    );
    configASSERT(ui_state_queue != NULL);
    micro_state_queue = xQueueCreateStatic(
        1,
        sizeof(cr_micro_state_t),
        micro_state_queue_buffer,
        &micro_state_queue_storage
    );
    configASSERT(micro_state_queue != NULL);
    if (cr_display_start() == NULL) {
        ESP_LOGE(TAG, "failed to initialize Waveshare display");
        return;
    }
    ESP_ERROR_CHECK(esp_lv_adapter_lock(200));
    cr_ui_callbacks_t ui_callbacks = {
        .select_session = ui_select,
        .scroll = ui_scroll,
        .terminal_key = ui_key,
        .terminal_shortcut = ui_shortcut,
        .micro_agent_key = ui_micro_agent_key,
        .micro_control_key = ui_micro_control_key,
        .micro_keyboard_action = ui_micro_keyboard_action,
        .micro_encoder_press = ui_micro_encoder_press,
        .micro_encoder_turn = ui_micro_encoder_turn,
        .micro_direction = ui_micro_direction,
        .request_connection_mode = ui_request_connection_mode,
        .confirm_connection_mode = ui_confirm_connection_mode,
        .cancel_connection_mode = ui_cancel_connection_mode,
        .interaction = note_interaction,
    };
    cr_ui_init(&ui_callbacks);
    if (connection_mode_state.active == CR_CONNECTION_MODE_NATIVE_MICRO) {
        cr_micro_state_init(&micro_state_snapshot);
        cr_ui_update_micro(&micro_state_snapshot);
    } else {
        cr_ui_update(&device_state);
    }
    refresh_connection_mode_ui();
    esp_lv_adapter_unlock();

    if (connection_mode_state.active == CR_CONNECTION_MODE_MAC_COMPANION) {
        cr_ble_config_t ble_config = {
            .on_state_changed = ble_state_changed,
        };
        ESP_ERROR_CHECK(cr_ble_start(&device_state, &ble_config));
        companion_transport_started = true;

        esp_err_t audio_result = cr_audio_capture_init();
        audio_available = audio_result == ESP_OK;
        if (!audio_available) {
            ESP_LOGW(TAG, "microphone unavailable: %s", esp_err_to_name(audio_result));
        }

        ESP_ERROR_CHECK(
            xTaskCreate(ui_state_task, "ui_state", 4096, NULL, 5, NULL) == pdPASS
                ? ESP_OK : ESP_ERR_NO_MEM
        );
    } else if (connection_mode_state.active == CR_CONNECTION_MODE_NATIVE_MICRO) {
        ESP_ERROR_CHECK(
            xTaskCreate(micro_state_task, "micro_ui", 4096, NULL, 5, NULL) == pdPASS
                ? ESP_OK : ESP_ERR_NO_MEM
        );
        cr_codex_micro_hid_config_t hid_config = {
            .on_state_changed = micro_state_changed,
        };
        ESP_ERROR_CHECK(cr_codex_micro_hid_start(&hid_config));
    } else {
        ESP_LOGI(TAG, "waiting for first connection mode selection; BLE is disabled");
    }

    gpio_config_t button_config = {
        .pin_bit_mask = UINT64_C(1) << USER_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&button_config));

    ESP_ERROR_CHECK(
        xTaskCreate(button_task, "user_button", 4096, NULL, 5, NULL) == pdPASS
            ? ESP_OK : ESP_ERR_NO_MEM
    );
    ESP_ERROR_CHECK(
        xTaskCreate(power_task, "display_power", 3072, NULL, 4, NULL) == pdPASS
            ? ESP_OK : ESP_ERR_NO_MEM
    );

    ESP_LOGI(TAG, "Codex Remote ready: %dx%d, GPIO18 enabled", BSP_LCD_H_RES, BSP_LCD_V_RES);
}
