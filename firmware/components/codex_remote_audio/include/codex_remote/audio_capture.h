#ifndef CODEX_REMOTE_AUDIO_CAPTURE_H
#define CODEX_REMOTE_AUDIO_CAPTURE_H

#include "esp_err.h"
#include <stdint.h>

typedef enum {
    CR_AUDIO_ALERT_COMPLETED = 0,
    CR_AUDIO_ALERT_REQUIRES_INPUT,
} cr_audio_alert_t;

esp_err_t cr_audio_capture_init(void);
esp_err_t cr_audio_capture_prepare(uint32_t *first_sequence);
esp_err_t cr_audio_capture_commit(void);
void cr_audio_capture_discard(void);
void cr_audio_capture_stop(uint32_t *last_sequence);
esp_err_t cr_audio_alert_play(cr_audio_alert_t alert);

#endif
