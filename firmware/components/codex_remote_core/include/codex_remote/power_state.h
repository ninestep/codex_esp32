#ifndef CODEX_REMOTE_POWER_STATE_H
#define CODEX_REMOTE_POWER_STATE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    CR_POWER_NORMAL = 0,
    CR_POWER_DIM,
    CR_POWER_SCREENSAVER,
    CR_POWER_OFF,
} cr_power_mode_t;

typedef struct {
    cr_power_mode_t mode;
    size_t asset_index;
} cr_power_output_t;

typedef struct {
    uint64_t last_interaction_ms;
    uint64_t urgent_until_ms;
    uint64_t last_rotation_ms;
    cr_power_mode_t mode;
    size_t asset_index;
} cr_power_state_t;

void cr_power_init(cr_power_state_t *state, uint64_t now_ms);
void cr_power_note_interaction(cr_power_state_t *state, uint64_t now_ms);
void cr_power_note_urgent(cr_power_state_t *state, uint64_t now_ms);
cr_power_output_t cr_power_update(
    cr_power_state_t *state,
    uint64_t now_ms,
    bool ptt_active,
    size_t asset_count
);

#endif
