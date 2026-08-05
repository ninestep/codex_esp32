#ifndef CODEX_REMOTE_CODEC_H
#define CODEX_REMOTE_CODEC_H

#include "codex_remote/protocol.h"

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t version_major;
    uint8_t version_minor;
    uint8_t type;
    uint8_t flags;
    uint32_t sequence;
    const uint8_t *payload;
    size_t payload_length;
} cr_envelope_view_t;

cr_result_t cr_envelope_decode(
    const uint8_t *encoded,
    size_t encoded_length,
    cr_envelope_view_t *envelope
);

cr_result_t cr_envelope_encode(
    const cr_envelope_view_t *envelope,
    uint8_t *output,
    size_t output_capacity,
    size_t *written
);

#endif
