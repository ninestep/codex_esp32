#include "codex_remote/codec.h"

#include "codex_remote/crc32.h"

#include <limits.h>
#include <string.h>

static uint32_t read_u32_le(const uint8_t *bytes)
{
    return (uint32_t)bytes[0]
        | ((uint32_t)bytes[1] << 8)
        | ((uint32_t)bytes[2] << 16)
        | ((uint32_t)bytes[3] << 24);
}

static void write_u32_le(uint8_t *bytes, uint32_t value)
{
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8);
    bytes[2] = (uint8_t)(value >> 16);
    bytes[3] = (uint8_t)(value >> 24);
}

static int is_known_message_type(uint8_t type)
{
    return type >= CR_MESSAGE_SELECT_SESSION && type <= CR_MESSAGE_MICRO_CONTROL_LAYOUT;
}

cr_result_t cr_envelope_decode(
    const uint8_t *encoded,
    size_t encoded_length,
    cr_envelope_view_t *envelope
)
{
    if (encoded == NULL || envelope == NULL) {
        return CR_ERR_INVALID_ARGUMENT;
    }
    if (encoded_length < CR_ENVELOPE_FIXED_OVERHEAD) {
        return CR_ERR_TRUNCATED;
    }
    if (encoded_length > CR_MAX_ENVELOPE_BYTES) {
        return CR_ERR_FRAME_TOO_LARGE;
    }
    if (encoded[0] != 'C' || encoded[1] != 'R') {
        return CR_ERR_INVALID_MAGIC;
    }
    if (encoded[2] != CR_PROTOCOL_MAJOR) {
        return CR_ERR_INCOMPATIBLE_VERSION;
    }
    if (!is_known_message_type(encoded[4])) {
        return CR_ERR_UNKNOWN_MESSAGE_TYPE;
    }
    if (encoded[5] != 0) {
        return CR_ERR_UNSUPPORTED_FLAGS;
    }

    uint32_t payload_length = read_u32_le(encoded + 10);
    size_t actual_payload_length = encoded_length - CR_ENVELOPE_FIXED_OVERHEAD;
    if ((size_t)payload_length != actual_payload_length) {
        return CR_ERR_PAYLOAD_LENGTH;
    }

    uint32_t stored_checksum = read_u32_le(encoded + encoded_length - CR_ENVELOPE_CHECKSUM_BYTES);
    uint32_t computed_checksum = cr_crc32_ieee(
        encoded,
        encoded_length - CR_ENVELOPE_CHECKSUM_BYTES
    );
    if (stored_checksum != computed_checksum) {
        return CR_ERR_CRC_MISMATCH;
    }

    *envelope = (cr_envelope_view_t){
        .version_major = encoded[2],
        .version_minor = encoded[3],
        .type = encoded[4],
        .flags = encoded[5],
        .sequence = read_u32_le(encoded + 6),
        .payload = encoded + CR_ENVELOPE_HEADER_BYTES,
        .payload_length = actual_payload_length,
    };
    return CR_OK;
}

cr_result_t cr_envelope_encode(
    const cr_envelope_view_t *envelope,
    uint8_t *output,
    size_t output_capacity,
    size_t *written
)
{
    if (envelope == NULL || written == NULL) {
        return CR_ERR_INVALID_ARGUMENT;
    }
    if (envelope->payload_length > 0 && envelope->payload == NULL) {
        return CR_ERR_INVALID_ARGUMENT;
    }
    if (envelope->version_major != CR_PROTOCOL_MAJOR) {
        return CR_ERR_INCOMPATIBLE_VERSION;
    }
    if (!is_known_message_type(envelope->type)) {
        return CR_ERR_UNKNOWN_MESSAGE_TYPE;
    }
    if (envelope->flags != 0) {
        return CR_ERR_UNSUPPORTED_FLAGS;
    }
    if (envelope->payload_length > UINT32_MAX) {
        return CR_ERR_NUMERIC_OVERFLOW;
    }
    if (envelope->payload_length > CR_MAX_ENVELOPE_BYTES - CR_ENVELOPE_FIXED_OVERHEAD) {
        return CR_ERR_FRAME_TOO_LARGE;
    }

    size_t required = CR_ENVELOPE_FIXED_OVERHEAD + envelope->payload_length;
    *written = required;
    if (output == NULL || output_capacity < required) {
        return CR_ERR_BUFFER_TOO_SMALL;
    }

    output[0] = 'C';
    output[1] = 'R';
    output[2] = envelope->version_major;
    output[3] = envelope->version_minor;
    output[4] = envelope->type;
    output[5] = envelope->flags;
    write_u32_le(output + 6, envelope->sequence);
    write_u32_le(output + 10, (uint32_t)envelope->payload_length);
    if (envelope->payload_length > 0) {
        memcpy(output + CR_ENVELOPE_HEADER_BYTES, envelope->payload, envelope->payload_length);
    }

    uint32_t checksum = cr_crc32_ieee(output, required - CR_ENVELOPE_CHECKSUM_BYTES);
    write_u32_le(output + required - CR_ENVELOPE_CHECKSUM_BYTES, checksum);
    return CR_OK;
}
