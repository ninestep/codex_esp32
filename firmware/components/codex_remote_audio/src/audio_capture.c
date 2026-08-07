#include "codex_remote/audio_capture.h"

#include "codex_remote/audio_frame.h"
#include "codex_remote/ble_transport.h"
#include "bsp/esp-bsp.h"
#include "driver/i2s_std.h"
#include "esp_codec_dev.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include <string.h>

#define PRE_ROLL_FRAME_COUNT 20
#define AUDIO_CHANNEL_COUNT 2
#define MICROPHONE_GAIN_DB 30.0f

typedef enum {
    CAPTURE_IDLE,
    CAPTURE_PRE_ROLL,
    CAPTURE_STREAMING,
} capture_mode_t;

typedef struct {
    uint32_t sequence;
    uint64_t timestamp;
    int16_t predictor;
    uint8_t encoded[CR_AUDIO_ENCODED_BYTES];
} stored_frame_t;

static const char *TAG = "codex_remote_audio";
static esp_codec_dev_handle_t microphone;
static SemaphoreHandle_t lock;
static capture_mode_t mode;
static stored_frame_t pre_roll[PRE_ROLL_FRAME_COUNT];
static size_t pre_roll_start;
static size_t pre_roll_count;
static uint32_t next_sequence = 1;
static uint32_t last_sequence;
static int16_t stereo_pcm_buffer[CR_AUDIO_SAMPLE_COUNT * AUDIO_CHANNEL_COUNT];
static int16_t mono_pcm_buffer[CR_AUDIO_SAMPLE_COUNT];
static uint8_t encoded_buffer[CR_AUDIO_ENCODED_BYTES];
static cr_message_t encoded_message;
static stored_frame_t streaming_frame;
static uint32_t channel_peak[AUDIO_CHANNEL_COUNT];
static uint64_t channel_absolute_sum[AUDIO_CHANNEL_COUNT];
static uint64_t channel_sample_count;

static void log_internal_heap(const char *stage)
{
    ESP_LOGI(
        TAG,
        "%s: internal heap free=%u largest=%u",
        stage,
        (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
        (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL)
    );
}

static void send_stored(const stored_frame_t *stored)
{
    cr_message_t message = {.type = CR_MESSAGE_AUDIO_FRAME};
    message.body.audio_frame.sequence = stored->sequence;
    message.body.audio_frame.sample_timestamp = stored->timestamp;
    message.body.audio_frame.predictor = stored->predictor;
    message.body.audio_frame.step_index = 0;
    message.body.audio_frame.sample_count = CR_AUDIO_SAMPLE_COUNT;
    message.body.audio_frame.encoded_samples = (cr_byte_view_t){
        .bytes = stored->encoded,
        .length = CR_AUDIO_ENCODED_BYTES,
    };
    if (cr_ble_send_audio_frame(&message) != ESP_OK) {
        ESP_LOGW(TAG, "audio frame %" PRIu32 " dropped", stored->sequence);
    }
}

static void capture_task(void *context)
{
    (void)context;
    while (true) {
        xSemaphoreTake(lock, portMAX_DELAY);
        capture_mode_t current_mode = mode;
        xSemaphoreGive(lock);
        if (current_mode == CAPTURE_IDLE) {
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }
        if (esp_codec_dev_read(microphone, stereo_pcm_buffer, sizeof(stereo_pcm_buffer)) != ESP_CODEC_DEV_OK) {
            ESP_LOGW(TAG, "microphone read failed");
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }

        uint32_t frame_peak[AUDIO_CHANNEL_COUNT] = {0};
        uint64_t frame_absolute_sum[AUDIO_CHANNEL_COUNT] = {0};
        for (size_t index = 0; index < CR_AUDIO_SAMPLE_COUNT; index++) {
            int32_t left = stereo_pcm_buffer[index * AUDIO_CHANNEL_COUNT];
            int32_t right = stereo_pcm_buffer[index * AUDIO_CHANNEL_COUNT + 1];
            mono_pcm_buffer[index] = (int16_t)((left + right) / AUDIO_CHANNEL_COUNT);
            int32_t channels[AUDIO_CHANNEL_COUNT] = {left, right};
            for (size_t channel = 0; channel < AUDIO_CHANNEL_COUNT; channel++) {
                uint32_t magnitude = (uint32_t)(channels[channel] < 0 ? -channels[channel] : channels[channel]);
                if (magnitude > frame_peak[channel]) frame_peak[channel] = magnitude;
                frame_absolute_sum[channel] += magnitude;
            }
        }

        uint32_t sequence = next_sequence++;
        uint64_t timestamp = (uint64_t)(esp_timer_get_time() * 16 / 1000);
        if (cr_audio_frame_encode_mono(
            mono_pcm_buffer, CR_AUDIO_SAMPLE_COUNT, sequence, timestamp, encoded_buffer, &encoded_message
        ) != CR_OK) continue;

        xSemaphoreTake(lock, portMAX_DELAY);
        current_mode = mode;
        if (current_mode != CAPTURE_IDLE) {
            for (size_t channel = 0; channel < AUDIO_CHANNEL_COUNT; channel++) {
                if (frame_peak[channel] > channel_peak[channel]) channel_peak[channel] = frame_peak[channel];
                channel_absolute_sum[channel] += frame_absolute_sum[channel];
            }
            channel_sample_count += CR_AUDIO_SAMPLE_COUNT;
        }
        if (current_mode == CAPTURE_PRE_ROLL) {
            size_t target = (pre_roll_start + pre_roll_count) % PRE_ROLL_FRAME_COUNT;
            if (pre_roll_count == PRE_ROLL_FRAME_COUNT) {
                pre_roll_start = (pre_roll_start + 1) % PRE_ROLL_FRAME_COUNT;
                target = (pre_roll_start + pre_roll_count - 1) % PRE_ROLL_FRAME_COUNT;
            } else {
                pre_roll_count++;
            }
            pre_roll[target] = (stored_frame_t){
                .sequence = sequence,
                .timestamp = timestamp,
                .predictor = encoded_message.body.audio_frame.predictor,
            };
            memcpy(pre_roll[target].encoded, encoded_buffer, sizeof(encoded_buffer));
        }
        xSemaphoreGive(lock);

        if (current_mode == CAPTURE_STREAMING) {
            streaming_frame = (stored_frame_t){
                .sequence = sequence,
                .timestamp = timestamp,
                .predictor = encoded_message.body.audio_frame.predictor,
            };
            memcpy(streaming_frame.encoded, encoded_buffer, sizeof(encoded_buffer));
            send_stored(&streaming_frame);
            last_sequence = sequence;
        }
    }
}

esp_err_t cr_audio_capture_init(void)
{
    log_internal_heap("audio init begin");
    i2s_std_config_t i2s_config = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(16000),
        .slot_cfg = I2S_STD_PHILIP_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = BSP_I2S_MCLK,
            .bclk = BSP_I2S_SCLK,
            .ws = BSP_I2S_LCLK,
            .dout = BSP_I2S_DOUT,
            .din = BSP_I2S_DSIN,
            .invert_flags = {0},
        },
    };
    esp_err_t result = bsp_i2c_init();
    if (result != ESP_OK) return result;
    result = bsp_audio_init(&i2s_config);
    if (result != ESP_OK) return result;
    microphone = bsp_audio_codec_microphone_init();
    if (microphone == NULL) return ESP_FAIL;
    esp_codec_dev_sample_info_t sample_info = {
        .bits_per_sample = 16,
        .channel = AUDIO_CHANNEL_COUNT,
        .sample_rate = 16000,
    };
    if (esp_codec_dev_open(microphone, &sample_info) != ESP_CODEC_DEV_OK) return ESP_FAIL;
    if (esp_codec_dev_set_in_gain(microphone, MICROPHONE_GAIN_DB) != ESP_CODEC_DEV_OK) return ESP_FAIL;
    log_internal_heap("audio codec opened");
    lock = xSemaphoreCreateMutex();
    if (lock == NULL) {
        log_internal_heap("audio mutex allocation failed");
        return ESP_ERR_NO_MEM;
    }
    if (xTaskCreate(capture_task, "audio_capture", 4096, NULL, 6, NULL) != pdPASS) {
        log_internal_heap("audio task allocation failed");
        return ESP_ERR_NO_MEM;
    }
    log_internal_heap("audio init ready");
    return ESP_OK;
}

