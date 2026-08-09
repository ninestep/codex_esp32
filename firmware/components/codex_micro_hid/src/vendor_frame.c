#include "codex_micro/vendor_frame.h"

#include <string.h>

const uint8_t cr_micro_hid_report_map[CR_MICRO_HID_REPORT_MAP_BYTES] = {
    0x06, 0x00, 0xff,
    0x09, 0x01,
    0xa1, 0x01,
    0x85, CR_MICRO_REPORT_ID,
    0x15, 0x00,
    0x26, 0xff, 0x00,
    0x75, 0x08,
    0x95, 0x3f,
    0x09, 0x01,
    0x81, 0x02,
    0x95, 0x3f,
    0x09, 0x02,
    0x91, 0x02,
    0xc0,
    0x05, 0x01,
    0x09, 0x06,
    0xa1, 0x01,
    0x85, CR_MICRO_KEYBOARD_REPORT_ID,
    0x05, 0x07,
    0x19, 0xe0,
    0x29, 0xe7,
    0x15, 0x00,
    0x25, 0x01,
    0x75, 0x01,
    0x95, 0x08,
    0x81, 0x02,
    0x95, 0x01,
    0x75, 0x08,
    0x81, 0x01,
    0x95, 0x06,
    0x75, 0x08,
    0x15, 0x00,
    0x25, 0x65,
    0x05, 0x07,
    0x19, 0x00,
    0x29, 0x65,
    0x81, 0x00,
    0xc0,
};

#define CR_HID_MODIFIER_LEFT_GUI UINT8_C(0x08)
#define CR_HID_KEY_A UINT8_C(0x04)
#define CR_HID_KEY_BACKSPACE UINT8_C(0x2a)

cr_micro_frame_result_t cr_micro_keyboard_action_encode(
    cr_micro_keyboard_action_t action,
    cr_micro_keyboard_sequence_t *sequence
)
{
    if (sequence == NULL) return CR_MICRO_FRAME_INVALID_ARGUMENT;
    memset(sequence, 0, sizeof(*sequence));
    switch (action) {
    case CR_MICRO_KEYBOARD_DELETE:
        sequence->reports[0][2] = CR_HID_KEY_BACKSPACE;
        sequence->count = 2;
        return CR_MICRO_FRAME_OK;
    case CR_MICRO_KEYBOARD_CLEAR:
        sequence->reports[0][0] = CR_HID_MODIFIER_LEFT_GUI;
        sequence->reports[0][2] = CR_HID_KEY_A;
        sequence->reports[2][2] = CR_HID_KEY_BACKSPACE;
        sequence->count = 4;
        return CR_MICRO_FRAME_OK;
    default:
        return CR_MICRO_FRAME_INVALID_ARGUMENT;
    }
}

static void reset_reassembler(cr_micro_reassembler_t *state)
{
    state->length = 0;
    state->message[0] = '\0';
}

static bool is_continuation(uint8_t byte)
{
    return (byte & UINT8_C(0xc0)) == UINT8_C(0x80);
}

static bool is_valid_utf8(const uint8_t *bytes, size_t length)
{
    size_t index = 0;
    while (index < length) {
        uint8_t first = bytes[index++];
        if (first <= UINT8_C(0x7f)) continue;
        if (first >= UINT8_C(0xc2) && first <= UINT8_C(0xdf)) {
            if (index >= length || !is_continuation(bytes[index])) return false;
            index++;
            continue;
        }
        if (first >= UINT8_C(0xe0) && first <= UINT8_C(0xef)) {
            if (index + 1 >= length) return false;
            uint8_t second = bytes[index];
            if (!is_continuation(second) || !is_continuation(bytes[index + 1])) return false;
            if (first == UINT8_C(0xe0) && second < UINT8_C(0xa0)) return false;
            if (first == UINT8_C(0xed) && second >= UINT8_C(0xa0)) return false;
            index += 2;
            continue;
        }
        if (first >= UINT8_C(0xf0) && first <= UINT8_C(0xf4)) {
            if (index + 2 >= length) return false;
            uint8_t second = bytes[index];
            if (!is_continuation(second)
                || !is_continuation(bytes[index + 1])
                || !is_continuation(bytes[index + 2])) return false;
            if (first == UINT8_C(0xf0) && second < UINT8_C(0x90)) return false;
            if (first == UINT8_C(0xf4) && second >= UINT8_C(0x90)) return false;
            index += 3;
            continue;
        }
        return false;
    }
    return true;
}

static bool has_complete_json_structure(const char *message, size_t length)
{
    size_t index = 0;
    while (index < length && (message[index] == ' ' || message[index] == '\t'
        || message[index] == '\r' || message[index] == '\n')) index++;
    if (index == length || (message[index] != '{' && message[index] != '[')) return false;

    int depth = 0;
    bool in_string = false;
    bool escaped = false;
    bool complete = false;
    for (; index < length; index++) {
        char byte = message[index];
        if (in_string) {
            if (escaped) escaped = false;
            else if (byte == '\\') escaped = true;
            else if (byte == '"') in_string = false;
            continue;
        }
        if (byte == '"') {
            in_string = true;
        } else if (byte == '{' || byte == '[') {
            if (complete) return false;
            depth++;
        } else if (byte == '}' || byte == ']') {
            if (depth <= 0) return false;
            depth--;
            if (depth == 0) complete = true;
        } else if (complete && byte != ' ' && byte != '\t' && byte != '\r'
            && byte != '\n') {
            return false;
        }
    }
    return complete && depth == 0 && !in_string && !escaped;
}

