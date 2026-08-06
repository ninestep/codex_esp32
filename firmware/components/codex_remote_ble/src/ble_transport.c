#include "codex_remote/ble_transport.h"

#include "codex_remote/advertising_layout.h"
#include "codex_remote/codec.h"
#include "codex_remote/fragment.h"
#include "codex_remote/message.h"
#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "os/os_mbuf.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include <string.h>

#define CR_REASSEMBLY_BYTES ((size_t)16384)
#define CR_ENCODED_BYTES ((size_t)4096)
#define CR_DEVICE_CAPABILITIES UINT16_C(0x000f)
#define CR_BLE_NO_CONNECTION UINT16_MAX

void ble_store_config_init(void);

static const char *TAG = "codex_remote_ble";

static const ble_uuid128_t service_uuid = BLE_UUID128_INIT(
    0x01, 0x00, 0x52, 0x4c, 0x6b, 0x9f, 0xe1, 0xa3,
    0x6d, 0x4e, 0x6a, 0x7c, 0x00, 0x00, 0x2e, 0x7d
);
#define CR_UUID_CHARACTERISTIC(number) BLE_UUID128_INIT( \
    0x01, 0x00, 0x52, 0x4c, 0x6b, 0x9f, 0xe1, 0xa3, \
    0x6d, 0x4e, 0x6a, 0x7c, number, 0x00, 0x2e, 0x7d)
static const ble_uuid128_t control_to_host_uuid = CR_UUID_CHARACTERISTIC(0x01);
static const ble_uuid128_t control_to_device_uuid = CR_UUID_CHARACTERISTIC(0x02);
static const ble_uuid128_t state_to_device_uuid = CR_UUID_CHARACTERISTIC(0x03);
static const ble_uuid128_t audio_to_host_uuid = CR_UUID_CHARACTERISTIC(0x04);
static const ble_uuid128_t asset_to_device_uuid = CR_UUID_CHARACTERISTIC(0x05);
static const ble_uuid128_t device_info_uuid = CR_UUID_CHARACTERISTIC(0x06);

static uint16_t control_to_host_handle;
static uint16_t audio_to_host_handle;
static uint16_t device_info_handle;
static uint16_t connection_handle = CR_BLE_NO_CONNECTION;
static uint8_t own_address_type;
static cr_device_state_t *device_state;
static cr_ble_config_t callbacks;
static cr_fragment_reassembler_t control_reassembler;
static cr_fragment_reassembler_t state_reassembler;
static cr_fragment_reassembler_t asset_reassembler;
static uint8_t control_storage[CR_REASSEMBLY_BYTES];
static uint8_t state_storage[CR_REASSEMBLY_BYTES];
static uint8_t asset_storage[CR_REASSEMBLY_BYTES];
static uint32_t next_envelope_sequence = 1;
static uint32_t next_message_id = 1;
static uint32_t next_request_id = 1;
static uint32_t next_scroll_sequence = 1;
static uint32_t pending_select_request;
static uint16_t pending_select_key;
static uint8_t tx_payload[CR_ENCODED_BYTES];
static uint8_t tx_envelope[CR_ENCODED_BYTES + CR_ENVELOPE_FIXED_OVERHEAD];
static StaticSemaphore_t tx_lock_storage;
static SemaphoreHandle_t tx_lock;
static StaticQueue_t device_info_queue_storage;
static uint8_t device_info_queue_buffer[sizeof(uint16_t)];
static QueueHandle_t device_info_queue;

static void advertise(void);

static void publish_state(void)
{
    if (callbacks.on_state_changed != NULL) {
        callbacks.on_state_changed(device_state, callbacks.callback_context);
    }
}

