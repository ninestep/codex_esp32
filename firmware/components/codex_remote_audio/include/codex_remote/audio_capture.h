#ifndef CODEX_REMOTE_AUDIO_CAPTURE_H
#define CODEX_REMOTE_AUDIO_CAPTURE_H

#include "esp_err.h"
#include <stdint.h>

esp_err_t cr_audio_capture_init(void);
esp_err_t cr_audio_capture_prepare(uint32_t *first_sequence);
esp_err_t cr_audio_capture_commit(void);
void cr_audio_capture_discard(void);
void cr_audio_capture_stop(uint32_t *last_sequence);

#endif