void cr_micro_reassembler_init(cr_micro_reassembler_t *state)
{
    if (state != NULL) reset_reassembler(state);
}

cr_micro_frame_result_t cr_micro_vendor_frame_encode(
    const uint8_t *payload,
    size_t payload_length,
    uint8_t report[CR_MICRO_REPORT_BODY_BYTES]
)
{
    if (report == NULL || (payload == NULL && payload_length > 0)) {
        return CR_MICRO_FRAME_INVALID_ARGUMENT;
    }
    if (payload_length > CR_MICRO_PAYLOAD_BYTES) return CR_MICRO_FRAME_INVALID_LENGTH;
    memset(report, 0, CR_MICRO_REPORT_BODY_BYTES);
    report[0] = CR_MICRO_MESSAGE_TYPE_JSON;
    report[1] = (uint8_t)payload_length;
    if (payload_length > 0) memcpy(report + 2, payload, payload_length);
    return CR_MICRO_FRAME_OK;
}

cr_micro_frame_result_t cr_micro_vendor_frame_encode_json_chunk(
    const char *json,
    size_t json_length,
    size_t *offset,
    uint8_t report[CR_MICRO_REPORT_BODY_BYTES],
    bool *done
)
{
    if (json == NULL || offset == NULL || report == NULL || done == NULL) {
        return CR_MICRO_FRAME_INVALID_ARGUMENT;
    }
    if (json_length > CR_MICRO_MAX_MESSAGE_BYTES || *offset > json_length) {
        return CR_MICRO_FRAME_INVALID_LENGTH;
    }

    size_t total_length = json_length + 1;
    size_t remaining = total_length - *offset;
    size_t chunk_length = remaining < CR_MICRO_PAYLOAD_BYTES
        ? remaining : CR_MICRO_PAYLOAD_BYTES;
    uint8_t payload[CR_MICRO_PAYLOAD_BYTES];
    for (size_t index = 0; index < chunk_length; index++) {
        size_t source_index = *offset + index;
        payload[index] = source_index < json_length ? (uint8_t)json[source_index] : (uint8_t)'\n';
    }
    cr_micro_frame_result_t result = cr_micro_vendor_frame_encode(payload, chunk_length, report);
    if (result != CR_MICRO_FRAME_OK) return result;
    *offset += chunk_length;
    *done = *offset == total_length;
    return CR_MICRO_FRAME_OK;
}

cr_micro_frame_result_t cr_micro_reassembler_push(
    cr_micro_reassembler_t *state,
    const uint8_t *report,
    size_t report_length
)
{
    if (state == NULL || report == NULL) return CR_MICRO_FRAME_INVALID_ARGUMENT;
    size_t body_offset;
    if (report_length == CR_MICRO_REPORT_BODY_BYTES) {
        body_offset = 0;
    } else if (report_length == CR_MICRO_REPORT_BODY_BYTES + 1
        && report[0] == CR_MICRO_REPORT_ID) {
        body_offset = 1;
    } else {
        reset_reassembler(state);
        return CR_MICRO_FRAME_INVALID_REPORT;
    }
    if (report[body_offset] != CR_MICRO_MESSAGE_TYPE_JSON) {
        reset_reassembler(state);
        return CR_MICRO_FRAME_INVALID_REPORT;
    }

    size_t payload_length = report[body_offset + 1];
    if (payload_length > CR_MICRO_PAYLOAD_BYTES) {
        reset_reassembler(state);
        return CR_MICRO_FRAME_INVALID_LENGTH;
    }
    const uint8_t *payload = report + body_offset + 2;
    static const uint8_t top_level_prefix[] = "{\"method\"";
    if (state->length > 0
        && payload_length >= sizeof(top_level_prefix) - 1
        && memcmp(payload, top_level_prefix, sizeof(top_level_prefix) - 1) == 0) {
        reset_reassembler(state);
    }

    for (size_t index = 0; index < payload_length; index++) {
        if (payload[index] == (uint8_t)'\n') {
            if (index + 1 != payload_length) {
                reset_reassembler(state);
                return CR_MICRO_FRAME_INVALID_REPORT;
            }
            state->message[state->length] = '\0';
            if (!is_valid_utf8((const uint8_t *)state->message, state->length)) {
                reset_reassembler(state);
                return CR_MICRO_FRAME_INVALID_UTF8;
            }
            return CR_MICRO_FRAME_MESSAGE_READY;
        }
        if (state->length == CR_MICRO_MAX_MESSAGE_BYTES) {
            reset_reassembler(state);
            return CR_MICRO_FRAME_TOO_LARGE;
        }
        state->message[state->length++] = (char)payload[index];
    }
    state->message[state->length] = '\0';
    if (has_complete_json_structure(state->message, state->length)) {
        if (!is_valid_utf8((const uint8_t *)state->message, state->length)) {
            reset_reassembler(state);
            return CR_MICRO_FRAME_INVALID_UTF8;
        }
        return CR_MICRO_FRAME_MESSAGE_READY;
    }
    return CR_MICRO_FRAME_NEED_MORE;
}