static int notify_fragmented(
    uint16_t conn_handle,
    uint16_t value_handle,
    bool indicate,
    const uint8_t *message,
    size_t length
)
{
    if (conn_handle == CR_BLE_NO_CONNECTION) return BLE_HS_ENOTCONN;
    uint16_t mtu = ble_att_mtu(conn_handle);
    if (mtu <= CR_FRAGMENT_HEADER_BYTES + 3) return BLE_HS_EMSGSIZE;
    size_t packet_limit = (size_t)mtu - 3;
    size_t payload_limit = packet_limit - CR_FRAGMENT_HEADER_BYTES;
    size_t count = length == 0 ? 1 : (length + payload_limit - 1) / payload_limit;
    if (count > CR_MAX_FRAGMENTS) return BLE_HS_EMSGSIZE;

    uint32_t message_id = next_message_id++;
    for (size_t index = 0; index < count; index++) {
        size_t offset = index * payload_limit;
        size_t payload_length = length - offset < payload_limit ? length - offset : payload_limit;
        struct os_mbuf *packet = ble_hs_mbuf_from_flat(NULL, 0);
        if (packet == NULL) return BLE_HS_ENOMEM;
        uint8_t header[CR_FRAGMENT_HEADER_BYTES] = {
            (uint8_t)message_id, (uint8_t)(message_id >> 8),
            (uint8_t)(message_id >> 16), (uint8_t)(message_id >> 24),
            (uint8_t)index, (uint8_t)(index >> 8),
            (uint8_t)count, (uint8_t)(count >> 8),
        };
        int rc = os_mbuf_append(packet, header, sizeof(header));
        if (rc == 0 && payload_length > 0) rc = os_mbuf_append(packet, message + offset, payload_length);
        if (rc != 0) {
            os_mbuf_free_chain(packet);
            return rc;
        }
        rc = indicate
            ? ble_gatts_indicate_custom(conn_handle, value_handle, packet)
            : ble_gatts_notify_custom(conn_handle, value_handle, packet);
        if (rc != 0) return rc;
    }
    return 0;
}

static int send_message_on_connection(
    const cr_message_t *message,
    uint16_t value_handle,
    bool indicate,
    uint16_t conn_handle
)
{
    xSemaphoreTake(tx_lock, portMAX_DELAY);
    size_t payload_length = 0;
    cr_result_t result = cr_message_encode(message, tx_payload, sizeof(tx_payload), &payload_length);
    if (result != CR_OK) {
        xSemaphoreGive(tx_lock);
        return BLE_HS_EAPP;
    }
    cr_envelope_view_t envelope = {
        .version_major = CR_PROTOCOL_MAJOR,
        .version_minor = CR_PROTOCOL_MINOR,
        .type = message->type,
        .flags = 0,
        .sequence = next_envelope_sequence++,
        .payload = tx_payload,
        .payload_length = payload_length,
    };
    size_t envelope_length = 0;
    result = cr_envelope_encode(&envelope, tx_envelope, sizeof(tx_envelope), &envelope_length);
    if (result != CR_OK) {
        xSemaphoreGive(tx_lock);
        return BLE_HS_EAPP;
    }
    int rc = notify_fragmented(conn_handle, value_handle, indicate, tx_envelope, envelope_length);
    xSemaphoreGive(tx_lock);
    return rc;
}

static int send_message(const cr_message_t *message, uint16_t value_handle, bool indicate)
{
    return send_message_on_connection(message, value_handle, indicate, connection_handle);
}

static int send_device_info(uint16_t conn_handle)
{
    static const uint8_t firmware[] = "0.1.0";
    cr_message_t message = {
        .type = CR_MESSAGE_DEVICE_INFO,
        .body.device_info = {
            .protocol_major = CR_PROTOCOL_MAJOR,
            .protocol_minor = CR_PROTOCOL_MINOR,
            .firmware_version = {.bytes = firmware, .length = sizeof(firmware) - 1},
            .capabilities = CR_DEVICE_CAPABILITIES,
            .battery_percent = 100,
        },
    };
    return send_message_on_connection(&message, device_info_handle, false, conn_handle);
}

static void queue_device_info(uint16_t conn_handle)
{
    xQueueOverwrite(device_info_queue, &conn_handle);
}

static void device_info_task(void *context)
{
    (void)context;
    uint16_t conn_handle;
    while (true) {
        if (xQueueReceive(device_info_queue, &conn_handle, portMAX_DELAY) != pdTRUE) continue;
        int rc = send_device_info(conn_handle);
        if (rc != 0) {
            ESP_LOGW(TAG, "device info notify failed: %d", rc);
        } else {
            ESP_LOGI(TAG, "device info sent on connection %u", (unsigned)conn_handle);
        }
    }
}

static void handle_complete_message(cr_byte_view_t complete)
{
    cr_envelope_view_t envelope;
    cr_message_t message;
    if (cr_envelope_decode(complete.bytes, complete.length, &envelope) != CR_OK
        || cr_message_decode(&envelope, &message) != CR_OK) {
        ESP_LOGW(TAG, "discarding malformed host message");
        return;
    }

    if (message.type == CR_MESSAGE_STATE_SNAPSHOT || message.type == CR_MESSAGE_STATE_DELTA) {
        cr_device_result_t result = cr_device_apply_message(device_state, &message);
        if (result == CR_DEVICE_APPLIED) publish_state();
        return;
    }
    if (message.type == CR_MESSAGE_ACTION_RESULT
        && message.body.action_result.request_id == pending_select_request) {
        if (message.body.action_result.result == 0) {
            (void)cr_device_select_session(device_state, pending_select_key);
            publish_state();
        }
        pending_select_request = 0;
    }
}

