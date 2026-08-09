#include "codex_micro/agent_status.h"

static uint32_t color_distance(uint32_t lhs, uint32_t rhs)
{
    int32_t red = (int32_t)((lhs >> 16) & 0xffU) - (int32_t)((rhs >> 16) & 0xffU);
    int32_t green = (int32_t)((lhs >> 8) & 0xffU) - (int32_t)((rhs >> 8) & 0xffU);
    int32_t blue = (int32_t)(lhs & 0xffU) - (int32_t)(rhs & 0xffU);
    return (uint32_t)(red * red + green * green + blue * blue);
}

cr_micro_agent_status_t cr_micro_agent_status(const cr_micro_light_t *light)
{
    static const uint32_t reference_colors[] = {
        UINT32_C(0xa1a1aa),
        UINT32_C(0x3b82f6),
        UINT32_C(0x22c55e),
        UINT32_C(0xf59e0b),
        UINT32_C(0xef4444),
    };
    if (light == NULL || !light->configured) return CR_MICRO_AGENT_OFFLINE;
    if (light->brightness == 0) return CR_MICRO_AGENT_IDLE;

    uint8_t nearest = 0;
    uint32_t distance = color_distance(light->color, reference_colors[0]);
    for (uint8_t index = 1; index < sizeof(reference_colors) / sizeof(reference_colors[0]); index++) {
        uint32_t candidate = color_distance(light->color, reference_colors[index]);
        if (candidate < distance) {
            nearest = index;
            distance = candidate;
        }
    }
    return (cr_micro_agent_status_t)nearest;
}
