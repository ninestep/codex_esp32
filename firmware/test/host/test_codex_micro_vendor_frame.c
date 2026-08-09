#include "codex_micro/rpc_codec.h"
#include "codex_micro/vendor_frame.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_report_body_is_fixed_63_bytes(void)
{
    static const uint8_t expected_report_map[CR_MICRO_HID_REPORT_MAP_BYTES] = {
        0x06, 0x00, 0xff, 0x09, 0x01, 0xa1, 0x01, 0x85, 0x06,
        0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x3f,
        0x09, 0x01, 0x81, 0x02, 0x95, 0x3f, 0x09, 0x02, 0x91,
        0x02, 0xc0,
        0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x07, 0x05,
        0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75,
        0x08, 0x81, 0x01, 0x95, 0x06, 0x75, 0x08, 0x15, 0x00,
        0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81,
        0x00, 0xc0,
    };
    assert(sizeof(expected_report_map) == sizeof(cr_micro_hid_report_map));
    assert(memcmp(expected_report_map, cr_micro_hid_report_map, sizeof(expected_report_map)) == 0);

    uint8_t report[CR_MICRO_REPORT_BODY_BYTES];
    const uint8_t payload[] = "abc";
    assert(cr_micro_vendor_frame_encode(payload, sizeof(payload) - 1, report) == CR_MICRO_FRAME_OK);
    assert(report[0] == CR_MICRO_MESSAGE_TYPE_JSON);
    assert(report[1] == 3);
    assert(memcmp(report + 2, payload, 3) == 0);
    for (size_t index = 5; index < sizeof(report); index++) assert(report[index] == 0);
    assert(cr_micro_vendor_frame_encode(payload, CR_MICRO_PAYLOAD_BYTES + 1, report)
        == CR_MICRO_FRAME_INVALID_LENGTH);
}

static void test_keyboard_actions_encode_exact_reports(void)
{
    cr_micro_keyboard_sequence_t sequence;
    assert(cr_micro_keyboard_action_encode(
        CR_MICRO_KEYBOARD_DELETE, &sequence
    ) == CR_MICRO_FRAME_OK);
    assert(sequence.count == 2);
    assert(sequence.reports[0][0] == 0);
    assert(sequence.reports[0][2] == 0x2a);
    for (size_t index = 0; index < CR_MICRO_KEYBOARD_REPORT_BYTES; index++) {
        assert(sequence.reports[1][index] == 0);
    }

    assert(cr_micro_keyboard_action_encode(
        CR_MICRO_KEYBOARD_CLEAR, &sequence
    ) == CR_MICRO_FRAME_OK);
    assert(sequence.count == 4);
    assert(sequence.reports[0][0] == 0x08);
    assert(sequence.reports[0][2] == 0x04);
    assert(sequence.reports[1][0] == 0 && sequence.reports[1][2] == 0);
    assert(sequence.reports[2][0] == 0 && sequence.reports[2][2] == 0x2a);
    assert(sequence.reports[3][0] == 0 && sequence.reports[3][2] == 0);

    assert(cr_micro_keyboard_action_encode(
        CR_MICRO_KEYBOARD_ENTER, &sequence
    ) == CR_MICRO_FRAME_OK);
    assert(sequence.count == 2);
    assert(sequence.reports[0][0] == 0 && sequence.reports[0][2] == 0x28);
    assert(sequence.reports[1][0] == 0 && sequence.reports[1][2] == 0);

    assert(cr_micro_keyboard_action_encode(
        CR_MICRO_KEYBOARD_ESCAPE, &sequence
    ) == CR_MICRO_FRAME_OK);
    assert(sequence.count == 2);
    assert(sequence.reports[0][0] == 0 && sequence.reports[0][2] == 0x29);
    assert(sequence.reports[1][0] == 0 && sequence.reports[1][2] == 0);

    assert(cr_micro_keyboard_action_encode(
        (cr_micro_keyboard_action_t)99, &sequence
    ) == CR_MICRO_FRAME_INVALID_ARGUMENT);
    assert(cr_micro_keyboard_action_encode(CR_MICRO_KEYBOARD_DELETE, NULL)
        == CR_MICRO_FRAME_INVALID_ARGUMENT);
}

