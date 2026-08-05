#ifndef CODEX_REMOTE_ASSET_STATE_H
#define CODEX_REMOTE_ASSET_STATE_H

#include "codex_remote/message.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CR_ASSET_MAX_SET_BYTES UINT32_C(4194304)
#define CR_ASSET_MAX_DIMENSION UINT16_C(480)

typedef enum {
    CR_ASSET_ACCEPTED = 0,
    CR_ASSET_COMPLETE,
    CR_ASSET_REJECTED,
    CR_ASSET_CONFLICT,
} cr_asset_result_t;

typedef struct {
    bool (*begin_pending)(void *context, uint32_t set_id, uint32_t total_bytes);
    bool (*write)(void *context, uint16_t asset_id, uint32_t offset, const uint8_t *bytes, size_t length);
    bool (*read)(void *context, uint16_t asset_id, uint32_t offset, uint8_t *bytes, size_t length);
    bool (*activate)(
        void *context,
        uint32_t set_id,
        const cr_asset_descriptor_t *items,
        size_t count
    );
    void (*cancel)(void *context, uint32_t set_id);
    void *context;
} cr_asset_storage_t;

typedef struct {
    cr_asset_storage_t storage;
    uint32_t active_set_id;
    size_t active_count;
    cr_asset_descriptor_t active_items[CR_MAX_ASSETS];
    bool pending;
    uint32_t pending_set_id;
    size_t pending_count;
    cr_asset_descriptor_t pending_items[CR_MAX_ASSETS];
    uint32_t received[CR_MAX_ASSETS];
} cr_asset_state_t;

void cr_asset_state_init(cr_asset_state_t *state, const cr_asset_storage_t *storage);
cr_asset_result_t cr_asset_begin(
    cr_asset_state_t *state,
    uint32_t set_id,
    uint32_t total_bytes,
    const cr_asset_descriptor_t *items,
    size_t count
);
cr_asset_result_t cr_asset_receive(
    cr_asset_state_t *state,
    uint32_t set_id,
    uint16_t asset_id,
    uint32_t offset,
    const uint8_t *bytes,
    size_t length,
    uint32_t *next_offset
);
void cr_asset_cancel_pending(cr_asset_state_t *state);

#endif
