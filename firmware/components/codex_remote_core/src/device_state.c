#include "codex_remote/device_state.h"

#include <string.h>

static bool text_is_valid(size_t capacity, cr_byte_view_t source)
{
    return source.length < capacity && (source.length == 0 || source.bytes != NULL);
}

static bool session_is_valid(const cr_session_view_t *session)
{
    return session->state <= 5
        && text_is_valid(CR_MAX_TITLE_BYTES + 1, session->display_title)
        && text_is_valid(CR_MAX_TITLE_BYTES + 1, session->working_directory_label)
        && text_is_valid(CR_MAX_DETAIL_BYTES + 1, session->status_detail);
}

static void copy_text(char *destination, cr_byte_view_t source)
{
    if (source.length > 0) memcpy(destination, source.bytes, source.length);
    destination[source.length] = '\0';
}

static void copy_session(cr_device_session_t *destination, const cr_session_view_t *source)
{
    memset(destination, 0, sizeof(*destination));
    destination->session_key = source->session_key;
    destination->state = source->state;
    destination->unread = source->unread;
    destination->capabilities = source->capabilities;
    destination->updated_at_milliseconds = source->updated_at_milliseconds;
    copy_text(destination->display_title, source->display_title);
    copy_text(destination->working_directory_label, source->working_directory_label);
    copy_text(destination->status_detail, source->status_detail);
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
    for (size_t index = 0; index < count; index++) {
        const cr_session_view_t *session = &message->body.state_snapshot.sessions[index];
        if (!session_is_valid(session)) {
            return CR_DEVICE_INVALID_MESSAGE;
        }
        for (size_t previous = 0; previous < index; previous++) {
            if (message->body.state_snapshot.sessions[previous].session_key == session->session_key) {
                return CR_DEVICE_INVALID_MESSAGE;
            }
        }
    }

    memset(state->sessions, 0, sizeof(state->sessions));
    for (size_t index = 0; index < count; index++) {
        copy_session(&state->sessions[index], &message->body.state_snapshot.sessions[index]);
    }
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
    if (!session_is_valid(&message->body.state_delta.session)) return CR_DEVICE_INVALID_MESSAGE;
    copy_session(&state->sessions[target], &message->body.state_delta.session);
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
