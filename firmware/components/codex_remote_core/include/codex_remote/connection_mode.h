#ifndef CODEX_REMOTE_CONNECTION_MODE_H
#define CODEX_REMOTE_CONNECTION_MODE_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    CR_CONNECTION_MODE_UNCONFIGURED = 0,
    CR_CONNECTION_MODE_NATIVE_MICRO = 1,
    CR_CONNECTION_MODE_MAC_COMPANION = 2,
} cr_connection_mode_t;

typedef struct {
    cr_connection_mode_t active;
    cr_connection_mode_t pending;
    bool confirmation_required;
    bool restart_required;
    bool input_locked;
} cr_connection_mode_state_t;

bool cr_connection_mode_is_valid(uint8_t value);
void cr_connection_mode_init(cr_connection_mode_state_t *state, uint8_t stored_value);
bool cr_connection_mode_request(cr_connection_mode_state_t *state, uint8_t requested_value);
bool cr_connection_mode_confirm(cr_connection_mode_state_t *state);
void cr_connection_mode_cancel(cr_connection_mode_state_t *state);
bool cr_connection_mode_should_start_transport(const cr_connection_mode_state_t *state);
bool cr_connection_mode_can_accept_input(const cr_connection_mode_state_t *state);

#endif
