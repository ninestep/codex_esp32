#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static void read_source(const char *path, char *buffer, size_t capacity)
{
    FILE *file = fopen(path, "rb");
    assert(file != NULL);
    size_t length = fread(buffer, 1, capacity - 1, file);
    assert(!ferror(file));
    assert(feof(file));
    buffer[length] = '\0';
    fclose(file);
}

int main(void)
{
    char audio_source[16384];
    read_source(
        "firmware/components/codex_remote_audio/src/audio_capture.c",
        audio_source,
        sizeof(audio_source)
    );

    assert(strstr(audio_source, "static int16_t pcm_buffer[CR_AUDIO_SAMPLE_COUNT]") != NULL);
    assert(strstr(audio_source, "static uint8_t encoded_buffer[CR_AUDIO_ENCODED_BYTES]") != NULL);
    assert(strstr(audio_source, "static cr_message_t encoded_message") != NULL);
    assert(strstr(audio_source, "static stored_frame_t streaming_frame") != NULL);
    const char *capture_task = strstr(audio_source, "static void capture_task");
    const char *capture_task_end = strstr(audio_source, "esp_err_t cr_audio_capture_init");
    assert(capture_task != NULL);
    assert(capture_task_end != NULL);
    const char *local_pcm = strstr(capture_task, "int16_t pcm[CR_AUDIO_SAMPLE_COUNT]");
    const char *local_encoded = strstr(capture_task, "uint8_t encoded[CR_AUDIO_ENCODED_BYTES]");
    assert(local_pcm == NULL || local_pcm >= capture_task_end);
    assert(local_encoded == NULL || local_encoded >= capture_task_end);

    char cmake_source[2048];
    read_source(
        "firmware/components/codex_remote_audio/CMakeLists.txt",
        cmake_source,
        sizeof(cmake_source)
    );
    assert(strstr(cmake_source, "-Wframe-larger-than=1024") != NULL);

    puts("test_audio_runtime: PASS");
    return 0;
}
