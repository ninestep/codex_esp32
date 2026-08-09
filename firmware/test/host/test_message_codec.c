#include "codex_remote/codec.h"
#include "codex_remote/fragment.h"
#include "codex_remote/message.h"

#include <assert.h>
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *path;
    uint8_t type;
    size_t expected_count;
} message_fixture_t;

static uint8_t hex_nibble(char value)
{
    if (value >= '0' && value <= '9') return (uint8_t)(value - '0');
    if (value >= 'a' && value <= 'f') return (uint8_t)(value - 'a' + 10);
    if (value >= 'A' && value <= 'F') return (uint8_t)(value - 'A' + 10);
    abort();
}

static uint8_t *decode_hex_text(const char *text, size_t length, size_t *byte_count)
{
    size_t digits = 0;
    for (size_t index = 0; index < length; index++) {
        if (!isspace((unsigned char)text[index])) digits++;
    }
    assert(digits % 2 == 0);
    uint8_t *bytes = malloc(digits / 2);
    assert(bytes != NULL);
    size_t output = 0;
    int high = -1;
    for (size_t index = 0; index < length; index++) {
        if (isspace((unsigned char)text[index])) continue;
        uint8_t nibble = hex_nibble(text[index]);
        if (high < 0) high = nibble;
        else {
            bytes[output++] = (uint8_t)(((uint8_t)high << 4) | nibble);
            high = -1;
        }
    }
    *byte_count = output;
    return bytes;
}

static char *load_text(const char *path, size_t *length)
{
    FILE *file = fopen(path, "rb");
    assert(file != NULL);
    assert(fseek(file, 0, SEEK_END) == 0);
    long size = ftell(file);
    assert(size > 0);
    rewind(file);
    char *text = calloc((size_t)size + 1, 1);
    assert(text != NULL);
    assert(fread(text, 1, (size_t)size, file) == (size_t)size);
    assert(fclose(file) == 0);
    *length = (size_t)size;
    return text;
}

static uint8_t *load_hex(const char *path, size_t *length)
{
    size_t text_length = 0;
    char *text = load_text(path, &text_length);
    uint8_t *bytes = decode_hex_text(text, text_length, length);
    free(text);
    return bytes;
}

static void assert_message_round_trip(message_fixture_t fixture)
{
    size_t encoded_length = 0;
    uint8_t *encoded = load_hex(fixture.path, &encoded_length);
    cr_envelope_view_t envelope = {0};
    assert(cr_envelope_decode(encoded, encoded_length, &envelope) == CR_OK);
    assert(envelope.type == fixture.type);

    cr_message_t message = {0};
    assert(cr_message_decode(&envelope, &message) == CR_OK);
    assert(message.type == fixture.type);
    if (fixture.type == CR_MESSAGE_STATE_SNAPSHOT) {
        assert(message.body.state_snapshot.session_count == fixture.expected_count);
    } else if (fixture.type == CR_MESSAGE_ASSET_MANIFEST) {
        assert(message.body.asset_manifest.item_count == fixture.expected_count);
    } else if (fixture.type == CR_MESSAGE_AUDIO_FRAME) {
        assert(message.body.audio_frame.sample_count == 320);
        assert(message.body.audio_frame.encoded_samples.length == 160);
    }

    uint8_t payload[CR_MAX_ENVELOPE_BYTES] = {0};
    size_t payload_length = 0;
    assert(cr_message_encode(&message, payload, sizeof(payload), &payload_length) == CR_OK);
    assert(payload_length == envelope.payload_length);
    assert(memcmp(payload, envelope.payload, payload_length) == 0);
    free(encoded);
}

