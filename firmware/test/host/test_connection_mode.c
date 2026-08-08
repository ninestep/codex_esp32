#include "codex_remote/connection_mode.h"

#include <assert.h>
#include <stdio.h>

static void test_unconfigured_and_invalid_values_do_not_start_transport(void)
{
    cr_connection_mode_state_t state;

    cr_connection_mode_init(&state, CR_CONNECTION_MODE_UNCONFIGURED);
    assert(state.active == CR_CONNECTION_MODE_UNCONFIGURED);
    assert(!cr_connection_mode_should_start_transport(&state));
    assert(!cr_connection_mode_can_accept_input(&state));

    cr_connection_mode_init(&state, UINT8_MAX);
    assert(state.active == CR_CONNECTION_MODE_UNCONFIGURED);
    assert(!cr_connection_mode_should_start_transport(&state));
    assert(!cr_connection_mode_can_accept_input(&state));
}

static void test_saved_modes_boot_ready(void)
{
    cr_connection_mode_state_t state;

    cr_connection_mode_init(&state, CR_CONNECTION_MODE_NATIVE_MICRO);
    assert(state.active == CR_CONNECTION_MODE_NATIVE_MICRO);
    assert(cr_connection_mode_should_start_transport(&state));
    assert(cr_connection_mode_can_accept_input(&state));

    cr_connection_mode_init(&state, CR_CONNECTION_MODE_MAC_COMPANION);
    assert(state.active == CR_CONNECTION_MODE_MAC_COMPANION);
    assert(cr_connection_mode_should_start_transport(&state));
    assert(cr_connection_mode_can_accept_input(&state));
}

static void test_mode_change_requires_confirmation_and_restart(void)
{
    cr_connection_mode_state_t state;
    cr_connection_mode_init(&state, CR_CONNECTION_MODE_MAC_COMPANION);

    assert(cr_connection_mode_request(&state, CR_CONNECTION_MODE_NATIVE_MICRO));
    assert(state.active == CR_CONNECTION_MODE_MAC_COMPANION);
    assert(state.pending == CR_CONNECTION_MODE_NATIVE_MICRO);
    assert(state.confirmation_required);
    assert(!state.restart_required);
    assert(cr_connection_mode_can_accept_input(&state));

    assert(cr_connection_mode_confirm(&state));
    assert(state.active == CR_CONNECTION_MODE_NATIVE_MICRO);
    assert(!state.confirmation_required);
    assert(state.restart_required);
    assert(!cr_connection_mode_should_start_transport(&state));
    assert(!cr_connection_mode_can_accept_input(&state));
}

static void test_first_selection_requires_confirmation(void)
{
    cr_connection_mode_state_t state;
    cr_connection_mode_init(&state, CR_CONNECTION_MODE_UNCONFIGURED);

    assert(cr_connection_mode_request(&state, CR_CONNECTION_MODE_MAC_COMPANION));
    assert(state.active == CR_CONNECTION_MODE_UNCONFIGURED);
    assert(state.pending == CR_CONNECTION_MODE_MAC_COMPANION);
    assert(state.confirmation_required);
    assert(cr_connection_mode_confirm(&state));
    assert(state.active == CR_CONNECTION_MODE_MAC_COMPANION);
    assert(state.restart_required);
    assert(!cr_connection_mode_can_accept_input(&state));
}

static void test_cancel_and_invalid_requests_preserve_active_mode(void)
{
    cr_connection_mode_state_t state;
    cr_connection_mode_init(&state, CR_CONNECTION_MODE_MAC_COMPANION);

    assert(!cr_connection_mode_request(&state, CR_CONNECTION_MODE_UNCONFIGURED));
    assert(!cr_connection_mode_request(&state, UINT8_MAX));
    assert(!cr_connection_mode_request(&state, CR_CONNECTION_MODE_MAC_COMPANION));
    assert(!state.confirmation_required);

    assert(cr_connection_mode_request(&state, CR_CONNECTION_MODE_NATIVE_MICRO));
    cr_connection_mode_cancel(&state);
    assert(state.active == CR_CONNECTION_MODE_MAC_COMPANION);
    assert(state.pending == CR_CONNECTION_MODE_MAC_COMPANION);
    assert(!state.confirmation_required);
    assert(!state.restart_required);
    assert(cr_connection_mode_can_accept_input(&state));
}

int main(void)
{
    test_unconfigured_and_invalid_values_do_not_start_transport();
    test_saved_modes_boot_ready();
    test_mode_change_requires_confirmation_and_restart();
    test_first_selection_requires_confirmation();
    test_cancel_and_invalid_requests_preserve_active_mode();
    puts("test_connection_mode: PASS");
    return 0;
}
