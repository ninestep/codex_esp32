#ifndef CODEX_REMOTE_CRC32_H
#define CODEX_REMOTE_CRC32_H

#include <stddef.h>
#include <stdint.h>

uint32_t cr_crc32_ieee(const uint8_t *bytes, size_t length);

#endif
