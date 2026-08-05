#include "codex_remote/power_state.h"

#include <string.h>

#define CR_DIM_AFTER_MS UINT64_C(60000)
#define CR_SCREENSAVER_AFTER_MS UINT64_C(120000)
#define CR_OFF_AFTER_MS UINT64_C(300000)
#define CR_ROTATE_AFTER_MS UINT64_C(30000)
#define CR_URGENT_WAKE_MS UINT64_C(8000)

void cr_power_init(cr_power_state_t *state, uint64_t now_ms)
{
    memset(state, 0, sizeof(*state));
    state->last_interaction_ms = now_ms;
    state->last_rotation_ms = now_ms;
}

void cr_power_note_interaction(cr_power_state_t *state, uint64_t now_ms)
{
    state->last_interaction_ms = now_ms;
    state->mode = CR_POWER_NORMAL;
    state->asset_index = 0;
}

void cr_power_note_urgent(cr_power_state_t *state, uint64_t now_ms)
{
    state->urgent_until_ms = now_ms + CR_URGENT_WAKE_MS;
}

cr_power_output_t cr_power_update(
    cr_power_state_t *state,
    uint64_t now_ms,
    bool ptt_active,
    size_t asset_count
)
{
    if (ptt_active) {
        cr_power_note_interaction(state, now_ms);
        return (cr_power_output_t){.mode = state->mode, .asset_index = state->asset_index};
    }

    cr_power_mode_t next_mode;
    if (now_ms < state->urgent_until_ms) {
        next_mode = CR_POWER_NORMAL;
    } else {
        uint64_t idle_ms = now_ms - state->last_interaction_ms;
        if (idle_ms >= CR_OFF_AFTER_MS) next_mode = CR_POWER_OFF;
        else if (idle_ms >= CR_SCREENSAVER_AFTER_MS) next_mode = CR_POWER_SCREENSAVER;
        else if (idle_ms >= CR_DIM_AFTER_MS) next_mode = CR_POWER_DIM;
        else next_mode = CR_POWER_NORMAL;
    }

    if (next_mode == CR_POWER_SCREENSAVER) {
        if (state->mode != CR_POWER_SCREENSAVER) {
            state->last_rotation_ms = now_ms;
            state->asset_index = 0;
        } else if (asset_count > 0 && now_ms - state->last_rotation_ms >= CR_ROTATE_AFTER_MS) {
            uint64_t rotations = (now_ms - state->last_rotation_ms) / CR_ROTATE_AFTER_MS;
            state->asset_index = (state->asset_index + (size_t)rotations) % asset_count;
            state->last_rotation_ms += rotations * CR_ROTATE_AFTER_MS;
        }
    }
    state->mode = next_mode;
    return (cr_power_output_t){.mode = state->mode, .asset_index = state->asset_index};
}
