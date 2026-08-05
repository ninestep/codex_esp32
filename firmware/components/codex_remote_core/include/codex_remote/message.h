#ifndef CODEX_REMOTE_MESSAGE_H
#define CODEX_REMOTE_MESSAGE_H

#include "codex_remote/codec.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CR_MAX_SESSIONS ((size_t)8)
#define CR_MAX_ASSETS ((size_t)8)
#define CR_MAX_TITLE_BYTES ((size_t)64)
#define CR_MAX_DETAIL_BYTES ((size_t)192)
#define CR_AUDIO_SAMPLE_COUNT UINT16_C(320)
#define CR_AUDIO_ENCODED_BYTES ((size_t)160)

typedef struct {
    const uint8_t *bytes;
    size_t length;
} cr_byte_view_t;

typedef struct {
    uint16_t session_key;
    cr_byte_view_t display_title;
    cr_byte_view_t working_directory_label;
    uint8_t state;
    cr_byte_view_t status_detail;
    bool unread;
    uint16_t capabilities;
    uint64_t updated_at_milliseconds;
} cr_session_view_t;

typedef struct {
    uint16_t asset_id;
    uint16_t width;
    uint16_t height;
    uint32_t byte_count;
    uint32_t crc32;
} cr_asset_descriptor_t;

typedef struct {
    uint8_t type;
    union {
        struct { uint32_t request_id; uint16_t session_key; } select_session;
        struct { uint16_t session_key; int16_t delta; uint32_t sequence; } scroll;
        struct { uint32_t request_id; uint16_t session_key; uint8_t key; } terminal_key;
        struct { uint32_t request_id; uint16_t session_key; uint32_t first_audio_sequence; } ptt_begin;
        struct { uint32_t request_id; uint16_t session_key; uint32_t last_audio_sequence; } ptt_end;
        struct { uint32_t request_id; uint8_t result; cr_byte_view_t detail; } action_result;
        struct { uint32_t generation; size_t session_count; cr_session_view_t sessions[CR_MAX_SESSIONS]; } state_snapshot;
        struct { uint32_t generation; uint32_t sequence; cr_session_view_t session; } state_delta;
        struct {
            uint32_t sequence;
            uint64_t sample_timestamp;
            int16_t predictor;
            uint8_t step_index;
            uint16_t sample_count;
            cr_byte_view_t encoded_samples;
        } audio_frame;
        struct {
            uint32_t set_id;
            uint32_t total_bytes;
            size_t item_count;
            cr_asset_descriptor_t items[CR_MAX_ASSETS];
        } asset_manifest;
        struct { uint32_t set_id; uint16_t asset_id; uint32_t offset; cr_byte_view_t bytes; } asset_chunk;
        struct { uint32_t set_id; uint16_t asset_id; uint32_t next_offset; uint8_t result; } asset_acknowledgement;
        struct { uint8_t protocol_major; uint8_t protocol_minor; cr_byte_view_t firmware_version; uint16_t capabilities; uint8_t battery_percent; } device_info;
        struct { uint8_t reason; } resync_required;
    } body;
} cr_message_t;

cr_result_t cr_message_decode(const cr_envelope_view_t *envelope, cr_message_t *message);
cr_result_t cr_message_encode(
    const cr_message_t *message,
    uint8_t *output,
    size_t output_capacity,
    size_t *written
);

#endif
