#ifndef CODEX_MICRO_STATE_H
#define CODEX_MICRO_STATE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CR_MICRO_SLOT_COUNT ((size_t)6)

typedef struct {
    uint32_t color;
    uint8_t brightness;
    uint8_t effect;
    uint8_t speed;
    uint8_t magic;
    bool sync_keys;
    bool sync_ambient;
    bool configured;
} cr_micro_light_t;

typedef struct {
    bool connected;
    uint32_t generation;
    cr_micro_light_t slots[CR_MICRO_SLOT_COUNT];
    cr_micro_light_t keys;
    cr_micro_light_t ambient;
} cr_micro_state_t;

void cr_micro_state_init(cr_micro_state_t *state);
bool cr_micro_state_set_connected(cr_micro_state_t *state, bool connected);
bool cr_micro_state_set_slot(
    cr_micro_state_t *state,
    uint8_t index,
    const cr_micro_light_t *light
);
bool cr_micro_state_set_global_lighting(
    cr_micro_state_t *state,
    const cr_micro_light_t *keys,
    const cr_micro_light_t *ambient
);

#endif
