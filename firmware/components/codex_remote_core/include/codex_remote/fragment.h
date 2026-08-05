#ifndef CODEX_REMOTE_FRAGMENT_H
#define CODEX_REMOTE_FRAGMENT_H

#include "codex_remote/message.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CR_FRAGMENT_HEADER_BYTES ((size_t)8)
#define CR_MAX_FRAGMENTS UINT16_C(1024)

typedef enum {
    CR_FRAGMENT_WAITING = 0,
    CR_FRAGMENT_COMPLETE = 1,
    CR_FRAGMENT_ERROR_MALFORMED = -1,
    CR_FRAGMENT_ERROR_SEQUENCE = -2,
    CR_FRAGMENT_ERROR_MESSAGE_ID = -3,
    CR_FRAGMENT_ERROR_COUNT = -4,
    CR_FRAGMENT_ERROR_TOO_LARGE = -5,
} cr_fragment_result_t;

typedef struct {
    uint8_t *storage;
    size_t storage_capacity;
    size_t accumulated_length;
    uint32_t message_id;
    uint16_t fragment_count;
    uint16_t next_index;
    bool active;
} cr_fragment_reassembler_t;

void cr_fragment_reassembler_init(
    cr_fragment_reassembler_t *reassembler,
    uint8_t *storage,
    size_t storage_capacity
);
void cr_fragment_reassembler_reset(cr_fragment_reassembler_t *reassembler);
cr_fragment_result_t cr_fragment_reassembler_accept(
    cr_fragment_reassembler_t *reassembler,
    const uint8_t *packet,
    size_t packet_length,
    cr_byte_view_t *complete
);

#endif
