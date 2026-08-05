#ifndef CODEX_REMOTE_AUDIO_FRAME_H
#define CODEX_REMOTE_AUDIO_FRAME_H

#include "codex_remote/message.h"

#include <stddef.h>
#include <stdint.h>

cr_result_t cr_audio_frame_encode_mono(
    const int16_t *samples,
    size_t sample_count,
    uint32_t sequence,
    uint64_t sample_timestamp,
    uint8_t encoded[CR_AUDIO_ENCODED_BYTES],
    cr_message_t *message
);

cr_result_t cr_audio_frame_encode_stereo(
    const int16_t *interleaved_samples,
    size_t frame_count,
    uint32_t sequence,
    uint64_t sample_timestamp,
    uint8_t encoded[CR_AUDIO_ENCODED_BYTES],
    cr_message_t *message
);

#endif
