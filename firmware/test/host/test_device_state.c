#include "codex_remote/device_state.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static cr_byte_view_t text(const char *value)
{
    return (cr_byte_view_t){.bytes = (const uint8_t *)value, .length = strlen(value)};
}

static cr_session_view_t session(uint16_t key, uint8_t state)
{
    return (cr_session_view_t){
        .session_key = key,
        .display_title = text(key == 1 ? "esp32" : "backend"),
        .working_directory_label = text(key == 1 ? "mcp/esp32" : "api"),
        .state = state,
        .status_detail = text(state == 1 ? "Codex 正在处理" : "空闲"),
        .capabilities = 7,
        .updated_at_milliseconds = 1700000000000ULL + key,
    };
}

static cr_message_t snapshot(uint32_t generation)
{
    cr_message_t message = {.type = CR_MESSAGE_STATE_SNAPSHOT};
    message.body.state_snapshot.generation = generation;
    message.body.state_snapshot.session_count = 2;
    message.body.state_snapshot.sessions[0] = session(1, 0);
    message.body.state_snapshot.sessions[1] = session(2, 1);
    return message;
}

static void test_snapshot_is_required_before_delta(void)
{
    cr_device_state_t state;
    cr_device_state_init(&state);
    cr_message_t delta = {.type = CR_MESSAGE_STATE_DELTA};
    delta.body.state_delta.generation = 4;
    delta.body.state_delta.sequence = 1;
    delta.body.state_delta.session = session(1, 1);

    assert(cr_device_apply_message(&state, &delta) == CR_DEVICE_RESYNC_CONNECTION_RESET);
    assert(state.session_count == 0);

    cr_message_t initial = snapshot(4);
    assert(cr_device_apply_message(&state, &initial) == CR_DEVICE_APPLIED);
    assert(state.has_snapshot);
    assert(state.session_count == 2);
    assert(state.sessions[0].session_key == 1);
    assert(strcmp(state.sessions[0].display_title, "esp32") == 0);
}

static void test_delta_requires_current_generation_and_sequence(void)
{
    cr_device_state_t state;
    cr_device_state_init(&state);
    cr_message_t initial = snapshot(7);
    assert(cr_device_apply_message(&state, &initial) == CR_DEVICE_APPLIED);

    cr_message_t delta = {.type = CR_MESSAGE_STATE_DELTA};
    delta.body.state_delta.generation = 7;
    delta.body.state_delta.sequence = 1;
    delta.body.state_delta.session = session(2, 3);
    assert(cr_device_apply_message(&state, &delta) == CR_DEVICE_APPLIED);
    assert(state.sessions[1].state == 3);

    delta.body.state_delta.sequence = 3;
    assert(cr_device_apply_message(&state, &delta) == CR_DEVICE_RESYNC_SEQUENCE_GAP);
    assert(!state.has_snapshot);

    initial = snapshot(9);
    assert(cr_device_apply_message(&state, &initial) == CR_DEVICE_APPLIED);
    delta.body.state_delta.generation = 8;
    delta.body.state_delta.sequence = 1;
    assert(cr_device_apply_message(&state, &delta) == CR_DEVICE_RESYNC_STALE_GENERATION);
}

static void test_invalid_snapshot_does_not_partially_replace_state(void)
{
    cr_device_state_t state;
    cr_device_state_init(&state);
    cr_message_t initial = snapshot(7);
    assert(cr_device_apply_message(&state, &initial) == CR_DEVICE_APPLIED);

    cr_message_t invalid = snapshot(8);
    invalid.body.state_snapshot.sessions[0] = session(3, 2);
    invalid.body.state_snapshot.sessions[1] = session(4, 6);

    assert(cr_device_apply_message(&state, &invalid) == CR_DEVICE_INVALID_MESSAGE);
    assert(state.generation == 7);
    assert(state.session_count == 2);
    assert(state.sessions[0].session_key == 1);
    assert(state.sessions[1].session_key == 2);
}

static void test_selection_and_request_deduplication(void)
{
    cr_device_state_t state;
    cr_device_state_init(&state);
    cr_message_t initial = snapshot(1);
    assert(cr_device_apply_message(&state, &initial) == CR_DEVICE_APPLIED);

    assert(cr_device_select_session(&state, 99) == CR_DEVICE_UNAVAILABLE);
    assert(!state.has_selection);
    assert(cr_device_select_session(&state, 2) == CR_DEVICE_APPLIED);
    assert(state.has_selection && state.selected_session_key == 2);

    assert(cr_device_record_request(&state, 100) == CR_DEVICE_APPLIED);
    assert(cr_device_record_request(&state, 100) == CR_DEVICE_DUPLICATE);
    assert(cr_device_accept_scroll_sequence(&state, 1) == CR_DEVICE_APPLIED);
    assert(cr_device_accept_scroll_sequence(&state, 1) == CR_DEVICE_DUPLICATE);
    assert(cr_device_accept_scroll_sequence(&state, 3) == CR_DEVICE_RESYNC_SEQUENCE_GAP);
}

static void test_disconnect_clears_connection_scoped_state(void)
{
    cr_device_state_t state;
    cr_device_state_init(&state);
    cr_message_t initial = snapshot(1);
    assert(cr_device_apply_message(&state, &initial) == CR_DEVICE_APPLIED);
    assert(cr_device_select_session(&state, 1) == CR_DEVICE_APPLIED);
    assert(cr_device_record_request(&state, 7) == CR_DEVICE_APPLIED);
    assert(cr_device_accept_scroll_sequence(&state, 1) == CR_DEVICE_APPLIED);
    state.ptt_active = true;

    cr_device_state_disconnect(&state);
    assert(!state.has_snapshot);
    assert(!state.has_selection);
    assert(!state.ptt_active);
    assert(state.session_count == 0);
    assert(cr_device_record_request(&state, 7) == CR_DEVICE_APPLIED);
    assert(cr_device_accept_scroll_sequence(&state, 1) == CR_DEVICE_UNAVAILABLE);
}

int main(void)
{
    test_snapshot_is_required_before_delta();
    test_delta_requires_current_generation_and_sequence();
    test_invalid_snapshot_does_not_partially_replace_state();
    test_selection_and_request_deduplication();
    test_disconnect_clears_connection_scoped_state();
    puts("test_device_state: PASS");
    return 0;
}
