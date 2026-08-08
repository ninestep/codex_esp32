#ifndef CODEX_REMOTE_UI_H
#define CODEX_REMOTE_UI_H

#include "codex_remote/connection_mode.h"
#include "codex_remote/device_state.h"
#include "codex_remote/power_state.h"
#include "codex_micro/micro_state.h"

#include <stdint.h>

typedef struct {
    void (*select_session)(uint16_t session_key, void *context);
    void (*scroll)(uint16_t session_key, int16_t delta, void *context);
    void (*terminal_key)(uint16_t session_key, uint8_t key, void *context);
    void (*terminal_shortcut)(uint16_t session_key, uint8_t shortcut, void *context);
    void (*micro_agent_key)(uint8_t agent_index, bool pressed, void *context);
    void (*request_connection_mode)(cr_connection_mode_t mode, void *context);
    void (*confirm_connection_mode)(void *context);
    void (*cancel_connection_mode)(void *context);
    void (*interaction)(void *context);
    void *context;
} cr_ui_callbacks_t;

void cr_ui_init(const cr_ui_callbacks_t *callbacks);
void cr_ui_update(const cr_device_state_t *state);
void cr_ui_update_micro(const cr_micro_state_t *state);
void cr_ui_set_connection_mode(const cr_connection_mode_state_t *state);
void cr_ui_set_power(cr_power_mode_t mode, size_t asset_index);

#endif
