#include "codex_remote/advertising_layout.h"

#include <assert.h>
#include <stdio.h>

int main(void)
{
    cr_ble_advertising_layout_t layout = cr_ble_advertising_layout(12);
    assert(layout.primary_length == 21);
    assert(layout.scan_response_length == 14);
    assert(layout.name_in_scan_response);
    assert(layout.fits_legacy_limits);

    assert(cr_ble_advertising_layout(29).fits_legacy_limits);
    assert(!cr_ble_advertising_layout(30).fits_legacy_limits);

    cr_ble_advertising_layout_t companion = cr_ble_hid_companion_advertising_layout(11);
    assert(companion.primary_length == 11);
    assert(companion.scan_response_length == 31);
    assert(companion.name_in_scan_response);
    assert(companion.fits_legacy_limits);
    assert(!cr_ble_hid_companion_advertising_layout(12).fits_legacy_limits);

    puts("test_ble_advertising: PASS");
    return 0;
}
