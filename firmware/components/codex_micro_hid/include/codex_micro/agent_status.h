#ifndef CODEX_MICRO_AGENT_STATUS_H
#define CODEX_MICRO_AGENT_STATUS_H

#include "codex_micro/micro_state.h"

typedef enum {
    CR_MICRO_AGENT_IDLE = 0,
    CR_MICRO_AGENT_WORKING,
    CR_MICRO_AGENT_COMPLETED,
    CR_MICRO_AGENT_REQUIRES_INPUT,
    CR_MICRO_AGENT_ERROR,
    CR_MICRO_AGENT_OFFLINE,
} cr_micro_agent_status_t;

cr_micro_agent_status_t cr_micro_agent_status(const cr_micro_light_t *light);

#endif