static void test_reassembles_fragments_and_requires_newline(void)
{
    static const char request[] =
        "{\"method\":\"device.status\",\"params\":{\"padding\":\"123456789012345678901234567890\"},\"id\":7}";
    cr_micro_reassembler_t state;
    cr_micro_reassembler_init(&state);

    size_t offset = 0;
    uint8_t report[CR_MICRO_REPORT_BODY_BYTES];
    bool done = false;
    assert(cr_micro_vendor_frame_encode_json_chunk(
        request, sizeof(request) - 1, &offset, report, &done
    ) == CR_MICRO_FRAME_OK);
    assert(!done);
    assert(cr_micro_reassembler_push(&state, report, sizeof(report)) == CR_MICRO_FRAME_NEED_MORE);

    while (!done) {
        assert(cr_micro_vendor_frame_encode_json_chunk(
            request, sizeof(request) - 1, &offset, report, &done
        ) == CR_MICRO_FRAME_OK);
        cr_micro_frame_result_t result = cr_micro_reassembler_push(&state, report, sizeof(report));
        assert(result == (done ? CR_MICRO_FRAME_MESSAGE_READY : CR_MICRO_FRAME_NEED_MORE));
    }
    assert(state.length == sizeof(request) - 1);
    assert(memcmp(state.message, request, state.length) == 0);
}

static void test_reassembles_structurally_complete_json_without_newline(void)
{
    static const char request[] = "{\"method\":\"v.oai.rgbcfg\",\"params\":{},\"id\":41}";
    cr_micro_reassembler_t state;
    cr_micro_reassembler_init(&state);

    uint8_t report[CR_MICRO_REPORT_BODY_BYTES];
    assert(cr_micro_vendor_frame_encode(
        (const uint8_t *)request, sizeof(request) - 1, report
    ) == CR_MICRO_FRAME_OK);
    assert(cr_micro_reassembler_push(&state, report, sizeof(report))
        == CR_MICRO_FRAME_MESSAGE_READY);
    assert(state.length == sizeof(request) - 1);
    assert(strcmp(state.message, request) == 0);
}

static void test_accepts_explicit_report_id_and_rejects_bad_reports(void)
{
    cr_micro_reassembler_t state;
    cr_micro_reassembler_init(&state);
    uint8_t raw[CR_MICRO_REPORT_BODY_BYTES + 1] = {0};
    raw[0] = CR_MICRO_REPORT_ID;
    raw[1] = CR_MICRO_MESSAGE_TYPE_JSON;
    raw[2] = 2;
    raw[3] = '{';
    raw[4] = '\n';
    assert(cr_micro_reassembler_push(&state, raw, sizeof(raw)) == CR_MICRO_FRAME_MESSAGE_READY);

    cr_micro_reassembler_init(&state);
    raw[0] = 5;
    assert(cr_micro_reassembler_push(&state, raw, sizeof(raw)) == CR_MICRO_FRAME_INVALID_REPORT);
    raw[0] = CR_MICRO_REPORT_ID;
    raw[1] = 1;
    assert(cr_micro_reassembler_push(&state, raw, sizeof(raw)) == CR_MICRO_FRAME_INVALID_REPORT);
    raw[1] = CR_MICRO_MESSAGE_TYPE_JSON;
    raw[2] = CR_MICRO_PAYLOAD_BYTES + 1;
    assert(cr_micro_reassembler_push(&state, raw, sizeof(raw)) == CR_MICRO_FRAME_INVALID_LENGTH);
}

static void test_empty_missing_newline_invalid_utf8_and_overflow(void)
{
    cr_micro_reassembler_t state;
    uint8_t report[CR_MICRO_REPORT_BODY_BYTES] = {CR_MICRO_MESSAGE_TYPE_JSON, 0};
    cr_micro_reassembler_init(&state);
    assert(cr_micro_reassembler_push(&state, report, sizeof(report)) == CR_MICRO_FRAME_NEED_MORE);

    report[1] = 1;
    report[2] = '{';
    for (size_t index = 0; index < CR_MICRO_MAX_MESSAGE_BYTES; index++) {
        assert(cr_micro_reassembler_push(&state, report, sizeof(report)) == CR_MICRO_FRAME_NEED_MORE);
    }
    assert(cr_micro_reassembler_push(&state, report, sizeof(report)) == CR_MICRO_FRAME_TOO_LARGE);

    cr_micro_reassembler_init(&state);
    report[1] = 3;
    report[2] = 0xe2;
    report[3] = 0x28;
    report[4] = '\n';
    assert(cr_micro_reassembler_push(&state, report, sizeof(report)) == CR_MICRO_FRAME_INVALID_UTF8);
}