esp_err_t cr_audio_capture_prepare(uint32_t *first_sequence)
{
    if (first_sequence == NULL || lock == NULL) return ESP_ERR_INVALID_STATE;
    xSemaphoreTake(lock, portMAX_DELAY);
    if (mode != CAPTURE_IDLE) {
        xSemaphoreGive(lock);
        return ESP_ERR_INVALID_STATE;
    }
    pre_roll_start = 0;
    pre_roll_count = 0;
    memset(channel_peak, 0, sizeof(channel_peak));
    memset(channel_absolute_sum, 0, sizeof(channel_absolute_sum));
    channel_sample_count = 0;
    mode = CAPTURE_PRE_ROLL;
    *first_sequence = next_sequence;
    xSemaphoreGive(lock);
    return ESP_OK;
}

esp_err_t cr_audio_capture_commit(void)
{
    if (lock == NULL) return ESP_ERR_INVALID_STATE;
    xSemaphoreTake(lock, portMAX_DELAY);
    if (mode != CAPTURE_PRE_ROLL) {
        xSemaphoreGive(lock);
        return ESP_ERR_INVALID_STATE;
    }
    for (size_t index = 0; index < pre_roll_count; index++) {
        send_stored(&pre_roll[(pre_roll_start + index) % PRE_ROLL_FRAME_COUNT]);
        last_sequence = pre_roll[(pre_roll_start + index) % PRE_ROLL_FRAME_COUNT].sequence;
    }
    pre_roll_count = 0;
    mode = CAPTURE_STREAMING;
    xSemaphoreGive(lock);
    return ESP_OK;
}

void cr_audio_capture_discard(void)
{
    if (lock == NULL) return;
    xSemaphoreTake(lock, portMAX_DELAY);
    mode = CAPTURE_IDLE;
    pre_roll_count = 0;
    xSemaphoreGive(lock);
}

void cr_audio_capture_stop(uint32_t *completed_last_sequence)
{
    if (lock == NULL) return;
    xSemaphoreTake(lock, portMAX_DELAY);
    mode = CAPTURE_IDLE;
    pre_roll_count = 0;
    ESP_LOGI(
        TAG,
        "microphone summary: samples=%" PRIu64 " left_peak=%u left_avg_abs=%" PRIu64
        " right_peak=%u right_avg_abs=%" PRIu64,
        channel_sample_count,
        (unsigned)channel_peak[0],
        channel_sample_count == 0 ? 0 : channel_absolute_sum[0] / channel_sample_count,
        (unsigned)channel_peak[1],
        channel_sample_count == 0 ? 0 : channel_absolute_sum[1] / channel_sample_count
    );
    if (completed_last_sequence != NULL) *completed_last_sequence = last_sequence;
    xSemaphoreGive(lock);
}
