#include "codex_micro/hid_transport.h"

#include "codex_micro/rpc_codec.h"
#include "codex_micro/vendor_frame.h"
#include "codex_remote/ble_transport.h"

#include "esp_check.h"
#include "esp_hidd.h"
#include "esp_hid_common.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "host/ble_hs_adv.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "services/hid/ble_svc_hid.h"

#include <string.h>

#define CR_MICRO_VENDOR_ID UINT16_C(0x303a)
#define CR_MICRO_PRODUCT_ID UINT16_C(0x8360)
#define CR_MICRO_RELEASE UINT16_C(0x0102)
#define CR_MICRO_RPC_RESPONSE_BYTES 512
#define CR_MICRO_RPC_QUEUE_DEPTH 4
#define CR_MICRO_NOTIFY_READY_BIT BIT0
#define CR_MICRO_NOTIFY_SETTLE_MS 20
#define CR_MICRO_KEYBOARD_REPORT_GAP_MS 12
void ble_store_config_init(void);

typedef struct {
    size_t length;
    char json[CR_MICRO_RPC_RESPONSE_BYTES];
} cr_micro_rpc_response_t;

static const char *TAG = "codex_micro_hid";
static const char device_name[] = "Codex Micro";
static const char manufacturer_name[] = "Work Louder";
static esp_hid_raw_report_map_t report_maps[] = {{
    .data = cr_micro_hid_report_map,
    .len = sizeof(cr_micro_hid_report_map),
}};
static esp_hid_device_config_t hid_device_config = {
    .vendor_id = CR_MICRO_VENDOR_ID,
    .product_id = CR_MICRO_PRODUCT_ID,
    .version = CR_MICRO_RELEASE,
    .device_name = device_name,
    .manufacturer_name = manufacturer_name,
    .serial_number = NULL,
    .report_maps = report_maps,
    .report_maps_len = 1,
};

static esp_hidd_dev_t *hid_device;
static cr_codex_micro_hid_config_t callbacks;
static cr_micro_reassembler_t reassembler;
static cr_micro_state_t micro_state;
static StaticSemaphore_t transmit_lock_storage;
static SemaphoreHandle_t transmit_lock;
static StaticEventGroup_t notification_events_storage;
static EventGroupHandle_t notification_events;
static StaticQueue_t rpc_response_queue_storage;
static uint8_t rpc_response_queue_buffer[
    CR_MICRO_RPC_QUEUE_DEPTH * sizeof(cr_micro_rpc_response_t)
];
static QueueHandle_t rpc_response_queue;
static StaticTask_t rpc_response_task_storage;
static StackType_t rpc_response_task_stack[3072];
static StaticTask_t output_report_task_storage;
static StackType_t output_report_task_stack[4096];
static struct report *output_report;
static uint16_t input_notification_handle;
static TickType_t input_notification_ready_tick;
static uint8_t battery_percent;
static bool charging;
static portMUX_TYPE battery_lock = portMUX_INITIALIZER_UNLOCKED;
static uint8_t own_address_type;
static bool service_change_announced;

static int gap_event(struct ble_gap_event *event, void *context);
static void handle_output_report(const uint8_t *data, size_t length);

/*
 * ESP-IDF 5.5 NimBLE HIDD stores output writes in the HID service report
 * buffer but does not publish ESP_HIDD_OUTPUT_EVENT. This symbol is provided
 * by that service and lets the adapter bridge the missing event without
 * duplicating framing or RPC handling.
 */
struct report *find_rpt_by_handle(uint16_t handle);

static void notify_state_changed(void)
{
    if (callbacks.on_state_changed != NULL) {
        callbacks.on_state_changed(&micro_state, callbacks.context);
    }
}