static void test_all_valid_message_fixtures(void)
{
    const message_fixture_t fixtures[] = {
        {"macos/Fixtures/ble-v1/empty-action-result.hex", CR_MESSAGE_ACTION_RESULT, 0},
        {"macos/Fixtures/ble-v1/select-session.hex", CR_MESSAGE_SELECT_SESSION, 0},
        {"macos/Fixtures/ble-v1/terminal-enter.hex", CR_MESSAGE_TERMINAL_KEY, 0},
        {"macos/Fixtures/ble-v1/terminal-up.hex", CR_MESSAGE_TERMINAL_KEY, 0},
        {"macos/Fixtures/ble-v1/terminal-backspace.hex", CR_MESSAGE_TERMINAL_KEY, 0},
        {"macos/Fixtures/ble-v1/terminal-clear-line.hex", CR_MESSAGE_TERMINAL_KEY, 0},
        {"macos/Fixtures/ble-v1/terminal-compact.hex", CR_MESSAGE_TERMINAL_SHORTCUT, 0},
        {"macos/Fixtures/ble-v1/snapshot-four.hex", CR_MESSAGE_STATE_SNAPSHOT, 4},
        {"macos/Fixtures/ble-v1/snapshot-eight.hex", CR_MESSAGE_STATE_SNAPSHOT, 8},
        {"macos/Fixtures/ble-v1/state-delta.hex", CR_MESSAGE_STATE_DELTA, 0},
        {"macos/Fixtures/ble-v1/adpcm-silence.hex", CR_MESSAGE_AUDIO_FRAME, 0},
        {"macos/Fixtures/ble-v1/asset-manifest.hex", CR_MESSAGE_ASSET_MANIFEST, 1},
        {"macos/Fixtures/ble-v1/asset-chunk.hex", CR_MESSAGE_ASSET_CHUNK, 0},
        {"macos/Fixtures/ble-v1/device-info.hex", CR_MESSAGE_DEVICE_INFO, 0},
        {"macos/Fixtures/ble-v1/micro-control-layout.hex", CR_MESSAGE_MICRO_CONTROL_LAYOUT, 0},
    };
    size_t count = sizeof(fixtures) / sizeof(fixtures[0]);
    for (size_t index = 0; index < count; index++) {
        assert_message_round_trip(fixtures[index]);
    }
}

static void test_two_fragment_fixture_reassembles(void)
{
    size_t text_length = 0;
    char *text = load_text("macos/Fixtures/ble-v1/two-fragment-message.hex", &text_length);
    char *line_break = strchr(text, '\n');
    assert(line_break != NULL);

    size_t first_length = 0;
    size_t second_length = 0;
    uint8_t *first = decode_hex_text(text, (size_t)(line_break - text), &first_length);
    uint8_t *second = decode_hex_text(
        line_break + 1,
        text_length - (size_t)(line_break + 1 - text),
        &second_length
    );
    free(text);

    uint8_t storage[CR_MAX_ENVELOPE_BYTES] = {0};
    cr_fragment_reassembler_t reassembler;
    cr_fragment_reassembler_init(&reassembler, storage, sizeof(storage));
    cr_byte_view_t complete = {0};
    assert(cr_fragment_reassembler_accept(&reassembler, first, first_length, &complete) == CR_FRAGMENT_WAITING);
    assert(cr_fragment_reassembler_accept(&reassembler, second, second_length, &complete) == CR_FRAGMENT_COMPLETE);

    cr_envelope_view_t envelope = {0};
    assert(cr_envelope_decode(complete.bytes, complete.length, &envelope) == CR_OK);
    assert(envelope.type == CR_MESSAGE_SELECT_SESSION);
    assert(envelope.sequence == 17);
    free(first);
    free(second);
}

static void assert_constructed_message_round_trip(const cr_message_t *message)
{
    uint8_t payload[512] = {0};
    size_t payload_length = 0;
    assert(cr_message_encode(message, payload, sizeof(payload), &payload_length) == CR_OK);
    cr_envelope_view_t envelope = {
        .version_major = CR_PROTOCOL_MAJOR,
        .version_minor = CR_PROTOCOL_MINOR,
        .type = message->type,
        .payload = payload,
        .payload_length = payload_length,
    };
    cr_message_t decoded = {0};
    assert(cr_message_decode(&envelope, &decoded) == CR_OK);
    uint8_t round_trip[512] = {0};
    size_t round_trip_length = 0;
    assert(cr_message_encode(&decoded, round_trip, sizeof(round_trip), &round_trip_length) == CR_OK);
    assert(round_trip_length == payload_length);
    assert(memcmp(payload, round_trip, payload_length) == 0);
}

