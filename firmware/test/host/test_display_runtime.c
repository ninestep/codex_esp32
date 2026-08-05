#include "display_runtime.h"

#include <assert.h>
#include <stddef.h>

int main(void)
{
    assert(CR_DISPLAY_WIDTH == 480);
    assert(CR_DISPLAY_BUFFER_HEIGHT == 10);
    assert(CR_DISPLAY_BUFFER_COUNT == 1);
    assert(CR_DISPLAY_BUFFER_BYTES == 9600);
    assert(CR_DISPLAY_TOTAL_BUFFER_BYTES == 9600);
    assert(CR_DISPLAY_BUFFER_IN_PSRAM == 0);
    return 0;
}