static esp_err_t advertise(void)
{
    int result = ble_hs_id_infer_auto(0, &own_address_type);
    ESP_RETURN_ON_FALSE(result == 0, ESP_FAIL, TAG, "BLE address inference failed: %d", result);

    ble_uuid16_t hid_service = BLE_UUID16_INIT(0x1812);
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.appearance = ESP_HID_APPEARANCE_GENERIC;
    fields.appearance_is_present = 1;
    fields.uuids16 = &hid_service;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;
    result = ble_gap_adv_set_fields(&fields);
    ESP_RETURN_ON_FALSE(result == 0, ESP_FAIL, TAG, "BLE advertising fields failed: %d", result);
    ESP_RETURN_ON_ERROR(
        cr_ble_configure_hid_scan_response(device_name),
        TAG,
        "companion scan response failed"
    );

    struct ble_gap_adv_params params = {0};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    params.itvl_min = BLE_GAP_ADV_ITVL_MS(30);
    params.itvl_max = BLE_GAP_ADV_ITVL_MS(50);
    result = ble_gap_adv_start(
        own_address_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL
    );
    ESP_RETURN_ON_FALSE(result == 0, ESP_FAIL, TAG, "BLE advertising start failed: %d", result);
    return ESP_OK;
}

static void host_task(void *context)
{
    (void)context;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

static esp_err_t send_json(const char *json, size_t json_length)
{
    ESP_RETURN_ON_FALSE(json != NULL, ESP_ERR_INVALID_ARG, TAG, "JSON is required");
    ESP_RETURN_ON_FALSE(
        hid_device != NULL && esp_hidd_dev_connected(hid_device),
        ESP_ERR_INVALID_STATE,
        TAG,
        "HID host is not connected"
    );

    xSemaphoreTake(transmit_lock, portMAX_DELAY);
    size_t offset = 0;
    bool done = false;
    esp_err_t result = ESP_OK;
    while (!done) {
        uint8_t report[CR_MICRO_REPORT_BODY_BYTES];
        cr_micro_frame_result_t frame_result = cr_micro_vendor_frame_encode_json_chunk(
            json, json_length, &offset, report, &done
        );
        if (frame_result != CR_MICRO_FRAME_OK) {
            result = ESP_ERR_INVALID_SIZE;
            break;
        }
        result = esp_hidd_dev_input_set(
            hid_device, 0, CR_MICRO_REPORT_ID, report, sizeof(report)
        );
        if (result != ESP_OK) break;
        if (!done) vTaskDelay(pdMS_TO_TICKS(4));
    }
    xSemaphoreGive(transmit_lock);
    return result;
}

static void rpc_response_task(void *context)
{
    (void)context;
    while (true) {
        cr_micro_rpc_response_t response;
        if (xQueueReceive(rpc_response_queue, &response, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        EventBits_t bits = xEventGroupWaitBits(
            notification_events,
            CR_MICRO_NOTIFY_READY_BIT,
            pdFALSE,
            pdTRUE,
            pdMS_TO_TICKS(500)
        );
        if ((bits & CR_MICRO_NOTIFY_READY_BIT) == 0) {
            ESP_LOGW(TAG, "RPC response dropped: HID input notifications are not ready");
            continue;
        }
        TickType_t settle_ticks = pdMS_TO_TICKS(CR_MICRO_NOTIFY_SETTLE_MS);
        TickType_t elapsed = xTaskGetTickCount() - input_notification_ready_tick;
        if (elapsed < settle_ticks) vTaskDelay(settle_ticks - elapsed);
        esp_err_t result = send_json(response.json, response.length);
        if (result == ESP_OK) {
            ESP_LOGI(TAG, "RPC response sent: %u bytes", (unsigned)response.length);
        } else {
            ESP_LOGW(TAG, "RPC response failed: %s", esp_err_to_name(result));
        }
    }
}

static esp_err_t enqueue_rpc_response(const char *json, size_t length)
{
    ESP_RETURN_ON_FALSE(
        json != NULL && length < CR_MICRO_RPC_RESPONSE_BYTES,
        ESP_ERR_INVALID_SIZE,
        TAG,
        "RPC response is too large"
    );
    cr_micro_rpc_response_t response = {.length = length};
    memcpy(response.json, json, length);
    response.json[length] = '\0';
    ESP_RETURN_ON_FALSE(
        xQueueSend(rpc_response_queue, &response, 0) == pdTRUE,
        ESP_ERR_TIMEOUT,
        TAG,
        "RPC response queue is full"
    );
    return ESP_OK;
}

static void output_report_task(void *context)
{
    (void)context;
    while (true) {
        uint8_t data[CR_MICRO_REPORT_BODY_BYTES + 1];
        size_t length = 0;
        struct report *report = __atomic_load_n(&output_report, __ATOMIC_ACQUIRE);
        if (report != NULL) {
            length = __atomic_load_n(&report->len, __ATOMIC_ACQUIRE);
            if (length > 0) {
                if (length <= sizeof(data)) memcpy(data, report->data, length);
                __atomic_store_n(&report->len, 0, __ATOMIC_RELEASE);
            }
        }
        if (length == sizeof(data) && data[0] == CR_MICRO_REPORT_ID) {
            ESP_LOGI(TAG, "host HID report received: %u bytes", (unsigned)length);
            handle_output_report(data + 1, CR_MICRO_REPORT_BODY_BYTES);
        } else if (length > CR_MICRO_REPORT_BODY_BYTES) {
            ESP_LOGW(TAG, "rejected oversized NimBLE output report: %u", (unsigned)length);
        } else if (length > 0) {
            ESP_LOGI(TAG, "host HID report received: %u bytes", (unsigned)length);
            handle_output_report(data, length);
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}

static struct report *find_output_report(uint16_t input_handle)
{
    for (uint16_t handle = input_handle + 1; handle <= input_handle + 8; handle++) {
        struct report *candidate = find_rpt_by_handle(handle);
        if (candidate != NULL
            && candidate->id == CR_MICRO_REPORT_ID
            && candidate->type == BLE_SVC_HID_RPT_TYPE_OUTPUT) {
            return candidate;
        }
    }
    return NULL;
}

static void handle_output_report(const uint8_t *data, size_t length)
{
    cr_micro_frame_result_t frame_result = cr_micro_reassembler_push(
        &reassembler, data, length
    );
    if (frame_result == CR_MICRO_FRAME_NEED_MORE) return;
    if (frame_result != CR_MICRO_FRAME_MESSAGE_READY) {
        ESP_LOGW(TAG, "rejected host report: %d", frame_result);
        return;
    }

    char response[CR_MICRO_RPC_RESPONSE_BYTES];
    size_t response_length = 0;
    bool state_changed = false;
    portENTER_CRITICAL(&battery_lock);
    uint8_t current_battery_percent = battery_percent;
    bool currently_charging = charging;
    portEXIT_CRITICAL(&battery_lock);
    cr_micro_rpc_result_t rpc_result = cr_micro_rpc_respond_with_state(
        reassembler.message,
        reassembler.length,
        current_battery_percent,
        currently_charging,
        &micro_state,
        &state_changed,
        response,
        sizeof(response),
        &response_length
    );
    if (rpc_result != CR_MICRO_RPC_OK
        && rpc_result != CR_MICRO_RPC_METHOD_NOT_FOUND) {
        ESP_LOGW(TAG, "rejected host RPC: %d", rpc_result);
        cr_micro_reassembler_init(&reassembler);
        return;
    }
    ESP_LOGI(TAG, "host RPC received: %u bytes", (unsigned)reassembler.length);
    esp_err_t send_result = enqueue_rpc_response(response, response_length);
    if (send_result != ESP_OK) {
        ESP_LOGW(TAG, "RPC response enqueue failed: %s", esp_err_to_name(send_result));
    }
    if (state_changed) notify_state_changed();
    cr_micro_reassembler_init(&reassembler);
}

static void hidd_event(
    void *handler_context,
    esp_event_base_t base,
    int32_t event_id,
    void *event_data
)
{
    (void)handler_context;
    (void)base;
    esp_hidd_event_data_t *event = event_data;
    switch ((esp_hidd_event_t)event_id) {
    case ESP_HIDD_START_EVENT:
        if (advertise() != ESP_OK) ESP_LOGE(TAG, "failed to advertise Codex Micro");
        break;
    case ESP_HIDD_CONNECT_EVENT:
        cr_micro_reassembler_init(&reassembler);
        (void)cr_micro_state_set_connected(&micro_state, true);
        if (!service_change_announced) {
            ble_svc_gatt_changed(UINT16_C(0x0001), UINT16_C(0xffff));
            service_change_announced = true;
            ESP_LOGI(TAG, "GATT service change announced for keyboard report migration");
        }
        ESP_LOGI(TAG, "Codex Micro host connected");
        if (callbacks.on_connection_changed != NULL) {
            callbacks.on_connection_changed(true, callbacks.context);
        }
        notify_state_changed();
        break;
    case ESP_HIDD_OUTPUT_EVENT:
        if (event->output.map_index == 0
            && event->output.report_id == CR_MICRO_REPORT_ID) {
            handle_output_report(event->output.data, event->output.length);
        }
        break;
    case ESP_HIDD_DISCONNECT_EVENT:
        cr_micro_reassembler_init(&reassembler);
        input_notification_handle = 0;
        xEventGroupClearBits(notification_events, CR_MICRO_NOTIFY_READY_BIT);
        (void)cr_micro_state_set_connected(&micro_state, false);
        ESP_LOGI(TAG, "Codex Micro host disconnected: %d", event->disconnect.reason);
        if (callbacks.on_connection_changed != NULL) {
            callbacks.on_connection_changed(false, callbacks.context);
        }
        notify_state_changed();
        if (advertise() != ESP_OK) ESP_LOGE(TAG, "failed to resume advertising");
        break;
    default:
        break;
    }
}

static int gap_event(struct ble_gap_event *event, void *context)
{
    (void)context;
    (void)cr_ble_handle_shared_gap_event(event);
    if (event->type == BLE_GAP_EVENT_DISCONNECT) {
        __atomic_store_n(&output_report, NULL, __ATOMIC_RELEASE);
        input_notification_handle = 0;
        xEventGroupClearBits(notification_events, CR_MICRO_NOTIFY_READY_BIT);
        xQueueReset(rpc_response_queue);
    } else if (event->type == BLE_GAP_EVENT_SUBSCRIBE) {
        struct report *subscribed_report = find_rpt_by_handle(
            event->subscribe.attr_handle
        );
        bool is_vendor_input = subscribed_report != NULL
            && subscribed_report->id == CR_MICRO_REPORT_ID
            && subscribed_report->type == BLE_SVC_HID_RPT_TYPE_INPUT;
        if (event->subscribe.cur_notify
            && is_vendor_input
            && input_notification_handle == 0) {
            input_notification_handle = event->subscribe.attr_handle;
            struct report *report = find_output_report(input_notification_handle);
            if (report == NULL) {
                ESP_LOGE(TAG, "Codex Micro output report was not found");
            } else {
                __atomic_store_n(&report->len, 0, __ATOMIC_RELEASE);
                __atomic_store_n(&output_report, report, __ATOMIC_RELEASE);
                ESP_LOGI(
                    TAG,
                    "HID output bridge ready: handle=0x%04x",
                    report->handle
                );
            }
            input_notification_ready_tick = xTaskGetTickCount();
            xEventGroupSetBits(notification_events, CR_MICRO_NOTIFY_READY_BIT);
            ESP_LOGI(
                TAG,
                "HID input notifications ready: handle=0x%04x",
                input_notification_handle
            );
        } else if (!event->subscribe.cur_notify
                   && is_vendor_input
                   && event->subscribe.attr_handle == input_notification_handle) {
            input_notification_handle = 0;
            xEventGroupClearBits(notification_events, CR_MICRO_NOTIFY_READY_BIT);
            ESP_LOGI(TAG, "HID input notifications disabled");
        }
    } else if (event->type == BLE_GAP_EVENT_REPEAT_PAIRING) {
        struct ble_gap_conn_desc description;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &description) != 0) {
            return BLE_GAP_REPEAT_PAIRING_IGNORE;
        }
        ble_store_util_delete_peer(&description.peer_id_addr);
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }
    return 0;
}

esp_err_t cr_codex_micro_hid_start(const cr_codex_micro_hid_config_t *config)
{
    ESP_RETURN_ON_FALSE(hid_device == NULL, ESP_ERR_INVALID_STATE, TAG, "HID already started");
    callbacks = config == NULL ? (cr_codex_micro_hid_config_t){0} : *config;
    cr_micro_reassembler_init(&reassembler);
    cr_micro_state_init(&micro_state);
    transmit_lock = xSemaphoreCreateMutexStatic(&transmit_lock_storage);
    ESP_RETURN_ON_FALSE(transmit_lock != NULL, ESP_ERR_NO_MEM, TAG, "TX lock allocation failed");
    notification_events = xEventGroupCreateStatic(&notification_events_storage);
    ESP_RETURN_ON_FALSE(
        notification_events != NULL,
        ESP_ERR_NO_MEM,
        TAG,
        "notification event group allocation failed"
    );
    rpc_response_queue = xQueueCreateStatic(
        CR_MICRO_RPC_QUEUE_DEPTH,
        sizeof(cr_micro_rpc_response_t),
        rpc_response_queue_buffer,
        &rpc_response_queue_storage
    );
    ESP_RETURN_ON_FALSE(
        rpc_response_queue != NULL,
        ESP_ERR_NO_MEM,
        TAG,
        "RPC response queue allocation failed"
    );
    ESP_RETURN_ON_FALSE(
        xTaskCreateStatic(
            rpc_response_task,
            "micro_rpc_tx",
            sizeof(rpc_response_task_stack) / sizeof(rpc_response_task_stack[0]),
            NULL,
            5,
            rpc_response_task_stack,
            &rpc_response_task_storage
        ) != NULL,
        ESP_ERR_NO_MEM,
        TAG,
        "RPC response task allocation failed"
    );
    ESP_RETURN_ON_FALSE(
        xTaskCreateStatic(
            output_report_task,
            "micro_hid_rx",
            sizeof(output_report_task_stack) / sizeof(output_report_task_stack[0]),
            NULL,
            5,
            output_report_task_stack,
            &output_report_task_storage
        ) != NULL,
        ESP_ERR_NO_MEM,
        TAG,
        "HID output bridge task allocation failed"
    );

    ESP_RETURN_ON_ERROR(nimble_port_init(), TAG, "NimBLE init failed");
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ID | BLE_SM_PAIR_KEY_DIST_ENC;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ID | BLE_SM_PAIR_KEY_DIST_ENC;
    ESP_RETURN_ON_ERROR(
        esp_hidd_dev_init(
            &hid_device_config,
            ESP_HID_TRANSPORT_BLE,
            hidd_event,
            &hid_device
        ),
        TAG,
        "HID profile init failed"
    );
    ESP_RETURN_ON_ERROR(
        cr_ble_register_hid_companion_services(),
        TAG,
        "companion GATT registration failed"
    );
    ESP_RETURN_ON_FALSE(
        ble_svc_gap_device_name_set(device_name) == 0,
        ESP_FAIL,
        TAG,
        "failed to set GAP name"
    );
    ble_store_config_init();
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    nimble_port_freertos_init(host_task);
    ESP_LOGI(
        TAG,
        "Codex Micro HOGP ready VID=%04X PID=%04X report=%u",
        CR_MICRO_VENDOR_ID,
        CR_MICRO_PRODUCT_ID,
        CR_MICRO_REPORT_ID
    );
    return ESP_OK;
}

bool cr_codex_micro_hid_is_connected(void)
{
    return hid_device != NULL && esp_hidd_dev_connected(hid_device);
}

esp_err_t cr_codex_micro_hid_set_battery_state(uint8_t new_battery_percent, bool is_charging)
{
    ESP_RETURN_ON_FALSE(
        new_battery_percent <= 100,
        ESP_ERR_INVALID_ARG,
        TAG,
        "invalid battery percentage"
    );
    portENTER_CRITICAL(&battery_lock);
    battery_percent = new_battery_percent;
    charging = is_charging;
    portEXIT_CRITICAL(&battery_lock);
    return ESP_OK;
}

esp_err_t cr_codex_micro_hid_send_agent_key(uint8_t agent_index, bool pressed)
{
    char json[160];
    size_t length = 0;
    cr_micro_rpc_result_t result = cr_micro_rpc_encode_agent_key(
        agent_index, pressed, json, sizeof(json), &length
    );
    if (result != CR_MICRO_RPC_OK) return ESP_ERR_INVALID_ARG;
    return send_json(json, length);
}

esp_err_t cr_codex_micro_hid_send_control_key(cr_micro_control_t control, bool pressed)
{
    char json[160];
    size_t length = 0;
    cr_micro_rpc_result_t result = cr_micro_rpc_encode_control_key(
        control, pressed, json, sizeof(json), &length
    );
    if (result != CR_MICRO_RPC_OK) return ESP_ERR_INVALID_ARG;
    return send_json(json, length);
}

esp_err_t cr_codex_micro_hid_send_keyboard_action(cr_micro_keyboard_action_t action)
{
    ESP_RETURN_ON_FALSE(
        hid_device != NULL && esp_hidd_dev_connected(hid_device),
        ESP_ERR_INVALID_STATE,
        TAG,
        "HID host is not connected"
    );
    cr_micro_keyboard_sequence_t sequence;
    ESP_RETURN_ON_FALSE(
        cr_micro_keyboard_action_encode(action, &sequence) == CR_MICRO_FRAME_OK,
        ESP_ERR_INVALID_ARG,
        TAG,
        "invalid keyboard action"
    );

    xSemaphoreTake(transmit_lock, portMAX_DELAY);
    esp_err_t result = ESP_OK;
    for (size_t index = 0; index < sequence.count; index++) {
        result = esp_hidd_dev_input_set(
            hid_device,
            0,
            CR_MICRO_KEYBOARD_REPORT_ID,
            sequence.reports[index],
            CR_MICRO_KEYBOARD_REPORT_BYTES
        );
        if (result != ESP_OK) break;
        if (index + 1 < sequence.count) {
            vTaskDelay(pdMS_TO_TICKS(CR_MICRO_KEYBOARD_REPORT_GAP_MS));
        }
    }
    xSemaphoreGive(transmit_lock);
    return result;
}

esp_err_t cr_codex_micro_hid_send_encoder(cr_micro_encoder_action_t action)
{
    char json[160];
    size_t length = 0;
    cr_micro_rpc_result_t result = cr_micro_rpc_encode_encoder(
        action, json, sizeof(json), &length
    );
    if (result != CR_MICRO_RPC_OK) return ESP_ERR_INVALID_ARG;
    return send_json(json, length);
}

esp_err_t cr_codex_micro_hid_send_encoder_press(bool pressed)
{
    char json[160];
    size_t length = 0;
    cr_micro_rpc_result_t result = cr_micro_rpc_encode_encoder_press(
        pressed, json, sizeof(json), &length
    );
    if (result != CR_MICRO_RPC_OK) return ESP_ERR_INVALID_ARG;
    return send_json(json, length);
}

esp_err_t cr_codex_micro_hid_send_direction(
    cr_micro_direction_t direction,
    bool pressed
)
{
    char json[160];
    size_t length = 0;
    cr_micro_rpc_result_t result = cr_micro_rpc_encode_direction(
        direction, pressed, json, sizeof(json), &length
    );
    if (result != CR_MICRO_RPC_OK) return ESP_ERR_INVALID_ARG;
    return send_json(json, length);
}
