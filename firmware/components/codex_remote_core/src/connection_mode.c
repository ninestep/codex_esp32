#include "codex_remote/connection_mode.h"

#include <stddef.h>

bool cr_connection_mode_is_valid(uint8_t value)
{
    return value == CR_CONNECTION_MODE_NATIVE_MICRO
        || value == CR_CONNECTION_MODE_MAC_COMPANION;
}

void cr_connection_mode_init(cr_connection_mode_state_t *state, uint8_t stored_value)
{
    if (state == NULL) return;
    cr_connection_mode_t mode = cr_connection_mode_is_valid(stored_value)
        ? (cr_connection_mode_t)stored_value
        : CR_CONNECTION_MODE_UNCONFIGURED;
    *state = (cr_connection_mode_state_t){
        .active = mode,
        .pending = mode,
        .confirmation_required = false,
        .restart_required = false,
        .input_locked = false,
    };
}

bool cr_connection_mode_request(cr_connection_mode_state_t *state, uint8_t requested_value)
{
    if (state == NULL || state->restart_required) return false;
    if (!cr_connection_mode_is_valid(requested_value)) return false;
    cr_connection_mode_t requested = (cr_connection_mode_t)requested_value;
    if (requested == state->active) return false;
    state->pending = requested;
    state->confirmation_required = true;
    return true;
}

bool cr_connection_mode_confirm(cr_connection_mode_state_t *state)
{
    if (state == NULL || !state->confirmation_required) return false;
    if (!cr_connection_mode_is_valid((uint8_t)state->pending)) return false;
    state->active = state->pending;
    state->confirmation_required = false;
    state->restart_required = true;
    state->input_locked = true;
    return true;
}

void cr_connection_mode_cancel(cr_connection_mode_state_t *state)
{
    if (state == NULL || state->restart_required) return;
    state->pending = state->active;
    state->confirmation_required = false;
}

bool cr_connection_mode_should_start_transport(const cr_connection_mode_state_t *state)
{
    return state != NULL
        && cr_connection_mode_is_valid((uint8_t)state->active)
        && !state->restart_required;
}

bool cr_connection_mode_can_accept_input(const cr_connection_mode_state_t *state)
{
    return cr_connection_mode_should_start_transport(state) && !state->input_locked;
}
