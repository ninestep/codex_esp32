#include "codex_remote/codec.h"
#include "codex_remote/crc32.h"

#include <assert.h>
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ARRAY_COUNT(values) (sizeof(values) / sizeof((values)[0]))

typedef struct {
    const char *path;
    uint8_t type;
    uint32_t sequence;
    size_t payload_length;
} valid_fixture_t;

static uint8_t hex_nibble(char value)
{
    if (value >= '0' && value <= '9') {
        return (uint8_t)(value - '0');
    }
    if (value >= 'a' && value <= 'f') {
        return (uint8_t)(value - 'a' + 10);
    }
    if (value >= 'A' && value <= 'F') {
        return (uint8_t)(value - 'A' + 10);
    }
    fprintf(stderr, "invalid hex character: %c\n", value);
    abort();
}

static uint8_t *load_hex_fixture(const char *path, size_t *byte_count)
{
    FILE *file = fopen(path, "rb");
    assert(file != NULL);
    assert(fseek(file, 0, SEEK_END) == 0);
    long file_size = ftell(file);
    assert(file_size > 0);
    rewind(file);

    char *text = calloc((size_t)file_size + 1, 1);
    assert(text != NULL);
    assert(fread(text, 1, (size_t)file_size, file) == (size_t)file_size);
    assert(fclose(file) == 0);

    size_t digit_count = 0;
    for (long index = 0; index < file_size; index++) {
        if (!isspace((unsigned char)text[index])) {
            digit_count++;
        }
    }
    assert(digit_count % 2 == 0);

    uint8_t *bytes = malloc(digit_count / 2);
    assert(bytes != NULL);
    size_t output_index = 0;
    int high_nibble = -1;
    for (long index = 0; index < file_size; index++) {
        if (isspace((unsigned char)text[index])) {
            continue;
        }
        uint8_t nibble = hex_nibble(text[index]);
        if (high_nibble < 0) {
            high_nibble = nibble;
        } else {
            bytes[output_index++] = (uint8_t)(((uint8_t)high_nibble << 4) | nibble);
            high_nibble = -1;
        }
    }
    free(text);
    *byte_count = output_index;
    return bytes;
}

static void assert_valid_fixture_round_trip(valid_fixture_t fixture)
{
    size_t encoded_length = 0;
    uint8_t *encoded = load_hex_fixture(fixture.path, &encoded_length);
    assert(encoded_length == CR_ENVELOPE_FIXED_OVERHEAD + fixture.payload_length);
    assert(encoded[0] == 'C');
    assert(encoded[1] == 'R');

    cr_envelope_view_t envelope = {0};
    assert(cr_envelope_decode(encoded, encoded_length, &envelope) == CR_OK);
    assert(envelope.version_major == CR_PROTOCOL_MAJOR);
    assert(envelope.version_minor == CR_PROTOCOL_MINOR);
    assert(envelope.type == fixture.type);
    assert(envelope.flags == 0);
    assert(envelope.sequence == fixture.sequence);
    assert(envelope.payload_length == fixture.payload_length);

    uint32_t stored_crc = (uint32_t)encoded[encoded_length - 4]
        | ((uint32_t)encoded[encoded_length - 3] << 8)
        | ((uint32_t)encoded[encoded_length - 2] << 16)
        | ((uint32_t)encoded[encoded_length - 1] << 24);
    assert(cr_crc32_ieee(encoded, encoded_length - 4) == stored_crc);

    uint8_t *round_trip = calloc(encoded_length, 1);
    assert(round_trip != NULL);
    size_t written = 0;
    assert(cr_envelope_encode(&envelope, round_trip, encoded_length, &written) == CR_OK);
    assert(written == encoded_length);
    assert(memcmp(encoded, round_trip, encoded_length) == 0);

    free(round_trip);
    free(encoded);
}

static void test_valid_envelopes_round_trip(void)
{
    const valid_fixture_t fixtures[] = {
        {"macos/Fixtures/ble-v1/empty-action-result.hex", CR_MESSAGE_ACTION_RESULT, 0, 7},
        {"macos/Fixtures/ble-v1/select-session.hex", CR_MESSAGE_SELECT_SESSION, 1, 6},
        {"macos/Fixtures/ble-v1/terminal-enter.hex", CR_MESSAGE_TERMINAL_KEY, 2, 7},
        {"macos/Fixtures/ble-v1/terminal-up.hex", CR_MESSAGE_TERMINAL_KEY, 3, 7},
        {"macos/Fixtures/ble-v1/terminal-backspace.hex", CR_MESSAGE_TERMINAL_KEY, 4, 7},
        {"macos/Fixtures/ble-v1/terminal-clear-line.hex", CR_MESSAGE_TERMINAL_KEY, 5, 7},
        {"macos/Fixtures/ble-v1/terminal-compact.hex", CR_MESSAGE_TERMINAL_SHORTCUT, 6, 7},
    };

    for (size_t index = 0; index < ARRAY_COUNT(fixtures); index++) {
        assert_valid_fixture_round_trip(fixtures[index]);
    }
}

static void test_invalid_envelopes_are_rejected(void)
{
    size_t byte_count = 0;
    uint8_t *bad_crc = load_hex_fixture("macos/Fixtures/ble-v1/bad-crc.hex", &byte_count);
    cr_envelope_view_t envelope = {0};
    assert(cr_envelope_decode(bad_crc, byte_count, &envelope) == CR_ERR_CRC_MISMATCH);
    free(bad_crc);

    uint8_t *bad_version = load_hex_fixture(
        "macos/Fixtures/ble-v1/incompatible-major.hex",
        &byte_count
    );
    assert(cr_envelope_decode(bad_version, byte_count, &envelope) == CR_ERR_INCOMPATIBLE_VERSION);
    free(bad_version);
}

static void test_output_capacity_is_checked_before_writing(void)
{
    const uint8_t payload[] = {0x01, 0x02};
    cr_envelope_view_t envelope = {
        .version_major = CR_PROTOCOL_MAJOR,
        .version_minor = CR_PROTOCOL_MINOR,
        .type = CR_MESSAGE_SELECT_SESSION,
        .flags = 0,
        .sequence = 42,
        .payload = payload,
        .payload_length = sizeof(payload),
    };
    uint8_t output[CR_ENVELOPE_FIXED_OVERHEAD + sizeof(payload) - 1];
    memset(output, 0xa5, sizeof(output));
    size_t written = 99;

    assert(cr_envelope_encode(&envelope, output, sizeof(output), &written) == CR_ERR_BUFFER_TOO_SMALL);
    assert(written == CR_ENVELOPE_FIXED_OVERHEAD + sizeof(payload));
    for (size_t index = 0; index < sizeof(output); index++) {
        assert(output[index] == 0xa5);
    }
}

int main(void)
{
    test_valid_envelopes_round_trip();
    test_invalid_envelopes_are_rejected();
    test_output_capacity_is_checked_before_writing();
    puts("test_codec: PASS");
    return 0;
}
