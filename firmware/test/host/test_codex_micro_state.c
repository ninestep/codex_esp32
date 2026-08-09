#include "codex_micro/micro_state.h"
#include "codex_micro/rpc_codec.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_initial_state_and_connection_changes(void)
{
    cr_micro_state_t state;
    cr_micro_state_init(&state);
    assert(!state.connected);
    assert(state.generation == 0);
    for (size_t index = 0; index < CR_MICRO_SLOT_COUNT; index++) {
        assert(!state.slots[index].configured);
    }

    assert(cr_micro_state_set_connected(&state, true));
    assert(state.connected);
    assert(state.generation == 1);
    assert(!cr_micro_state_set_connected(&state, true));
}

static void test_rgb_and_thread_status_requests_update_state(void)
{
    cr_micro_state_t state;
    cr_micro_state_init(&state);
    char response[512];
    size_t response_length = 0;
    bool state_changed = false;

    static const char rgb_request[] =
        "{\"method\":\"v.oai.rgbcfg\",\"params\":{\"ambient\":"
        "{\"e\":1,\"b\":0.5,\"s\":0.25,\"m\":0,\"c\":1122867},"
        "\"keys\":{\"e\":4,\"b\":1,\"s\":0,\"m\":2,\"c\":4478310}},\"id\":31}";
    assert(cr_micro_rpc_respond_with_state(
        rgb_request, sizeof(rgb_request) - 1, 88, true, &state, &state_changed,
        response, sizeof(response), &response_length
    ) == CR_MICRO_RPC_OK);
    assert(state_changed);
    assert(strcmp(response, "{\"id\":31,\"result\":true}") == 0);
    assert(state.ambient.configured);
    assert(state.ambient.color == UINT32_C(0x112233));
    assert(state.ambient.brightness == 128);
    assert(state.ambient.speed == 64);
    assert(state.keys.effect == 4);
    assert(state.keys.magic == 2);

    static const char threads_request[] =
        "{\"method\":\"v.oai.thstatus\",\"params\":["
        "{\"id\":0,\"c\":255,\"b\":1,\"e\":2,\"s\":0.5,\"sk\":1,\"sa\":0},"
        "{\"id\":5,\"c\":16711680,\"b\":0.75,\"e\":4,\"s\":1}],\"id\":32}";
    state_changed = false;
    assert(cr_micro_rpc_respond_with_state(
        threads_request, sizeof(threads_request) - 1, 88, true, &state, &state_changed,
        response, sizeof(response), &response_length
    ) == CR_MICRO_RPC_OK);
    assert(state_changed);
    assert(strcmp(response, "{\"id\":32,\"result\":true}") == 0);
    assert(state.slots[0].configured);
    assert(state.slots[0].color == 255);
    assert(state.slots[0].brightness == 255);
    assert(state.slots[0].speed == 128);
    assert(state.slots[0].sync_keys);
    assert(!state.slots[0].sync_ambient);
    assert(state.slots[5].configured);
    assert(state.slots[5].color == UINT32_C(0xff0000));
}

static void test_invalid_thread_status_does_not_mutate_state(void)
{
    cr_micro_state_t state;
    cr_micro_state_init(&state);
    cr_micro_state_t before = state;
    char response[256];
    size_t response_length = 0;
    bool state_changed = false;
    static const char invalid[] =
        "{\"method\":\"v.oai.thstatus\",\"params\":[{\"id\":6,\"c\":1}],\"id\":7}";
    assert(cr_micro_rpc_respond_with_state(
        invalid, sizeof(invalid) - 1, 0, false, &state, &state_changed,
        response, sizeof(response), &response_length
    ) == CR_MICRO_RPC_INVALID_REQUEST);
    assert(!state_changed);
    assert(memcmp(&state, &before, sizeof(state)) == 0);
}

static void test_all_native_control_events_are_encoded(void)
{
    char json[192];
    size_t length = 0;
    assert(cr_micro_rpc_encode_control_key(
        CR_MICRO_CONTROL_APPROVE, true, json, sizeof(json), &length
    ) == CR_MICRO_RPC_OK);
    assert(strstr(json, "\"k\":\"ACT07\"") != NULL);
    assert(strstr(json, "\"act\":1") != NULL);

    assert(cr_micro_rpc_encode_encoder(
        CR_MICRO_ENCODER_CLOCKWISE, json, sizeof(json), &length
    ) == CR_MICRO_RPC_OK);
    assert(strstr(json, "\"k\":\"ENC_CW\"") != NULL);
    assert(strstr(json, "\"act\":2") != NULL);

    assert(cr_micro_rpc_encode_encoder_press(
        true, json, sizeof(json), &length
    ) == CR_MICRO_RPC_OK);
    assert(strstr(json, "\"k\":\"ENC_PRESS\"") != NULL);
    assert(strstr(json, "\"act\":1") != NULL);
    assert(cr_micro_rpc_encode_encoder_press(
        false, json, sizeof(json), &length
    ) == CR_MICRO_RPC_OK);
    assert(strstr(json, "\"k\":\"ENC_PRESS\"") != NULL);
    assert(strstr(json, "\"act\":0") != NULL);

    static const char *const angles[] = {
        "\"a\":0.75", "\"a\":0", "\"a\":0.25", "\"a\":0.5",
    };
    for (int direction = CR_MICRO_DIRECTION_UP;
         direction <= CR_MICRO_DIRECTION_LEFT; direction++) {
        assert(cr_micro_rpc_encode_direction(
            (cr_micro_direction_t)direction, true,
            json, sizeof(json), &length
        ) == CR_MICRO_RPC_OK);
        assert(strstr(json, "\"method\":\"v.oai.rad\"") != NULL);
        assert(strstr(json, angles[direction]) != NULL);
        assert(strstr(json, "\"d\":1") != NULL);
        assert(cr_micro_rpc_encode_direction(
            (cr_micro_direction_t)direction, false,
            json, sizeof(json), &length
        ) == CR_MICRO_RPC_OK);
        assert(strstr(json, angles[direction]) != NULL);
        assert(strstr(json, "\"d\":0") != NULL);
    }
}

int main(void)
{
    test_initial_state_and_connection_changes();
    test_rgb_and_thread_status_requests_update_state();
    test_invalid_thread_status_does_not_mutate_state();
    test_all_native_control_events_are_encoded();
    puts("test_codex_micro_state: PASS");
    return 0;
}