static void test_non_fixture_message_types_round_trip(void)
{
    const cr_message_t messages[] = {
        {.type = CR_MESSAGE_SCROLL, .body.scroll = {.session_key = 2, .delta = -9, .sequence = 7}},
        {.type = CR_MESSAGE_TERMINAL_KEY, .body.terminal_key = {.request_id = 7, .session_key = 2, .key = CR_TERMINAL_KEY_RIGHT}},
        {.type = CR_MESSAGE_TERMINAL_SHORTCUT, .body.terminal_shortcut = {.request_id = 8, .session_key = 2, .shortcut = CR_TERMINAL_SHORTCUT_COMPACT}},
        {.type = CR_MESSAGE_PTT_BEGIN, .body.ptt_begin = {.request_id = 9, .session_key = 2, .first_audio_sequence = 10}},
        {.type = CR_MESSAGE_PTT_END, .body.ptt_end = {.request_id = 9, .session_key = 2, .last_audio_sequence = 19}},
        {.type = CR_MESSAGE_ASSET_ACKNOWLEDGEMENT, .body.asset_acknowledgement = {.set_id = 4, .asset_id = 3, .next_offset = 128, .result = 1}},
        {.type = CR_MESSAGE_RESYNC_REQUIRED, .body.resync_required = {.reason = 2}},
        {.type = CR_MESSAGE_MICRO_CONTROL_LAYOUT, .body.micro_control_layout = {
            .controls = {
                {.bytes = (const uint8_t *)"fast", .length = 4},
                {.bytes = (const uint8_t *)"approve", .length = 7},
                {.bytes = (const uint8_t *)"decline", .length = 7},
                {.bytes = (const uint8_t *)"continue", .length = 8},
                {.bytes = (const uint8_t *)"ptt", .length = 3},
                {.bytes = (const uint8_t *)"send", .length = 4},
            },
            .encoder = {.bytes = (const uint8_t *)"scroll", .length = 6},
            .directions = {
                {.bytes = (const uint8_t *)"plan", .length = 4},
                {.bytes = (const uint8_t *)"forward", .length = 7},
                {.bytes = (const uint8_t *)"sidebar", .length = 7},
                {.bytes = (const uint8_t *)"back", .length = 4},
            },
        }},
    };
    for (size_t index = 0; index < sizeof(messages) / sizeof(messages[0]); index++) {
        assert_constructed_message_round_trip(&messages[index]);
    }
}

static void test_malformed_payloads_are_rejected(void)
{
    const uint8_t invalid_key[] = {1, 0, 0, 0, 2, 0, 9};
    cr_envelope_view_t envelope = {
        .type = CR_MESSAGE_TERMINAL_KEY,
        .payload = invalid_key,
        .payload_length = sizeof(invalid_key),
    };
    cr_message_t message = {0};
    assert(cr_message_decode(&envelope, &message) == CR_ERR_INVALID_PAYLOAD);

    const uint8_t invalid_shortcut[] = {1, 0, 0, 0, 2, 0, 6};
    envelope.type = CR_MESSAGE_TERMINAL_SHORTCUT;
    envelope.payload = invalid_shortcut;
    envelope.payload_length = sizeof(invalid_shortcut);
    assert(cr_message_decode(&envelope, &message) == CR_ERR_INVALID_PAYLOAD);

    const uint8_t too_many_sessions[] = {1, 0, 0, 0, 9};
    envelope.type = CR_MESSAGE_STATE_SNAPSHOT;
    envelope.payload = too_many_sessions;
    envelope.payload_length = sizeof(too_many_sessions);
    assert(cr_message_decode(&envelope, &message) == CR_ERR_INVALID_PAYLOAD);

    const uint8_t trailing_select[] = {1, 0, 0, 0, 2, 0, 0xff};
    envelope.type = CR_MESSAGE_SELECT_SESSION;
    envelope.payload = trailing_select;
    envelope.payload_length = sizeof(trailing_select);
    assert(cr_message_decode(&envelope, &message) == CR_ERR_TRAILING_BYTES);

    const uint8_t invalid_utf8_action[] = {1, 0, 0, 0, 0, 1, 0, 0xff};
    envelope.type = CR_MESSAGE_ACTION_RESULT;
    envelope.payload = invalid_utf8_action;
    envelope.payload_length = sizeof(invalid_utf8_action);
    assert(cr_message_decode(&envelope, &message) == CR_ERR_INVALID_UTF8);
}

int main(void)
{
    assert(CR_PROTOCOL_MINOR == 3);
    assert(CR_TERMINAL_KEY_BACKSPACE == 7);
    assert(CR_TERMINAL_KEY_CLEAR_LINE == 8);
    test_all_valid_message_fixtures();
    test_two_fragment_fixture_reassembles();
    test_non_fixture_message_types_round_trip();
    test_malformed_payloads_are_rejected();
    puts("test_message_codec: PASS");
    return 0;
}
