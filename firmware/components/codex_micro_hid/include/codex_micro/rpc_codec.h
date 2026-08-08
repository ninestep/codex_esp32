#ifndef CODEX_MICRO_RPC_CODEC_H
#define CODEX_MICRO_RPC_CODEC_H

#include "codex_micro/micro_state.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CR_MICRO_FIRMWARE_VERSION "0.2.0-codex-remote"

typedef enum {
    CR_MICRO_RPC_OK = 0,
    CR_MICRO_RPC_METHOD_NOT_FOUND,
    CR_MICRO_RPC_INVALID_JSON,
    CR_MICRO_RPC_INVALID_REQUEST,
    CR_MICRO_RPC_OUTPUT_TOO_SMALL,
} cr_micro_rpc_result_t;

typedef enum {
    CR_MICRO_CONTROL_FAST = 0,
    CR_MICRO_CONTROL_APPROVE,
    CR_MICRO_CONTROL_DECLINE,
    CR_MICRO_CONTROL_CONTINUE,
    CR_MICRO_CONTROL_PTT,
    CR_MICRO_CONTROL_SEND,
} cr_micro_control_t;

typedef enum {
    CR_MICRO_ENCODER_PRESS = 0,
    CR_MICRO_ENCODER_CLOCKWISE,
    CR_MICRO_ENCODER_COUNTERCLOCKWISE,
} cr_micro_encoder_action_t;

typedef enum {
    CR_MICRO_DIRECTION_UP = 0,
    CR_MICRO_DIRECTION_RIGHT,
    CR_MICRO_DIRECTION_DOWN,
    CR_MICRO_DIRECTION_LEFT,
} cr_micro_direction_t;

cr_micro_rpc_result_t cr_micro_rpc_respond(
    const char *json,
    size_t json_length,
    uint8_t battery_percent,
    bool charging,
    char *response,
    size_t response_capacity,
    size_t *response_length
);
cr_micro_rpc_result_t cr_micro_rpc_respond_with_state(
    const char *json,
    size_t json_length,
    uint8_t battery_percent,
    bool charging,
    cr_micro_state_t *state,
    bool *state_changed,
    char *response,
    size_t response_capacity,
    size_t *response_length
);
cr_micro_rpc_result_t cr_micro_rpc_encode_agent_key(
    uint8_t agent_index,
    bool pressed,
    char *json,
    size_t capacity,
    size_t *length
);
cr_micro_rpc_result_t cr_micro_rpc_encode_control_key(
    cr_micro_control_t control,
    bool pressed,
    char *json,
    size_t capacity,
    size_t *length
);
cr_micro_rpc_result_t cr_micro_rpc_encode_encoder(
    cr_micro_encoder_action_t action,
    char *json,
    size_t capacity,
    size_t *length
);
cr_micro_rpc_result_t cr_micro_rpc_encode_direction(
    cr_micro_direction_t direction,
    bool pressed,
    char *json,
    size_t capacity,
    size_t *length
);

#endif
