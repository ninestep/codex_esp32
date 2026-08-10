#include "codex_remote/power_state.h"

#include <assert.h>
#include <stdio.h>

int main(void)
{
    cr_power_state_t state;
    cr_power_init(&state, 1000);

    assert(cr_power_update(&state, 60999, false, 3).mode == CR_POWER_NORMAL);
    assert(cr_power_update(&state, 61000, false, 3).mode == CR_POWER_DIM);
    assert(cr_power_update(&state, 121000, false, 3).mode == CR_POWER_SCREENSAVER);
    assert(cr_power_update(&state, 151000, false, 3).asset_index == 1);
    assert(cr_power_update(&state, 301000, false, 3).mode == CR_POWER_SCREENSAVER);

    cr_power_note_interaction(&state, 302000);
    assert(cr_power_update(&state, 302000, false, 3).mode == CR_POWER_NORMAL);

    assert(cr_power_update(&state, 422000, true, 3).mode == CR_POWER_NORMAL);
    assert(cr_power_update(&state, 482000, false, 3).mode == CR_POWER_DIM);

    cr_power_note_urgent(&state, 800000);
    assert(cr_power_update(&state, 807999, false, 3).mode == CR_POWER_NORMAL);
    assert(cr_power_update(&state, 808000, false, 3).mode == CR_POWER_SCREENSAVER);

    puts("test_power_state: PASS");
    return 0;
}
