#ifndef CODEX_MICRO_HID_TRANSPORT_H
#define CODEX_MICRO_HID_TRANSPORT_H

#include "codex_micro/micro_state.h"
#include "codex_micro/rpc_codec.h"
#include "codex_micro/vendor_frame.h"
#include "esp_err.h"

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    void (*on_connection_changed)(bool connected, void *context);
    void (*on_state_changed)(const cr_micro_state_t *state, void *context);
    void *context;
} cr_codex_micro_hid_config_t;

esp_err_t cr_codex_micro_hid_start(const cr_codex_micro_hid_config_t *config);
bool cr_codex_micro_hid_is_connected(void);
esp_err_t cr_codex_micro_hid_set_battery_state(uint8_t battery_percent, bool charging);
esp_err_t cr_codex_micro_hid_send_agent_key(uint8_t agent_index, bool pressed);
esp_err_t cr_codex_micro_hid_send_control_key(cr_micro_control_t control, bool pressed);
esp_err_t cr_codex_micro_hid_send_keyboard_action(cr_micro_keyboard_action_t action);
esp_err_t cr_codex_micro_hid_send_encoder(cr_micro_encoder_action_t action);
esp_err_t cr_codex_micro_hid_send_encoder_press(bool pressed);
esp_err_t cr_codex_micro_hid_send_direction(
    cr_micro_direction_t direction,
    bool pressed
);

#endif
