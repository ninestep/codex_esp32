#ifndef CODEX_REMOTE_BLE_TRANSPORT_H
#define CODEX_REMOTE_BLE_TRANSPORT_H

#include "codex_remote/device_state.h"

#include "esp_err.h"
#include <stdbool.h>
#include <stdint.h>

struct ble_gap_event;

typedef void (*cr_ble_state_callback_t)(const cr_device_state_t *state, void *context);
typedef void (*cr_ble_micro_layout_callback_t)(const cr_message_t *message, void *context);

typedef struct {
    cr_ble_state_callback_t on_state_changed;
    cr_ble_micro_layout_callback_t on_micro_layout_changed;
    void *callback_context;
} cr_ble_config_t;

esp_err_t cr_ble_start(cr_device_state_t *device_state, const cr_ble_config_t *config);
esp_err_t cr_ble_prepare_hid_companion(
    cr_device_state_t *device_state,
    const cr_ble_config_t *config
);
esp_err_t cr_ble_register_hid_companion_services(void);
esp_err_t cr_ble_configure_hid_scan_response(const char *device_name);
int cr_ble_handle_shared_gap_event(struct ble_gap_event *event);
bool cr_ble_is_connected(void);
esp_err_t cr_ble_send_select(uint16_t session_key);
esp_err_t cr_ble_send_scroll(uint16_t session_key, int16_t delta);
esp_err_t cr_ble_send_terminal_key(uint16_t session_key, uint8_t key);
esp_err_t cr_ble_send_terminal_shortcut(uint16_t session_key, uint8_t shortcut);
esp_err_t cr_ble_send_ptt_begin(uint16_t session_key, uint32_t first_audio_sequence);
esp_err_t cr_ble_send_ptt_end(uint16_t session_key, uint32_t last_audio_sequence);
esp_err_t cr_ble_send_audio_frame(const cr_message_t *audio_frame);

#endif
