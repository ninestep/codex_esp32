#pragma once

#include <stdbool.h>
#include <stddef.h>

typedef struct {
    size_t primary_length;
    size_t scan_response_length;
    bool name_in_scan_response;
    bool fits_legacy_limits;
} cr_ble_advertising_layout_t;

cr_ble_advertising_layout_t cr_ble_advertising_layout(size_t name_length);
