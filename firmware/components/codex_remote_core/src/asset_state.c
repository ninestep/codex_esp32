#include "codex_remote/asset_state.h"

#include <string.h>

static bool storage_is_valid(const cr_asset_storage_t *storage)
{
    return storage != NULL && storage->begin_pending != NULL && storage->write != NULL
        && storage->read != NULL && storage->activate != NULL && storage->cancel != NULL;
}

static int descriptor_index(const cr_asset_state_t *state, uint16_t asset_id)
{
    for (size_t index = 0; index < state->pending_count; index++) {
        if (state->pending_items[index].asset_id == asset_id) return (int)index;
    }
    return -1;
}

static uint32_t crc_update(uint32_t checksum, const uint8_t *bytes, size_t length)
{
    for (size_t byte_index = 0; byte_index < length; byte_index++) {
        checksum ^= bytes[byte_index];
        for (uint8_t bit_index = 0; bit_index < 8; bit_index++) {
            uint32_t mask = (uint32_t)(-(int32_t)(checksum & UINT32_C(1)));
            checksum = (checksum >> 1) ^ (UINT32_C(0xedb88320) & mask);
        }
    }
    return checksum;
}

static bool asset_crc_matches(cr_asset_state_t *state, size_t index)
{
    const cr_asset_descriptor_t *item = &state->pending_items[index];
    uint8_t buffer[256];
    uint32_t checksum = UINT32_C(0xffffffff);
    uint32_t offset = 0;
    while (offset < item->byte_count) {
        size_t remaining = item->byte_count - offset;
        size_t length = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
        if (!state->storage.read(state->storage.context, item->asset_id, offset, buffer, length)) {
            return false;
        }
        checksum = crc_update(checksum, buffer, length);
        offset += (uint32_t)length;
    }
    return (checksum ^ UINT32_C(0xffffffff)) == item->crc32;
}

void cr_asset_state_init(cr_asset_state_t *state, const cr_asset_storage_t *storage)
{
    memset(state, 0, sizeof(*state));
    if (storage_is_valid(storage)) state->storage = *storage;
}

void cr_asset_cancel_pending(cr_asset_state_t *state)
{
    if (!state->pending) return;
    state->storage.cancel(state->storage.context, state->pending_set_id);
    state->pending = false;
    state->pending_count = 0;
    memset(state->received, 0, sizeof(state->received));
}

cr_asset_result_t cr_asset_begin(
    cr_asset_state_t *state,
    uint32_t set_id,
    uint32_t total_bytes,
    const cr_asset_descriptor_t *items,
    size_t count
)
{
    if (state == NULL || !storage_is_valid(&state->storage) || items == NULL
        || count == 0 || count > CR_MAX_ASSETS || total_bytes > CR_ASSET_MAX_SET_BYTES) {
        return CR_ASSET_REJECTED;
    }
    uint64_t described_total = 0;
    for (size_t index = 0; index < count; index++) {
        const cr_asset_descriptor_t *item = &items[index];
        if (item->asset_id == 0 || item->width == 0 || item->height == 0
            || item->width > CR_ASSET_MAX_DIMENSION || item->height > CR_ASSET_MAX_DIMENSION
            || item->byte_count == 0) {
            return CR_ASSET_REJECTED;
        }
        for (size_t previous = 0; previous < index; previous++) {
            if (items[previous].asset_id == item->asset_id) return CR_ASSET_REJECTED;
        }
        described_total += item->byte_count;
    }
    if (described_total != total_bytes) return CR_ASSET_REJECTED;

    cr_asset_cancel_pending(state);
    if (!state->storage.begin_pending(state->storage.context, set_id, total_bytes)) {
        return CR_ASSET_REJECTED;
    }
    state->pending = true;
    state->pending_set_id = set_id;
    state->pending_count = count;
    memcpy(state->pending_items, items, count * sizeof(*items));
    memset(state->received, 0, sizeof(state->received));
    return CR_ASSET_ACCEPTED;
}

cr_asset_result_t cr_asset_receive(
    cr_asset_state_t *state,
    uint32_t set_id,
    uint16_t asset_id,
    uint32_t offset,
    const uint8_t *bytes,
    size_t length,
    uint32_t *next_offset
)
{
    if (state == NULL || next_offset == NULL || !state->pending
        || set_id != state->pending_set_id || (bytes == NULL && length > 0)) {
        return CR_ASSET_REJECTED;
    }
    int found = descriptor_index(state, asset_id);
    if (found < 0) return CR_ASSET_REJECTED;
    size_t index = (size_t)found;
    uint32_t received = state->received[index];
    const cr_asset_descriptor_t *item = &state->pending_items[index];
    if (length > UINT32_MAX || offset > item->byte_count
        || (uint32_t)length > item->byte_count - offset) {
        return CR_ASSET_REJECTED;
    }

    if (offset < received) {
        if ((uint32_t)length > received - offset) return CR_ASSET_REJECTED;
        uint8_t existing[256];
        size_t compared = 0;
        while (compared < length) {
            size_t part = length - compared < sizeof(existing) ? length - compared : sizeof(existing);
            if (!state->storage.read(
                    state->storage.context,
                    asset_id,
                    offset + (uint32_t)compared,
                    existing,
                    part
                ) || memcmp(existing, bytes + compared, part) != 0) {
                return CR_ASSET_CONFLICT;
            }
            compared += part;
        }
        *next_offset = received;
        return CR_ASSET_ACCEPTED;
    }
    if (offset != received) return CR_ASSET_REJECTED;
    if (!state->storage.write(state->storage.context, asset_id, offset, bytes, length)) {
        return CR_ASSET_REJECTED;
    }
    state->received[index] += (uint32_t)length;
    *next_offset = state->received[index];

    for (size_t current = 0; current < state->pending_count; current++) {
        if (state->received[current] != state->pending_items[current].byte_count) {
            return CR_ASSET_ACCEPTED;
        }
    }
    for (size_t current = 0; current < state->pending_count; current++) {
        if (!asset_crc_matches(state, current)) {
            cr_asset_cancel_pending(state);
            return CR_ASSET_REJECTED;
        }
    }
    if (!state->storage.activate(
            state->storage.context,
            state->pending_set_id,
            state->pending_items,
            state->pending_count
        )) {
        cr_asset_cancel_pending(state);
        return CR_ASSET_REJECTED;
    }
    state->active_set_id = state->pending_set_id;
    state->active_count = state->pending_count;
    memcpy(state->active_items, state->pending_items, state->pending_count * sizeof(*state->pending_items));
    state->pending = false;
    state->pending_count = 0;
    return CR_ASSET_COMPLETE;
}
