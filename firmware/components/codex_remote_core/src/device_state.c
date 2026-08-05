#include "codex_remote/device_state.h"

#include <string.h>

static bool copy_text(char *destination, size_t capacity, cr_byte_view_t source)
{
    if (source.length >= capacity || (source.length > 0 && source.bytes == NULL)) return false;
    if (source.length > 0) memcpy(destination, source.bytes, source.length);
    destination[source.length] = '\0';
    return true;
}

static bool copy_session(cr_device_session_t *destination, const cr_session_view_t *source)
{
    if (source->state > 5) return false;
    cr_device_session_t session = {
        .session_key = source->session_key,
        .state = source->state,
        .unread = source->unread,
        .capabilities = source->capabilities,
        .updated_at_milliseconds = source->updated_at_milliseconds,
    };
    if (!copy_text(session.display_title, sizeof(session.display_title), source->display_title)
        || !copy_text(
            session.working_directory_label,
            sizeof(session.working_directory_label),
            source->working_directory_label
        )
        || !copy_text(session.status_detail, sizeof(session.status_detail), source->status_detail)) {
        return false;
    }
    *destination = session;
    return true;
}

static void invalidate_snapshot(cr_device_state_t *state)
{
    state->has_snapshot = false;
    state->generation = 0;
    state->next_delta_sequence = 0;
    state->session_count = 0;
    state->has_selection = false;
    state->selected_session_key = 0;
    state->ptt_active = false;
    state->has_scroll_sequence = false;
    state->last_scroll_sequence = 0;
}

void cr_device_state_init(cr_device_state_t *state)
{
    memset(state, 0, sizeof(*state));
}

void cr_device_state_disconnect(cr_device_state_t *state)
{
    memset(state, 0, sizeof(*state));
}

static cr_device_result_t apply_snapshot(cr_device_state_t *state, const cr_message_t *message)
{
    size_t count = message->body.state_snapshot.session_count;
    if (count > CR_MAX_SESSIONS) return CR_DEVICE_INVALID_MESSAGE;
    cr_device_session_t sessions[CR_MAX_SESSIONS] = {0};
    for (size_t index = 0; index < count; index++) {
        if (!copy_session(&sessions[index], &message->body.state_snapshot.sessions[index])) {
            return CR_DEVICE_INVALID_MESSAGE;
        }
        for (size_t previous = 0; previous < index; previous++) {
            if (sessions[previous].session_key == sessions[index].session_key) {
                return CR_DEVICE_INVALID_MESSAGE;
            }
        }
    }

    memcpy(state->sessions, sessions, sizeof(sessions));
    state->session_count = count;
    state->generation = message->body.state_snapshot.generation;
    state->next_delta_sequence = 1;
    state->has_snapshot = true;
    state->has_selection = false;
    state->selected_session_key = 0;
    state->ptt_active = false;
    state->has_scroll_sequence = false;
    return CR_DEVICE_APPLIED;
}

static cr_device_result_t apply_delta(cr_device_state_t *state, const cr_message_t *message)
{
    if (!state->has_snapshot) return CR_DEVICE_RESYNC_CONNECTION_RESET;
    if (message->body.state_delta.generation != state->generation) {
        invalidate_snapshot(state);
        return CR_DEVICE_RESYNC_STALE_GENERATION;
    }
    if (message->body.state_delta.sequence != state->next_delta_sequence) {
        invalidate_snapshot(state);
        return CR_DEVICE_RESYNC_SEQUENCE_GAP;
    }

    size_t target = state->session_count;
    for (size_t index = 0; index < state->session_count; index++) {
        if (state->sessions[index].session_key == message->body.state_delta.session.session_key) {
            target = index;
            break;
        }
    }
    if (target == state->session_count && state->session_count == CR_MAX_SESSIONS) {
        return CR_DEVICE_INVALID_MESSAGE;
    }
    cr_device_session_t updated = {0};
    if (!copy_session(&updated, &message->body.state_delta.session)) return CR_DEVICE_INVALID_MESSAGE;
    state->sessions[target] = updated;
    if (target == state->session_count) state->session_count++;
    state->next_delta_sequence++;
    return CR_DEVICE_APPLIED;
}

cr_device_result_t cr_device_apply_message(cr_device_state_t *state, const cr_message_t *message)
{
    if (state == NULL || message == NULL) return CR_DEVICE_INVALID_MESSAGE;
    if (message->type == CR_MESSAGE_STATE_SNAPSHOT) return apply_snapshot(state, message);
    if (message->type == CR_MESSAGE_STATE_DELTA) return apply_delta(state, message);
    return CR_DEVICE_INVALID_MESSAGE;
}

cr_device_result_t cr_device_select_session(cr_device_state_t *state, uint16_t session_key)
{
    if (state == NULL || !state->has_snapshot) return CR_DEVICE_UNAVAILABLE;
    for (size_t index = 0; index < state->session_count; index++) {
        if (state->sessions[index].session_key == session_key) {
            state->has_selection = true;
            state->selected_session_key = session_key;
            state->has_scroll_sequence = false;
            return CR_DEVICE_APPLIED;
        }
    }
    return CR_DEVICE_UNAVAILABLE;
}

cr_device_result_t cr_device_record_request(cr_device_state_t *state, uint32_t request_id)
{
    if (state == NULL) return CR_DEVICE_INVALID_MESSAGE;
    for (size_t index = 0; index < state->request_count; index++) {
        if (state->request_ids[index] == request_id) return CR_DEVICE_DUPLICATE;
    }
    state->request_ids[state->next_request_slot] = request_id;
    state->next_request_slot = (state->next_request_slot + 1) % CR_REQUEST_CACHE_SIZE;
    if (state->request_count < CR_REQUEST_CACHE_SIZE) state->request_count++;
    return CR_DEVICE_APPLIED;
}

cr_device_result_t cr_device_accept_scroll_sequence(cr_device_state_t *state, uint32_t sequence)
{
    if (state == NULL || !state->has_selection) return CR_DEVICE_UNAVAILABLE;
    if (!state->has_scroll_sequence) {
        if (sequence != 1) return CR_DEVICE_RESYNC_SEQUENCE_GAP;
        state->has_scroll_sequence = true;
        state->last_scroll_sequence = sequence;
        return CR_DEVICE_APPLIED;
    }
    if (sequence <= state->last_scroll_sequence) return CR_DEVICE_DUPLICATE;
    if (sequence != state->last_scroll_sequence + 1) return CR_DEVICE_RESYNC_SEQUENCE_GAP;
    state->last_scroll_sequence = sequence;
    return CR_DEVICE_APPLIED;
}
