#include "codex_remote/advertising_layout.h"

enum {
    LEGACY_PAYLOAD_LIMIT = 31,
    FLAGS_FIELD_LENGTH = 3,
    UUID128_FIELD_LENGTH = 18,
    FIELD_HEADER_LENGTH = 2,
};

cr_ble_advertising_layout_t cr_ble_advertising_layout(size_t name_length)
{
    const size_t primary_length = FLAGS_FIELD_LENGTH + UUID128_FIELD_LENGTH;
    const size_t scan_response_length = FIELD_HEADER_LENGTH + name_length;
    return (cr_ble_advertising_layout_t) {
        .primary_length = primary_length,
        .scan_response_length = scan_response_length,
        .name_in_scan_response = true,
        .fits_legacy_limits = primary_length <= LEGACY_PAYLOAD_LIMIT
            && scan_response_length <= LEGACY_PAYLOAD_LIMIT,
    };
}
