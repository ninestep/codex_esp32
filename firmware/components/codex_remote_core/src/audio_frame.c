#include "codex_remote/audio_frame.h"

#include <limits.h>

static const int index_adjustments[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8,
};

static const int steps[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
    34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
    157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
    598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707,
    1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
    5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};

static uint8_t encode_nibble(int sample, int *predictor, int *step_index)
{
    int step = steps[*step_index];
    int difference = sample - *predictor;
    int nibble = 0;
    if (difference < 0) {
        nibble = 8;
        difference = -difference;
    }
    int reconstructed = step >> 3;
    if (difference >= step) {
        nibble |= 4;
        difference -= step;
        reconstructed += step;
    }
    if (difference >= (step >> 1)) {
        nibble |= 2;
        difference -= step >> 1;
        reconstructed += step >> 1;
    }
    if (difference >= (step >> 2)) {
        nibble |= 1;
        reconstructed += step >> 2;
    }
    *predictor += (nibble & 8) == 0 ? reconstructed : -reconstructed;
    if (*predictor > INT16_MAX) *predictor = INT16_MAX;
    if (*predictor < INT16_MIN) *predictor = INT16_MIN;
    *step_index += index_adjustments[nibble];
    if (*step_index > 88) *step_index = 88;
    if (*step_index < 0) *step_index = 0;
    return (uint8_t)nibble;
}

cr_result_t cr_audio_frame_encode_mono(
    const int16_t *samples,
    size_t sample_count,
    uint32_t sequence,
    uint64_t sample_timestamp,
    uint8_t encoded[CR_AUDIO_ENCODED_BYTES],
    cr_message_t *message
)
{
    if (samples == NULL || encoded == NULL || message == NULL) return CR_ERR_INVALID_ARGUMENT;
    if (sample_count != CR_AUDIO_SAMPLE_COUNT) return CR_ERR_INVALID_PAYLOAD;
    int16_t initial_predictor = samples[0];
    int predictor = initial_predictor;
    int step_index = 0;
    for (size_t index = 0; index < sample_count; index += 2) {
        uint8_t low = encode_nibble(samples[index], &predictor, &step_index);
        uint8_t high = encode_nibble(samples[index + 1], &predictor, &step_index);
        encoded[index / 2] = (uint8_t)(low | (uint8_t)(high << 4));
    }
    *message = (cr_message_t){.type = CR_MESSAGE_AUDIO_FRAME};
    message->body.audio_frame.sequence = sequence;
    message->body.audio_frame.sample_timestamp = sample_timestamp;
    message->body.audio_frame.predictor = initial_predictor;
    message->body.audio_frame.step_index = 0;
    message->body.audio_frame.sample_count = CR_AUDIO_SAMPLE_COUNT;
    message->body.audio_frame.encoded_samples = (cr_byte_view_t){
        .bytes = encoded,
        .length = CR_AUDIO_ENCODED_BYTES,
    };
    return CR_OK;
}

cr_result_t cr_audio_frame_encode_stereo(
    const int16_t *interleaved_samples,
    size_t frame_count,
    uint32_t sequence,
    uint64_t sample_timestamp,
    uint8_t encoded[CR_AUDIO_ENCODED_BYTES],
    cr_message_t *message
)
{
    if (interleaved_samples == NULL) return CR_ERR_INVALID_ARGUMENT;
    if (frame_count != CR_AUDIO_SAMPLE_COUNT) return CR_ERR_INVALID_PAYLOAD;
    int16_t mono[CR_AUDIO_SAMPLE_COUNT];
    for (size_t index = 0; index < frame_count; index++) {
        int32_t sum = (int32_t)interleaved_samples[index * 2]
            + (int32_t)interleaved_samples[index * 2 + 1];
        mono[index] = (int16_t)(sum / 2);
    }
    return cr_audio_frame_encode_mono(
        mono, frame_count, sequence, sample_timestamp, encoded, message
    );
}