static void test_rpc_whitelist_and_responses(void)
{
    char response[512];
    size_t response_length = 0;
    const char version_request[] = "{\"method\":\"sys.version\",\"id\":12}";
    assert(cr_micro_rpc_respond(
        version_request, sizeof(version_request) - 1, 93, false,
        response, sizeof(response), &response_length
    ) == CR_MICRO_RPC_OK);
    assert(response_length == strlen(response));
    assert(strstr(response, "\"id\":12") != NULL);
    assert(strstr(response, "\"version\":") != NULL);

    const char status_request[] = "{\"method\":\"device.status\",\"id\":\"abc\"}";
    assert(cr_micro_rpc_respond(
        status_request, sizeof(status_request) - 1, 93, true,
        response, sizeof(response), &response_length
    ) == CR_MICRO_RPC_OK);
    assert(strstr(response, "\"id\":\"abc\"") != NULL);
    assert(strstr(response, "\"battery\":93") != NULL);
    assert(strstr(response, "\"is_charging\":true") != NULL);

    const char unknown[] = "{\"method\":\"system.erase\",\"id\":99}";
    assert(cr_micro_rpc_respond(
        unknown, sizeof(unknown) - 1, 0, false,
        response, sizeof(response), &response_length
    ) == CR_MICRO_RPC_METHOD_NOT_FOUND);
    assert(strstr(response, "\"code\":-32601") != NULL);

    const char malformed[] = "{\"method\":";
    assert(cr_micro_rpc_respond(
        malformed, sizeof(malformed) - 1, 0, false,
        response, sizeof(response), &response_length
    ) == CR_MICRO_RPC_INVALID_JSON);
    const char missing_id[] = "{\"method\":\"sys.version\"}";
    assert(cr_micro_rpc_respond(
        missing_id, sizeof(missing_id) - 1, 0, false,
        response, sizeof(response), &response_length
    ) == CR_MICRO_RPC_INVALID_REQUEST);

    assert(cr_micro_rpc_encode_agent_key(
        0, true, response, sizeof(response), &response_length
    ) == CR_MICRO_RPC_OK);
    assert(strstr(response, "\"method\":\"v.oai.hid\"") != NULL);
    assert(strstr(response, "\"k\":\"AG00\"") != NULL);
    assert(strstr(response, "\"act\":1") != NULL);
    assert(cr_micro_rpc_encode_agent_key(
        6, false, response, sizeof(response), &response_length
    ) == CR_MICRO_RPC_INVALID_REQUEST);
}

static void test_control_keys_encode_press_and_release(void)
{
    static const char *const keys[] = {
        "ACT06", "ACT07", "ACT08", "ACT09", "ACT10", "ACT12",
    };
    char json[160];
    size_t length = 0;
    for (size_t index = 0; index < sizeof(keys) / sizeof(keys[0]); index++) {
        assert(cr_micro_rpc_encode_control_key(
            (cr_micro_control_t)index, true, json, sizeof(json), &length
        ) == CR_MICRO_RPC_OK);
        assert(strstr(json, "\"method\":\"v.oai.hid\"") != NULL);
        assert(strstr(json, keys[index]) != NULL);
        assert(strstr(json, "\"act\":1") != NULL);

        assert(cr_micro_rpc_encode_control_key(
            (cr_micro_control_t)index, false, json, sizeof(json), &length
        ) == CR_MICRO_RPC_OK);
        assert(strstr(json, keys[index]) != NULL);
        assert(strstr(json, "\"act\":0") != NULL);
    }
    assert(cr_micro_rpc_encode_control_key(
        (cr_micro_control_t)6, true, json, sizeof(json), &length
    ) == CR_MICRO_RPC_INVALID_REQUEST);
}

int main(void)
{
    test_report_body_is_fixed_63_bytes();
    test_keyboard_actions_encode_exact_reports();
    test_reassembles_fragments_and_requires_newline();
    test_reassembles_structurally_complete_json_without_newline();
    test_accepts_explicit_report_id_and_rejects_bad_reports();
    test_empty_missing_newline_invalid_utf8_and_overflow();
    test_rpc_whitelist_and_responses();
    test_control_keys_encode_press_and_release();
    puts("test_codex_micro_vendor_frame: PASS");
    return 0;
}
