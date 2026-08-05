#include "codex_remote/asset_state.h"
#include "codex_remote/crc32.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    uint8_t data[2][32];
    size_t lengths[2];
    uint32_t activated_set;
    int activation_count;
    int cancel_count;
} fake_storage_t;

static int slot(uint16_t asset_id) { return asset_id == 10 ? 0 : asset_id == 11 ? 1 : -1; }

static bool begin_pending(void *context, uint32_t set_id, uint32_t total_bytes)
{
    fake_storage_t *storage = context;
    (void)set_id;
    (void)total_bytes;
    memset(storage->data, 0, sizeof(storage->data));
    memset(storage->lengths, 0, sizeof(storage->lengths));
    return true;
}

static bool write_bytes(void *context, uint16_t asset_id, uint32_t offset, const uint8_t *bytes, size_t length)
{
    fake_storage_t *storage = context;
    int index = slot(asset_id);
    if (index < 0 || offset + length > sizeof(storage->data[index])) return false;
    memcpy(storage->data[index] + offset, bytes, length);
    if (storage->lengths[index] < offset + length) storage->lengths[index] = offset + length;
    return true;
}

static bool read_bytes(void *context, uint16_t asset_id, uint32_t offset, uint8_t *bytes, size_t length)
{
    fake_storage_t *storage = context;
    int index = slot(asset_id);
    if (index < 0 || offset + length > storage->lengths[index]) return false;
    memcpy(bytes, storage->data[index] + offset, length);
    return true;
}

static bool activate(void *context, uint32_t set_id, const cr_asset_descriptor_t *items, size_t count)
{
    fake_storage_t *storage = context;
    (void)items;
    (void)count;
    storage->activated_set = set_id;
    storage->activation_count++;
    return true;
}

static void cancel(void *context, uint32_t set_id)
{
    fake_storage_t *storage = context;
    (void)set_id;
    storage->cancel_count++;
}

int main(void)
{
    static const uint8_t first[] = {1, 2, 3, 4};
    static const uint8_t second[] = {5, 6, 7};
    cr_asset_descriptor_t items[] = {
        {.asset_id = 10, .width = 480, .height = 480, .byte_count = sizeof(first), .crc32 = 0},
        {.asset_id = 11, .width = 320, .height = 240, .byte_count = sizeof(second), .crc32 = 0},
    };
    items[0].crc32 = cr_crc32_ieee(first, sizeof(first));
    items[1].crc32 = cr_crc32_ieee(second, sizeof(second));

    fake_storage_t memory = {0};
    cr_asset_storage_t storage = {
        .begin_pending = begin_pending,
        .write = write_bytes,
        .read = read_bytes,
        .activate = activate,
        .cancel = cancel,
        .context = &memory,
    };
    cr_asset_state_t state;
    cr_asset_state_init(&state, &storage);

    assert(cr_asset_begin(&state, 7, 7, items, 2) == CR_ASSET_ACCEPTED);
    uint32_t next = 0;
    assert(cr_asset_receive(&state, 7, 10, 0, first, 2, &next) == CR_ASSET_ACCEPTED);
    assert(next == 2);
    assert(cr_asset_receive(&state, 7, 10, 0, first, 2, &next) == CR_ASSET_ACCEPTED);
    uint8_t conflict[] = {9, 9};
    assert(cr_asset_receive(&state, 7, 10, 0, conflict, 2, &next) == CR_ASSET_CONFLICT);
    assert(cr_asset_receive(&state, 7, 10, 3, first, 1, &next) == CR_ASSET_REJECTED);
    assert(cr_asset_receive(&state, 7, 10, 2, first + 2, 2, &next) == CR_ASSET_ACCEPTED);
    assert(cr_asset_receive(&state, 7, 11, 0, second, sizeof(second), &next) == CR_ASSET_COMPLETE);
    assert(state.active_set_id == 7 && state.active_count == 2);
    assert(memory.activated_set == 7 && memory.activation_count == 1);

    assert(cr_asset_begin(&state, 8, 7, items, 2) == CR_ASSET_ACCEPTED);
    assert(state.active_set_id == 7);
    uint8_t bad_first[] = {1, 2, 3, 5};
    assert(cr_asset_receive(&state, 8, 10, 0, bad_first, sizeof(bad_first), &next) == CR_ASSET_ACCEPTED);
    assert(cr_asset_receive(&state, 8, 11, 0, second, sizeof(second), &next) == CR_ASSET_REJECTED);
    assert(state.active_set_id == 7 && memory.activation_count == 1 && memory.cancel_count == 1);

    cr_asset_descriptor_t invalid = items[0];
    invalid.width = 481;
    assert(cr_asset_begin(&state, 9, invalid.byte_count, &invalid, 1) == CR_ASSET_REJECTED);

    puts("test_asset_state: PASS");
    return 0;
}