static int accept_write(cr_fragment_reassembler_t *reassembler, struct os_mbuf *om)
{
    size_t length = OS_MBUF_PKTLEN(om);
    if (length > 517) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    uint8_t packet[517];
    uint16_t copied = 0;
    int rc = ble_hs_mbuf_to_flat(om, packet, sizeof(packet), &copied);
    if (rc != 0) return BLE_ATT_ERR_UNLIKELY;
    cr_byte_view_t complete = {0};
    cr_fragment_result_t result = cr_fragment_reassembler_accept(reassembler, packet, copied, &complete);
    if (result == CR_FRAGMENT_COMPLETE) handle_complete_message(complete);
    return result < 0 ? BLE_ATT_ERR_UNLIKELY : 0;
}

static int gatt_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    cr_fragment_reassembler_t *reassembler = arg;
    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR && reassembler != NULL) {
        return accept_write(reassembler, ctxt->om);
    }
    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR && attr == device_info_handle) {
        static const uint8_t version[] = "Codex Remote 0.1.0";
        return os_mbuf_append(ctxt->om, version, sizeof(version) - 1) == 0
            ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    (void)conn;
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def services[] = {{
    .type = BLE_GATT_SVC_TYPE_PRIMARY,
    .uuid = &service_uuid.u,
    .characteristics = (struct ble_gatt_chr_def[]) {
        {.uuid = &control_to_host_uuid.u, .access_cb = gatt_access,
         .flags = BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_INDICATE | BLE_GATT_CHR_F_READ_ENC,
         .val_handle = &control_to_host_handle},
        {.uuid = &control_to_device_uuid.u, .access_cb = gatt_access, .arg = &control_reassembler,
         .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC},
        {.uuid = &state_to_device_uuid.u, .access_cb = gatt_access, .arg = &state_reassembler,
         .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC},
        {.uuid = &audio_to_host_uuid.u, .access_cb = gatt_access,
         .flags = BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_READ_ENC,
         .val_handle = &audio_to_host_handle},
        {.uuid = &asset_to_device_uuid.u, .access_cb = gatt_access, .arg = &asset_reassembler,
         .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC},
        {.uuid = &device_info_uuid.u, .access_cb = gatt_access,
         .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
         .val_handle = &device_info_handle},
        {0},
    },
}, {0}};

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            connection_handle = event->connect.conn_handle;
            ESP_LOGI(TAG, "Mac connected");
        } else {
            advertise();
        }
        return 0;
    case BLE_GAP_EVENT_DISCONNECT:
        connection_handle = CR_BLE_NO_CONNECTION;
        cr_device_state_disconnect(device_state);
        publish_state();
        advertise();
        return 0;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == device_info_handle && event->subscribe.cur_notify) {
            queue_device_info(event->subscribe.conn_handle);
        }
        return 0;
    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0) {
            ble_store_util_delete_peer(&desc.peer_id_addr);
        }
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }
    default:
        return 0;
    }
}

static void advertise(void)
{
    const char *device_name = ble_svc_gap_device_name();
    const cr_ble_advertising_layout_t layout = cr_ble_advertising_layout(strlen(device_name));
    if (!layout.fits_legacy_limits) {
        ESP_LOGE(TAG, "advertising name is too long: %u bytes", (unsigned)strlen(device_name));
        return;
    }

    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)&service_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "advertising data failed: %d", rc);
        return;
    }

    struct ble_hs_adv_fields response = {0};
    response.name = (uint8_t *)device_name;
    response.name_len = strlen(device_name);
    response.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&response);
    if (rc != 0) {
        ESP_LOGE(TAG, "scan response data failed: %d", rc);
        return;
    }

    struct ble_gap_adv_params params = {
        .conn_mode = BLE_GAP_CONN_MODE_UND,
        .disc_mode = BLE_GAP_DISC_MODE_GEN,
    };
    rc = ble_gap_adv_start(own_address_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
    if (rc != 0) ESP_LOGE(TAG, "advertising start failed: %d", rc);
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc == 0) rc = ble_hs_id_infer_auto(0, &own_address_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "BLE identity unavailable: %d", rc);
        return;
    }
    advertise();
}

