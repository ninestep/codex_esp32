#ifndef CODEX_REMOTE_DEVICE_STATE_H
#define CODEX_REMOTE_DEVICE_STATE_H

#include "codex_remote/message.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CR_REQUEST_CACHE_SIZE ((size_t)16)

typedef enum {
    CR_DEVICE_APPLIED = 0,
    CR_DEVICE_DUPLICATE,
    CR_DEVICE_UNAVAILABLE,
    CR_DEVICE_INVALID_MESSAGE,
    CR_DEVICE_RESYNC_CONNECTION_RESET,
    CR_DEVICE_RESYNC_SEQUENCE_GAP,
    CR_DEVICE_RESYNC_STALE_GENERATION,
} cr_device_result_t;

typedef struct {
    uint16_t session_key;
    char display_title[CR_MAX_TITLE_BYTES + 1];
    char working_directory_label[CR_MAX_TITLE_BYTES + 1];
    uint8_t state;
    char status_detail[CR_MAX_DETAIL_BYTES + 1];
    bool unread;
    uint16_t capabilities;
    uint64_t updated_at_milliseconds;
} cr_device_session_t;

typedef struct {
    bool has_snapshot;
    uint32_t generation;
    uint32_t next_delta_sequence;
    size_t session_count;
    cr_device_session_t sessions[CR_MAX_SESSIONS];
    bool has_selection;
    uint16_t selected_session_key;
    bool ptt_active;
    bool has_scroll_sequence;
    uint32_t last_scroll_sequence;
    uint32_t request_ids[CR_REQUEST_CACHE_SIZE];
    size_t request_count;
    size_t next_request_slot;
} cr_device_state_t;

void cr_device_state_init(cr_device_state_t *state);
void cr_device_state_disconnect(cr_device_state_t *state);
cr_device_result_t cr_device_apply_message(cr_device_state_t *state, const cr_message_t *message);
cr_device_result_t cr_device_select_session(cr_device_state_t *state, uint16_t session_key);
cr_device_result_t cr_device_record_request(cr_device_state_t *state, uint32_t request_id);
cr_device_result_t cr_device_accept_scroll_sequence(cr_device_state_t *state, uint32_t sequence);

#endif
