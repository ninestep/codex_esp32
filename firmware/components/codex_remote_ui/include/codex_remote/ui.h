#ifndef CODEX_REMOTE_UI_H
#define CODEX_REMOTE_UI_H

#include "codex_remote/device_state.h"
#include "codex_remote/power_state.h"

#include <stdint.h>

typedef struct {
    void (*select_session)(uint16_t session_key, void *context);
    void (*scroll)(uint16_t session_key, int16_t delta, void *context);
    void (*terminal_key)(uint16_t session_key, uint8_t key, void *context);
    void (*interaction)(void *context);
    void *context;
} cr_ui_callbacks_t;

void cr_ui_init(const cr_ui_callbacks_t *callbacks);
void cr_ui_update(const cr_device_state_t *state);
void cr_ui_set_power(cr_power_mode_t mode, size_t asset_index);

#endif
