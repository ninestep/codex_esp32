#include "codex_micro/micro_state.h"

#include <string.h>

void cr_micro_state_init(cr_micro_state_t *state)
{
    if (state != NULL) memset(state, 0, sizeof(*state));
}

bool cr_micro_state_set_connected(cr_micro_state_t *state, bool connected)
{
    if (state == NULL || state->connected == connected) return false;
    state->connected = connected;
    state->generation++;
    return true;
}

bool cr_micro_state_set_slot(
    cr_micro_state_t *state,
    uint8_t index,
    const cr_micro_light_t *light
)
{
    if (state == NULL || light == NULL || index >= CR_MICRO_SLOT_COUNT) return false;
    if (memcmp(&state->slots[index], light, sizeof(*light)) == 0) return false;
    state->slots[index] = *light;
    state->generation++;
    return true;
}

bool cr_micro_state_set_global_lighting(
    cr_micro_state_t *state,
    const cr_micro_light_t *keys,
    const cr_micro_light_t *ambient
)
{
    if (state == NULL || keys == NULL || ambient == NULL) return false;
    if (memcmp(&state->keys, keys, sizeof(*keys)) == 0
        && memcmp(&state->ambient, ambient, sizeof(*ambient)) == 0) return false;
    state->keys = *keys;
    state->ambient = *ambient;
    state->generation++;
    return true;
}
