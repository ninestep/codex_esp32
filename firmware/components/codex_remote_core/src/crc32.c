#include "codex_remote/crc32.h"

uint32_t cr_crc32_ieee(const uint8_t *bytes, size_t length)
{
    uint32_t checksum = UINT32_C(0xffffffff);

    for (size_t byte_index = 0; byte_index < length; byte_index++) {
        checksum ^= bytes[byte_index];
        for (uint8_t bit_index = 0; bit_index < 8; bit_index++) {
            uint32_t mask = (uint32_t)(-(int32_t)(checksum & UINT32_C(1)));
            checksum = (checksum >> 1) ^ (UINT32_C(0xedb88320) & mask);
        }
    }

    return checksum ^ UINT32_C(0xffffffff);
}