static void host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t cr_ble_start(cr_device_state_t *state, const cr_ble_config_t *config)
{
    ESP_RETURN_ON_FALSE(state != NULL && config != NULL, ESP_ERR_INVALID_ARG, TAG, "invalid config");
    tx_lock = xSemaphoreCreateMutexStatic(&tx_lock_storage);
    device_state = state;
    callbacks = *config;
    cr_fragment_reassembler_init(&control_reassembler, control_storage, sizeof(control_storage));
    cr_fragment_reassembler_init(&state_reassembler, state_storage, sizeof(state_storage));
    cr_fragment_reassembler_init(&asset_reassembler, asset_storage, sizeof(asset_storage));

    ESP_RETURN_ON_ERROR(nimble_port_init(), TAG, "NimBLE init failed");
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    ble_store_config_init();
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ESP_RETURN_ON_FALSE(ble_svc_gap_device_name_set("Codex Remote") == 0, ESP_FAIL, TAG, "name failed");
    ESP_RETURN_ON_FALSE(ble_gatts_count_cfg(services) == 0, ESP_FAIL, TAG, "GATT count failed");
    ESP_RETURN_ON_FALSE(ble_gatts_add_svcs(services) == 0, ESP_FAIL, TAG, "GATT add failed");
    device_info_queue = xQueueCreateStatic(
        1,
        sizeof(uint16_t),
        device_info_queue_buffer,
        &device_info_queue_storage
    );
    ESP_RETURN_ON_FALSE(device_info_queue != NULL, ESP_ERR_NO_MEM, TAG, "device info queue failed");
    ESP_RETURN_ON_FALSE(
        xTaskCreatePinnedToCore(
            device_info_task, "device_info", 4096, NULL, 5, NULL, NIMBLE_CORE
        ) == pdPASS,
        ESP_ERR_NO_MEM,
        TAG,
        "device info task failed"
    );
    nimble_port_freertos_init(host_task);
    return ESP_OK;
}

esp_err_t cr_ble_send_select(uint16_t session_key)
{
    uint32_t request_id = next_request_id++;
    cr_message_t message = {.type = CR_MESSAGE_SELECT_SESSION};
    message.body.select_session.request_id = request_id;
    message.body.select_session.session_key = session_key;
    int rc = send_message(&message, control_to_host_handle, true);
    if (rc == 0) {
        pending_select_request = request_id;
        pending_select_key = session_key;
    }
    return rc == 0 ? ESP_OK : ESP_FAIL;
}

esp_err_t cr_ble_send_scroll(uint16_t session_key, int16_t delta)
{
    cr_message_t message = {.type = CR_MESSAGE_SCROLL};
    message.body.scroll.session_key = session_key;
    message.body.scroll.delta = delta;
    message.body.scroll.sequence = next_scroll_sequence++;
    return send_message(&message, control_to_host_handle, false) == 0 ? ESP_OK : ESP_FAIL;
}

esp_err_t cr_ble_send_terminal_key(uint16_t session_key, uint8_t key)
{
    cr_message_t message = {.type = CR_MESSAGE_TERMINAL_KEY};
    message.body.terminal_key.request_id = next_request_id++;
    message.body.terminal_key.session_key = session_key;
    message.body.terminal_key.key = key;
    return send_message(&message, control_to_host_handle, true) == 0 ? ESP_OK : ESP_FAIL;
}

esp_err_t cr_ble_send_ptt_begin(uint16_t session_key, uint32_t first_audio_sequence)
{
    cr_message_t message = {.type = CR_MESSAGE_PTT_BEGIN};
    message.body.ptt_begin.request_id = next_request_id++;
    message.body.ptt_begin.session_key = session_key;
    message.body.ptt_begin.first_audio_sequence = first_audio_sequence;
    return send_message(&message, control_to_host_handle, true) == 0 ? ESP_OK : ESP_FAIL;
}

esp_err_t cr_ble_send_ptt_end(uint16_t session_key, uint32_t last_audio_sequence)
{
    cr_message_t message = {.type = CR_MESSAGE_PTT_END};
    message.body.ptt_end.request_id = next_request_id++;
    message.body.ptt_end.session_key = session_key;
    message.body.ptt_end.last_audio_sequence = last_audio_sequence;
    return send_message(&message, control_to_host_handle, true) == 0 ? ESP_OK : ESP_FAIL;
}

esp_err_t cr_ble_send_audio_frame(const cr_message_t *audio_frame)
{
    if (audio_frame == NULL || audio_frame->type != CR_MESSAGE_AUDIO_FRAME) {
        return ESP_ERR_INVALID_ARG;
    }
    return send_message(audio_frame, audio_to_host_handle, false) == 0 ? ESP_OK : ESP_FAIL;
}
