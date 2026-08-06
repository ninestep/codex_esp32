#ifndef CODEX_REMOTE_BLE_TRANSPORT_H
#define CODEX_REMOTE_BLE_TRANSPORT_H

#include "codex_remote/device_state.h"

#include "esp_err.h"
#include <stdint.h>

typedef void (*cr_ble_state_callback_t)(const cr_device_state_t *state, void *context);

typedef struct {
    cr_ble_state_callback_t on_state_changed;
    void *callback_context;
} cr_ble_config_t;

esp_err_t cr_ble_start(cr_device_state_t *device_state, const cr_ble_config_t *config);
esp_err_t cr_ble_send_select(uint16_t session_key);
esp_err_t cr_ble_send_scroll(uint16_t session_key, int16_t delta);
esp_err_t cr_ble_send_terminal_key(uint16_t session_key, uint8_t key);
esp_err_t cr_ble_send_terminal_shortcut(uint16_t session_key, uint8_t shortcut);
esp_err_t cr_ble_send_ptt_begin(uint16_t session_key, uint32_t first_audio_sequence);
esp_err_t cr_ble_send_ptt_end(uint16_t session_key, uint32_t last_audio_sequence);
esp_err_t cr_ble_send_audio_frame(const cr_message_t *audio_frame);

#endif
