#include "codex_micro/agent_status.h"

#include <assert.h>
#include <stdio.h>

static cr_micro_light_t light(uint32_t color, uint8_t brightness)
{
    return (cr_micro_light_t){
        .configured = true,
        .color = color,
        .brightness = brightness,
    };
}

int main(void)
{
    cr_micro_light_t offline = {0};
    cr_micro_light_t idle = light(UINT32_C(0x3b82f6), 0);
    cr_micro_light_t idle_dark = light(UINT32_C(0x000000), 0);
    cr_micro_light_t working = light(UINT32_C(0x3b82f6), 100);
    cr_micro_light_t completed = light(UINT32_C(0x22c55e), 100);
    cr_micro_light_t requires_input = light(UINT32_C(0xf59e0b), 100);
    cr_micro_light_t error = light(UINT32_C(0xef4444), 100);

    assert(cr_micro_agent_status(NULL) == CR_MICRO_AGENT_OFFLINE);
    assert(cr_micro_agent_status(&offline) == CR_MICRO_AGENT_OFFLINE);
    assert(cr_micro_agent_status(&idle) == CR_MICRO_AGENT_IDLE);
    assert(cr_micro_agent_status(&idle_dark) == CR_MICRO_AGENT_IDLE);
    assert(cr_micro_agent_status(&working) == CR_MICRO_AGENT_WORKING);
    assert(cr_micro_agent_status(&completed) == CR_MICRO_AGENT_COMPLETED);
    assert(cr_micro_agent_status(&requires_input) == CR_MICRO_AGENT_REQUIRES_INPUT);
    assert(cr_micro_agent_status(&error) == CR_MICRO_AGENT_ERROR);

    puts("codex micro agent status tests passed");
    return 0;
}
