#include "codex_remote/fragment.h"

#include <string.h>

static uint16_t read_u16_le(const uint8_t *bytes)
{
    return (uint16_t)((uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8));
}

static uint32_t read_u32_le(const uint8_t *bytes)
{
    return (uint32_t)bytes[0]
        | ((uint32_t)bytes[1] << 8)
        | ((uint32_t)bytes[2] << 16)
        | ((uint32_t)bytes[3] << 24);
}

void cr_fragment_reassembler_init(
    cr_fragment_reassembler_t *reassembler,
    uint8_t *storage,
    size_t storage_capacity
)
{
    *reassembler = (cr_fragment_reassembler_t){
        .storage = storage,
        .storage_capacity = storage_capacity,
    };
}

void cr_fragment_reassembler_reset(cr_fragment_reassembler_t *reassembler)
{
    reassembler->accumulated_length = 0;
    reassembler->message_id = 0;
    reassembler->fragment_count = 0;
    reassembler->next_index = 0;
    reassembler->active = false;
}

static cr_fragment_result_t fail(
    cr_fragment_reassembler_t *reassembler,
    cr_fragment_result_t result
)
{
    cr_fragment_reassembler_reset(reassembler);
    return result;
}

cr_fragment_result_t cr_fragment_reassembler_accept(
    cr_fragment_reassembler_t *reassembler,
    const uint8_t *packet,
    size_t packet_length,
    cr_byte_view_t *complete
)
{
    if (reassembler == NULL || packet == NULL || complete == NULL
        || reassembler->storage == NULL || packet_length < CR_FRAGMENT_HEADER_BYTES) {
        return reassembler == NULL ? CR_FRAGMENT_ERROR_MALFORMED
                                   : fail(reassembler, CR_FRAGMENT_ERROR_MALFORMED);
    }

    uint32_t message_id = read_u32_le(packet);
    uint16_t index = read_u16_le(packet + 4);
    uint16_t count = read_u16_le(packet + 6);
    if (count == 0 || count > CR_MAX_FRAGMENTS || index >= count) {
        return fail(reassembler, CR_FRAGMENT_ERROR_COUNT);
    }
    if (reassembler->active && reassembler->message_id != message_id) {
        return fail(reassembler, CR_FRAGMENT_ERROR_MESSAGE_ID);
    }
    if (reassembler->active && reassembler->fragment_count != count) {
        return fail(reassembler, CR_FRAGMENT_ERROR_COUNT);
    }
    if (index != reassembler->next_index) {
        return fail(reassembler, CR_FRAGMENT_ERROR_SEQUENCE);
    }

    size_t payload_length = packet_length - CR_FRAGMENT_HEADER_BYTES;
    if (payload_length > reassembler->storage_capacity - reassembler->accumulated_length
        || reassembler->accumulated_length + payload_length > CR_MAX_ENVELOPE_BYTES) {
        return fail(reassembler, CR_FRAGMENT_ERROR_TOO_LARGE);
    }
    if (!reassembler->active) {
        reassembler->active = true;
        reassembler->message_id = message_id;
        reassembler->fragment_count = count;
    }

    memcpy(
        reassembler->storage + reassembler->accumulated_length,
        packet + CR_FRAGMENT_HEADER_BYTES,
        payload_length
    );
    reassembler->accumulated_length += payload_length;
    reassembler->next_index++;

    if (reassembler->next_index == count) {
        *complete = (cr_byte_view_t){
            .bytes = reassembler->storage,
            .length = reassembler->accumulated_length,
        };
        cr_fragment_reassembler_reset(reassembler);
        return CR_FRAGMENT_COMPLETE;
    }
    *complete = (cr_byte_view_t){0};
    return CR_FRAGMENT_WAITING;
}
