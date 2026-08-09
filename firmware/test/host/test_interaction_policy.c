#include "codex_remote/interaction_policy.h"

#include <assert.h>
#include <stdio.h>

int main(void)
{
    assert(!cr_detail_idle_timeout_reached(19999, 0));
    assert(cr_detail_idle_timeout_reached(20000, 0));
    assert(cr_detail_idle_timeout_reached(35000, 10000));
    assert(!cr_detail_idle_timeout_reached(999, 1000));

    puts("interaction policy tests passed");
    return 0;
}
