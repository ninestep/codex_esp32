#include "codex_remote/ble_transport.h"
#include "codex_remote/audio_capture.h"
#include "codex_remote/device_state.h"
#include "codex_remote/input_state.h"
#include "codex_remote/power_state.h"
#include "codex_remote/ui.h"
#include "display_runtime.h"

#include "bsp/display.h"
#include "bsp/esp-bsp.h"
#include "driver/gpio.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_lv_adapter.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#define USER_BUTTON_GPIO GPIO_NUM_18

static const char *TAG = "codex_remote";
static cr_device_state_t device_state;
static cr_input_state_t input_state;
static cr_power_state_t power_state;
static cr_power_mode_t current_power_mode;
static portMUX_TYPE power_lock = portMUX_INITIALIZER_UNLOCKED;
static uint32_t pending_first_audio_sequence;
static QueueHandle_t ui_state_queue;
static StaticQueue_t ui_state_queue_storage;
static uint8_t ui_state_queue_buffer[sizeof(cr_device_state_t)];
static cr_device_state_t ui_state_snapshot;

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

static void execute_input_action(cr_input_action_t action)
{
    if (action == CR_INPUT_WAKE) {
        note_interaction(NULL);
        return;
    }
    if (!device_state.has_selection) return;
    switch (action) {
    case CR_INPUT_PRE_ROLL_BEGIN:
        (void)cr_audio_capture_prepare(&pending_first_audio_sequence);
        break;
    case CR_INPUT_PRE_ROLL_DISCARD:
        cr_audio_capture_discard();
        break;
    case CR_INPUT_ENTER:
        note_interaction(NULL);
        (void)cr_ble_send_terminal_key(device_state.selected_session_key, 1);
        break;
    case CR_INPUT_ESCAPE:
        note_interaction(NULL);
        (void)cr_ble_send_terminal_key(device_state.selected_session_key, 2);
        break;
    case CR_INPUT_PTT_BEGIN:
        note_interaction(NULL);
        if (cr_ble_send_ptt_begin(device_state.selected_session_key, pending_first_audio_sequence) == ESP_OK) {
            portENTER_CRITICAL(&power_lock);
            device_state.ptt_active = true;
            portEXIT_CRITICAL(&power_lock);
            (void)cr_audio_capture_commit();
            ble_state_changed(&device_state, NULL);
        } else {
            cr_audio_capture_discard();
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
            .interaction_locked = device_state.ptt_active,
        };
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
    cr_device_state_init(&device_state);
    cr_input_state_init(&input_state);
    cr_power_init(&power_state, now_ms());

    if (cr_display_start() == NULL) {
        ESP_LOGE(TAG, "failed to initialize Waveshare display");
        return;
    }
    ESP_ERROR_CHECK(esp_lv_adapter_lock(200));
    cr_ui_callbacks_t ui_callbacks = {
        .select_session = ui_select,
        .scroll = ui_scroll,
        .terminal_key = ui_key,
        .interaction = note_interaction,
    };
    cr_ui_init(&ui_callbacks);
    cr_ui_update(&device_state);
    esp_lv_adapter_unlock();

    ui_state_queue = xQueueCreateStatic(
        1,
        sizeof(cr_device_state_t),
        ui_state_queue_buffer,
        &ui_state_queue_storage
    );
    configASSERT(ui_state_queue != NULL);
    ESP_ERROR_CHECK(
        xTaskCreate(ui_state_task, "ui_state", 4096, NULL, 5, NULL) == pdPASS
            ? ESP_OK : ESP_ERR_NO_MEM
    );

    gpio_config_t button_config = {
        .pin_bit_mask = UINT64_C(1) << USER_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&button_config));

    cr_ble_config_t ble_config = {
        .on_state_changed = ble_state_changed,
    };
    ESP_ERROR_CHECK(cr_ble_start(&device_state, &ble_config));
    esp_err_t audio_result = cr_audio_capture_init();
    if (audio_result != ESP_OK) {
        ESP_LOGW(TAG, "microphone unavailable: %s", esp_err_to_name(audio_result));
    }
    xTaskCreate(button_task, "user_button", 4096, NULL, 5, NULL);
    xTaskCreate(power_task, "display_power", 3072, NULL, 4, NULL);

    ESP_LOGI(TAG, "Codex Remote ready: %dx%d, GPIO18 enabled", BSP_LCD_H_RES, BSP_LCD_V_RES);
}
