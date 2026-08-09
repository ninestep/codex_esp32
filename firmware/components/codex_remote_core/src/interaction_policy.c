#include "codex_remote/interaction_policy.h"

bool cr_detail_idle_timeout_reached(uint64_t now_ms, uint64_t last_interaction_ms)
{
    return now_ms >= last_interaction_ms
        && now_ms - last_interaction_ms >= CR_DETAIL_IDLE_TIMEOUT_MS;
}
