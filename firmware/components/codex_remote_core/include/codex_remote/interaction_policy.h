#ifndef CODEX_REMOTE_INTERACTION_POLICY_H
#define CODEX_REMOTE_INTERACTION_POLICY_H

#include <stdbool.h>
#include <stdint.h>

#define CR_DETAIL_IDLE_TIMEOUT_MS UINT64_C(20000)

bool cr_detail_idle_timeout_reached(uint64_t now_ms, uint64_t last_interaction_ms);

#endif
