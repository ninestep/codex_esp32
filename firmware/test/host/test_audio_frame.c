#include "codex_remote/audio_frame.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_silence_matches_swift_frame(void)
{
    int16_t samples[CR_AUDIO_SAMPLE_COUNT] = {0};
    uint8_t encoded[CR_AUDIO_ENCODED_BYTES];
    cr_message_t message;

    assert(cr_audio_frame_encode_mono(samples, CR_AUDIO_SAMPLE_COUNT, 7, 12345, encoded, &message) == CR_OK);
    assert(message.type == CR_MESSAGE_AUDIO_FRAME);
    assert(message.body.audio_frame.sequence == 7);
    assert(message.body.audio_frame.sample_timestamp == 12345);
    assert(message.body.audio_frame.predictor == 0);
    assert(message.body.audio_frame.step_index == 0);
    assert(message.body.audio_frame.sample_count == 320);
    assert(message.body.audio_frame.encoded_samples.length == 160);
    for (size_t index = 0; index < sizeof(encoded); index++) assert(encoded[index] == 0);
}

static void test_stereo_is_averaged_before_encoding(void)
{
    int16_t stereo[CR_AUDIO_SAMPLE_COUNT * 2];
    int16_t mono[CR_AUDIO_SAMPLE_COUNT];
    for (size_t index = 0; index < CR_AUDIO_SAMPLE_COUNT; index++) {
        stereo[index * 2] = (int16_t)(index * 50);
        stereo[index * 2 + 1] = (int16_t)(index * 30);
        mono[index] = (int16_t)(index * 40);
    }
    uint8_t stereo_encoded[CR_AUDIO_ENCODED_BYTES];
    uint8_t mono_encoded[CR_AUDIO_ENCODED_BYTES];
    cr_message_t stereo_message;
    cr_message_t mono_message;

    assert(cr_audio_frame_encode_stereo(stereo, CR_AUDIO_SAMPLE_COUNT, 1, 0, stereo_encoded, &stereo_message) == CR_OK);
    assert(cr_audio_frame_encode_mono(mono, CR_AUDIO_SAMPLE_COUNT, 1, 0, mono_encoded, &mono_message) == CR_OK);
    assert(memcmp(stereo_encoded, mono_encoded, sizeof(stereo_encoded)) == 0);
}

int main(void)
{
    test_silence_matches_swift_frame();
    test_stereo_is_averaged_before_encoding();
    puts("test_audio_frame: PASS");
    return 0;
}
