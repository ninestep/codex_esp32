#include "codex_remote/message.h"

#include <limits.h>
#include <string.h>

typedef struct {
    const uint8_t *bytes;
    size_t length;
    size_t offset;
} reader_t;

typedef struct {
    uint8_t *bytes;
    size_t capacity;
    size_t offset;
    bool overflow;
} writer_t;

static bool utf8_is_valid(const uint8_t *bytes, size_t length)
{
    size_t index = 0;
    while (index < length) {
        uint8_t first = bytes[index++];
        if (first <= 0x7f) continue;
        if (first >= 0xc2 && first <= 0xdf) {
            if (index >= length || (bytes[index++] & 0xc0) != 0x80) return false;
            continue;
        }
        if (first >= 0xe0 && first <= 0xef) {
            if (index + 1 >= length) return false;
            uint8_t second = bytes[index++];
            uint8_t third = bytes[index++];
            if ((second & 0xc0) != 0x80 || (third & 0xc0) != 0x80) return false;
            if (first == 0xe0 && second < 0xa0) return false;
            if (first == 0xed && second >= 0xa0) return false;
            continue;
        }
        if (first >= 0xf0 && first <= 0xf4) {
            if (index + 2 >= length) return false;
            uint8_t second = bytes[index++];
            uint8_t third = bytes[index++];
            uint8_t fourth = bytes[index++];
            if ((second & 0xc0) != 0x80 || (third & 0xc0) != 0x80 || (fourth & 0xc0) != 0x80) return false;
            if (first == 0xf0 && second < 0x90) return false;
            if (first == 0xf4 && second >= 0x90) return false;
            continue;
        }
        return false;
    }
    return true;
}

static bool reader_take(reader_t *reader, size_t count, const uint8_t **bytes)
{
    if (count > reader->length - reader->offset) return false;
    *bytes = reader->bytes + reader->offset;
    reader->offset += count;
    return true;
}

static bool read_u8(reader_t *reader, uint8_t *value)
{
    const uint8_t *bytes = NULL;
    if (!reader_take(reader, 1, &bytes)) return false;
    *value = bytes[0];
    return true;
}

static bool read_u16(reader_t *reader, uint16_t *value)
{
    const uint8_t *bytes = NULL;
    if (!reader_take(reader, 2, &bytes)) return false;
    *value = (uint16_t)((uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8));
    return true;
}

static bool read_u32(reader_t *reader, uint32_t *value)
{
    const uint8_t *bytes = NULL;
    if (!reader_take(reader, 4, &bytes)) return false;
    *value = (uint32_t)bytes[0]
        | ((uint32_t)bytes[1] << 8)
        | ((uint32_t)bytes[2] << 16)
        | ((uint32_t)bytes[3] << 24);
    return true;
}

static bool read_u64(reader_t *reader, uint64_t *value)
{
    const uint8_t *bytes = NULL;
    if (!reader_take(reader, 8, &bytes)) return false;
    *value = 0;
    for (uint8_t index = 0; index < 8; index++) {
        *value |= (uint64_t)bytes[index] << (index * 8);
    }
    return true;
}

static cr_result_t read_string(reader_t *reader, size_t maximum, cr_byte_view_t *value)
{
    uint16_t length = 0;
    if (!read_u16(reader, &length)) return CR_ERR_TRUNCATED;
    if ((size_t)length > maximum) return CR_ERR_STRING_TOO_LONG;
    const uint8_t *bytes = NULL;
    if (!reader_take(reader, length, &bytes)) return CR_ERR_TRUNCATED;
    if (!utf8_is_valid(bytes, length)) return CR_ERR_INVALID_UTF8;
    *value = (cr_byte_view_t){.bytes = bytes, .length = length};
    return CR_OK;
}

static cr_result_t decode_session(reader_t *reader, cr_session_view_t *session)
{
    uint8_t unread = 0;
    cr_result_t result;
    if (!read_u16(reader, &session->session_key)) return CR_ERR_TRUNCATED;
    result = read_string(reader, CR_MAX_TITLE_BYTES, &session->display_title);
    if (result != CR_OK) return result;
    result = read_string(reader, CR_MAX_TITLE_BYTES, &session->working_directory_label);
    if (result != CR_OK) return result;
    if (!read_u8(reader, &session->state)) return CR_ERR_TRUNCATED;
    if (session->state > 5) return CR_ERR_INVALID_PAYLOAD;
    result = read_string(reader, CR_MAX_DETAIL_BYTES, &session->status_detail);
    if (result != CR_OK) return result;
    if (!read_u8(reader, &unread)) return CR_ERR_TRUNCATED;
    if (unread > 1) return CR_ERR_INVALID_PAYLOAD;
    session->unread = unread == 1;
    if (!read_u16(reader, &session->capabilities)
        || !read_u64(reader, &session->updated_at_milliseconds)) return CR_ERR_TRUNCATED;
    return CR_OK;
}

static cr_result_t validate_manifest(const cr_message_t *message)
{
    size_t count = message->body.asset_manifest.item_count;
    if (count == 0 || count > CR_MAX_ASSETS) return CR_ERR_INVALID_PAYLOAD;
    uint64_t total = 0;
    for (size_t index = 0; index < count; index++) {
        const cr_asset_descriptor_t *item = &message->body.asset_manifest.items[index];
        if (item->width == 0 || item->height == 0 || item->byte_count == 0) return CR_ERR_INVALID_PAYLOAD;
        total += item->byte_count;
        for (size_t previous = 0; previous < index; previous++) {
            if (message->body.asset_manifest.items[previous].asset_id == item->asset_id) return CR_ERR_INVALID_PAYLOAD;
        }
    }
    return total == message->body.asset_manifest.total_bytes ? CR_OK : CR_ERR_INVALID_PAYLOAD;
}

cr_result_t cr_message_decode(const cr_envelope_view_t *envelope, cr_message_t *message)
{
    if (envelope == NULL || message == NULL || (envelope->payload_length > 0 && envelope->payload == NULL)) {
        return CR_ERR_INVALID_ARGUMENT;
    }
    reader_t reader = {.bytes = envelope->payload, .length = envelope->payload_length};
    memset(message, 0, sizeof(*message));
    message->type = envelope->type;
    uint16_t raw16 = 0;
    uint8_t raw8 = 0;
    cr_result_t result = CR_OK;

    switch (message->type) {
    case CR_MESSAGE_SELECT_SESSION:
        if (!read_u32(&reader, &message->body.select_session.request_id)
            || !read_u16(&reader, &message->body.select_session.session_key)) result = CR_ERR_TRUNCATED;
        break;
    case CR_MESSAGE_SCROLL:
        if (!read_u16(&reader, &message->body.scroll.session_key) || !read_u16(&reader, &raw16)
            || !read_u32(&reader, &message->body.scroll.sequence)) result = CR_ERR_TRUNCATED;
        message->body.scroll.delta = (int16_t)raw16;
        break;
    case CR_MESSAGE_TERMINAL_KEY:
        if (!read_u32(&reader, &message->body.terminal_key.request_id)
            || !read_u16(&reader, &message->body.terminal_key.session_key)
            || !read_u8(&reader, &message->body.terminal_key.key)) result = CR_ERR_TRUNCATED;
        else if (message->body.terminal_key.key < CR_TERMINAL_KEY_ENTER
            || message->body.terminal_key.key > CR_TERMINAL_KEY_CLEAR_LINE) result = CR_ERR_INVALID_PAYLOAD;
        break;
    case CR_MESSAGE_TERMINAL_SHORTCUT:
        if (!read_u32(&reader, &message->body.terminal_shortcut.request_id)
            || !read_u16(&reader, &message->body.terminal_shortcut.session_key)
            || !read_u8(&reader, &message->body.terminal_shortcut.shortcut)) result = CR_ERR_TRUNCATED;
        else if (message->body.terminal_shortcut.shortcut < CR_TERMINAL_SHORTCUT_NEW_SESSION
            || message->body.terminal_shortcut.shortcut > CR_TERMINAL_SHORTCUT_COMPACT) result = CR_ERR_INVALID_PAYLOAD;
        break;
    case CR_MESSAGE_PTT_BEGIN:
        if (!read_u32(&reader, &message->body.ptt_begin.request_id)
            || !read_u16(&reader, &message->body.ptt_begin.session_key)
            || !read_u32(&reader, &message->body.ptt_begin.first_audio_sequence)) result = CR_ERR_TRUNCATED;
        break;
    case CR_MESSAGE_PTT_END:
        if (!read_u32(&reader, &message->body.ptt_end.request_id)
            || !read_u16(&reader, &message->body.ptt_end.session_key)
            || !read_u32(&reader, &message->body.ptt_end.last_audio_sequence)) result = CR_ERR_TRUNCATED;
        break;
    case CR_MESSAGE_ACTION_RESULT:
        if (!read_u32(&reader, &message->body.action_result.request_id)
            || !read_u8(&reader, &message->body.action_result.result)) result = CR_ERR_TRUNCATED;
        else if (message->body.action_result.result > 4) result = CR_ERR_INVALID_PAYLOAD;
        else result = read_string(&reader, CR_MAX_DETAIL_BYTES, &message->body.action_result.detail);
        break;
    case CR_MESSAGE_STATE_SNAPSHOT:
        if (!read_u32(&reader, &message->body.state_snapshot.generation) || !read_u8(&reader, &raw8)) {
            result = CR_ERR_TRUNCATED;
            break;
        }
        if (raw8 > CR_MAX_SESSIONS) {
            result = CR_ERR_INVALID_PAYLOAD;
            break;
        }
        message->body.state_snapshot.session_count = raw8;
        for (size_t index = 0; index < raw8 && result == CR_OK; index++) {
            result = decode_session(&reader, &message->body.state_snapshot.sessions[index]);
        }
        break;
    case CR_MESSAGE_STATE_DELTA:
        if (!read_u32(&reader, &message->body.state_delta.generation)
            || !read_u32(&reader, &message->body.state_delta.sequence)) result = CR_ERR_TRUNCATED;
        else result = decode_session(&reader, &message->body.state_delta.session);
        break;
    case CR_MESSAGE_AUDIO_FRAME:
        if (!read_u32(&reader, &message->body.audio_frame.sequence)
            || !read_u64(&reader, &message->body.audio_frame.sample_timestamp)
            || !read_u16(&reader, &raw16)) {
            result = CR_ERR_TRUNCATED;
            break;
        }
        message->body.audio_frame.predictor = (int16_t)raw16;
        if (!read_u8(&reader, &message->body.audio_frame.step_index)
            || !read_u16(&reader, &message->body.audio_frame.sample_count)
            || !read_u16(&reader, &raw16)) {
            result = CR_ERR_TRUNCATED;
            break;
        }
        if (!reader_take(&reader, raw16, &message->body.audio_frame.encoded_samples.bytes)) {
            result = CR_ERR_TRUNCATED;
            break;
        }
        message->body.audio_frame.encoded_samples.length = raw16;
        if (message->body.audio_frame.sample_count != CR_AUDIO_SAMPLE_COUNT
            || message->body.audio_frame.encoded_samples.length != CR_AUDIO_ENCODED_BYTES
            || message->body.audio_frame.step_index > 88) result = CR_ERR_INVALID_PAYLOAD;
        break;
    case CR_MESSAGE_ASSET_MANIFEST:
        if (!read_u32(&reader, &message->body.asset_manifest.set_id)
            || !read_u32(&reader, &message->body.asset_manifest.total_bytes)
            || !read_u8(&reader, &raw8)) {
            result = CR_ERR_TRUNCATED;
            break;
        }
        if (raw8 > CR_MAX_ASSETS) {
            result = CR_ERR_INVALID_PAYLOAD;
            break;
        }
        message->body.asset_manifest.item_count = raw8;
        for (size_t index = 0; index < raw8; index++) {
            cr_asset_descriptor_t *item = &message->body.asset_manifest.items[index];
            if (!read_u16(&reader, &item->asset_id) || !read_u16(&reader, &item->width)
                || !read_u16(&reader, &item->height) || !read_u32(&reader, &item->byte_count)
                || !read_u32(&reader, &item->crc32)) {
                result = CR_ERR_TRUNCATED;
                break;
            }
        }
        if (result == CR_OK) result = validate_manifest(message);
        break;
    case CR_MESSAGE_ASSET_CHUNK:
        if (!read_u32(&reader, &message->body.asset_chunk.set_id)
            || !read_u16(&reader, &message->body.asset_chunk.asset_id)
            || !read_u32(&reader, &message->body.asset_chunk.offset) || !read_u16(&reader, &raw16)) {
            result = CR_ERR_TRUNCATED;
            break;
        }
        if (!reader_take(&reader, raw16, &message->body.asset_chunk.bytes.bytes)) result = CR_ERR_TRUNCATED;
        else message->body.asset_chunk.bytes.length = raw16;
        break;
    case CR_MESSAGE_ASSET_ACKNOWLEDGEMENT:
        if (!read_u32(&reader, &message->body.asset_acknowledgement.set_id)
            || !read_u16(&reader, &message->body.asset_acknowledgement.asset_id)
            || !read_u32(&reader, &message->body.asset_acknowledgement.next_offset)
            || !read_u8(&reader, &message->body.asset_acknowledgement.result)) result = CR_ERR_TRUNCATED;
        else if (message->body.asset_acknowledgement.result > 3) result = CR_ERR_INVALID_PAYLOAD;
        break;
    case CR_MESSAGE_DEVICE_INFO:
        if (!read_u8(&reader, &message->body.device_info.protocol_major)
            || !read_u8(&reader, &message->body.device_info.protocol_minor)) {
            result = CR_ERR_TRUNCATED;
            break;
        }
        if (message->body.device_info.protocol_major != CR_PROTOCOL_MAJOR) {
            result = CR_ERR_INCOMPATIBLE_VERSION;
            break;
        }
        result = read_string(&reader, CR_MAX_TITLE_BYTES, &message->body.device_info.firmware_version);
        if (result == CR_OK && (!read_u16(&reader, &message->body.device_info.capabilities)
            || !read_u8(&reader, &message->body.device_info.battery_percent))) result = CR_ERR_TRUNCATED;
        if (result == CR_OK && message->body.device_info.battery_percent > 100) result = CR_ERR_INVALID_PAYLOAD;
        break;
    case CR_MESSAGE_RESYNC_REQUIRED:
        if (!read_u8(&reader, &message->body.resync_required.reason)) result = CR_ERR_TRUNCATED;
        else if (message->body.resync_required.reason < 1 || message->body.resync_required.reason > 4) result = CR_ERR_INVALID_PAYLOAD;
        break;
    default:
        result = CR_ERR_UNSUPPORTED_MESSAGE;
        break;
    }

    if (result == CR_OK && reader.offset != reader.length) return CR_ERR_TRAILING_BYTES;
    return result;
}

static void writer_bytes(writer_t *writer, const uint8_t *bytes, size_t length)
{
    if (length > SIZE_MAX - writer->offset) {
        writer->overflow = true;
        return;
    }
    if (writer->bytes != NULL) {
        if (length > writer->capacity - writer->offset) {
            writer->overflow = true;
            return;
        }
        if (length > 0) memcpy(writer->bytes + writer->offset, bytes, length);
    }
    writer->offset += length;
}

static void write_u8(writer_t *writer, uint8_t value) { writer_bytes(writer, &value, 1); }

static void write_u16(writer_t *writer, uint16_t value)
{
    uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8)};
    writer_bytes(writer, bytes, sizeof(bytes));
}

static void write_u32(writer_t *writer, uint32_t value)
{
    uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8), (uint8_t)(value >> 16), (uint8_t)(value >> 24)};
    writer_bytes(writer, bytes, sizeof(bytes));
}

static void write_u64(writer_t *writer, uint64_t value)
{
    uint8_t bytes[8];
    for (uint8_t index = 0; index < 8; index++) bytes[index] = (uint8_t)(value >> (index * 8));
    writer_bytes(writer, bytes, sizeof(bytes));
}

static cr_result_t write_string(writer_t *writer, cr_byte_view_t value, size_t maximum)
{
    if (value.length > maximum || value.length > UINT16_MAX) return CR_ERR_STRING_TOO_LONG;
    if (value.length > 0 && value.bytes == NULL) return CR_ERR_INVALID_ARGUMENT;
    if (!utf8_is_valid(value.bytes, value.length)) return CR_ERR_INVALID_UTF8;
    write_u16(writer, (uint16_t)value.length);
    writer_bytes(writer, value.bytes, value.length);
    return CR_OK;
}

static cr_result_t encode_session(writer_t *writer, const cr_session_view_t *session)
{
    if (session->state > 5) return CR_ERR_INVALID_PAYLOAD;
    write_u16(writer, session->session_key);
    cr_result_t result = write_string(writer, session->display_title, CR_MAX_TITLE_BYTES);
    if (result != CR_OK) return result;
    result = write_string(writer, session->working_directory_label, CR_MAX_TITLE_BYTES);
    if (result != CR_OK) return result;
    write_u8(writer, session->state);
    result = write_string(writer, session->status_detail, CR_MAX_DETAIL_BYTES);
    if (result != CR_OK) return result;
    write_u8(writer, session->unread ? 1 : 0);
    write_u16(writer, session->capabilities);
    write_u64(writer, session->updated_at_milliseconds);
    return CR_OK;
}

static cr_result_t encode_body(const cr_message_t *message, writer_t *writer)
{
    cr_result_t result = CR_OK;
    switch (message->type) {
    case CR_MESSAGE_SELECT_SESSION:
        write_u32(writer, message->body.select_session.request_id);
        write_u16(writer, message->body.select_session.session_key);
        break;
    case CR_MESSAGE_SCROLL:
        write_u16(writer, message->body.scroll.session_key);
        write_u16(writer, (uint16_t)message->body.scroll.delta);
        write_u32(writer, message->body.scroll.sequence);
        break;
    case CR_MESSAGE_TERMINAL_KEY:
        if (message->body.terminal_key.key < CR_TERMINAL_KEY_ENTER
            || message->body.terminal_key.key > CR_TERMINAL_KEY_CLEAR_LINE) return CR_ERR_INVALID_PAYLOAD;
        write_u32(writer, message->body.terminal_key.request_id);
        write_u16(writer, message->body.terminal_key.session_key);
        write_u8(writer, message->body.terminal_key.key);
        break;
    case CR_MESSAGE_TERMINAL_SHORTCUT:
        if (message->body.terminal_shortcut.shortcut < CR_TERMINAL_SHORTCUT_NEW_SESSION
            || message->body.terminal_shortcut.shortcut > CR_TERMINAL_SHORTCUT_COMPACT) return CR_ERR_INVALID_PAYLOAD;
        write_u32(writer, message->body.terminal_shortcut.request_id);
        write_u16(writer, message->body.terminal_shortcut.session_key);
        write_u8(writer, message->body.terminal_shortcut.shortcut);
        break;
    case CR_MESSAGE_PTT_BEGIN:
        write_u32(writer, message->body.ptt_begin.request_id);
        write_u16(writer, message->body.ptt_begin.session_key);
        write_u32(writer, message->body.ptt_begin.first_audio_sequence);
        break;
    case CR_MESSAGE_PTT_END:
        write_u32(writer, message->body.ptt_end.request_id);
        write_u16(writer, message->body.ptt_end.session_key);
        write_u32(writer, message->body.ptt_end.last_audio_sequence);
        break;
    case CR_MESSAGE_ACTION_RESULT:
        if (message->body.action_result.result > 4) return CR_ERR_INVALID_PAYLOAD;
        write_u32(writer, message->body.action_result.request_id);
        write_u8(writer, message->body.action_result.result);
        return write_string(writer, message->body.action_result.detail, CR_MAX_DETAIL_BYTES);
    case CR_MESSAGE_STATE_SNAPSHOT:
        if (message->body.state_snapshot.session_count > CR_MAX_SESSIONS) return CR_ERR_INVALID_PAYLOAD;
        write_u32(writer, message->body.state_snapshot.generation);
        write_u8(writer, (uint8_t)message->body.state_snapshot.session_count);
        for (size_t index = 0; index < message->body.state_snapshot.session_count; index++) {
            result = encode_session(writer, &message->body.state_snapshot.sessions[index]);
            if (result != CR_OK) return result;
        }
        break;
    case CR_MESSAGE_STATE_DELTA:
        write_u32(writer, message->body.state_delta.generation);
        write_u32(writer, message->body.state_delta.sequence);
        return encode_session(writer, &message->body.state_delta.session);
    case CR_MESSAGE_AUDIO_FRAME:
        if (message->body.audio_frame.sample_count != CR_AUDIO_SAMPLE_COUNT
            || message->body.audio_frame.encoded_samples.length != CR_AUDIO_ENCODED_BYTES
            || message->body.audio_frame.step_index > 88) return CR_ERR_INVALID_PAYLOAD;
        write_u32(writer, message->body.audio_frame.sequence);
        write_u64(writer, message->body.audio_frame.sample_timestamp);
        write_u16(writer, (uint16_t)message->body.audio_frame.predictor);
        write_u8(writer, message->body.audio_frame.step_index);
        write_u16(writer, message->body.audio_frame.sample_count);
        write_u16(writer, (uint16_t)message->body.audio_frame.encoded_samples.length);
        writer_bytes(writer, message->body.audio_frame.encoded_samples.bytes, message->body.audio_frame.encoded_samples.length);
        break;
    case CR_MESSAGE_ASSET_MANIFEST:
        result = validate_manifest(message);
        if (result != CR_OK) return result;
        write_u32(writer, message->body.asset_manifest.set_id);
        write_u32(writer, message->body.asset_manifest.total_bytes);
        write_u8(writer, (uint8_t)message->body.asset_manifest.item_count);
        for (size_t index = 0; index < message->body.asset_manifest.item_count; index++) {
            const cr_asset_descriptor_t *item = &message->body.asset_manifest.items[index];
            write_u16(writer, item->asset_id);
            write_u16(writer, item->width);
            write_u16(writer, item->height);
            write_u32(writer, item->byte_count);
            write_u32(writer, item->crc32);
        }
        break;
    case CR_MESSAGE_ASSET_CHUNK:
        if (message->body.asset_chunk.bytes.length > UINT16_MAX) return CR_ERR_NUMERIC_OVERFLOW;
        write_u32(writer, message->body.asset_chunk.set_id);
        write_u16(writer, message->body.asset_chunk.asset_id);
        write_u32(writer, message->body.asset_chunk.offset);
        write_u16(writer, (uint16_t)message->body.asset_chunk.bytes.length);
        writer_bytes(writer, message->body.asset_chunk.bytes.bytes, message->body.asset_chunk.bytes.length);
        break;
    case CR_MESSAGE_ASSET_ACKNOWLEDGEMENT:
        if (message->body.asset_acknowledgement.result > 3) return CR_ERR_INVALID_PAYLOAD;
        write_u32(writer, message->body.asset_acknowledgement.set_id);
        write_u16(writer, message->body.asset_acknowledgement.asset_id);
        write_u32(writer, message->body.asset_acknowledgement.next_offset);
        write_u8(writer, message->body.asset_acknowledgement.result);
        break;
    case CR_MESSAGE_DEVICE_INFO:
        if (message->body.device_info.protocol_major != CR_PROTOCOL_MAJOR) return CR_ERR_INCOMPATIBLE_VERSION;
        if (message->body.device_info.battery_percent > 100) return CR_ERR_INVALID_PAYLOAD;
        write_u8(writer, message->body.device_info.protocol_major);
        write_u8(writer, message->body.device_info.protocol_minor);
        result = write_string(writer, message->body.device_info.firmware_version, CR_MAX_TITLE_BYTES);
        if (result != CR_OK) return result;
        write_u16(writer, message->body.device_info.capabilities);
        write_u8(writer, message->body.device_info.battery_percent);
        break;
    case CR_MESSAGE_RESYNC_REQUIRED:
        if (message->body.resync_required.reason < 1 || message->body.resync_required.reason > 4) return CR_ERR_INVALID_PAYLOAD;
        write_u8(writer, message->body.resync_required.reason);
        break;
    default:
        return CR_ERR_UNSUPPORTED_MESSAGE;
    }
    return writer->overflow ? CR_ERR_BUFFER_TOO_SMALL : CR_OK;
}

cr_result_t cr_message_encode(
    const cr_message_t *message,
    uint8_t *output,
    size_t output_capacity,
    size_t *written
)
{
    if (message == NULL || written == NULL) return CR_ERR_INVALID_ARGUMENT;
    writer_t sizing = {0};
    cr_result_t result = encode_body(message, &sizing);
    if (result != CR_OK) return result;
    *written = sizing.offset;
    if (output == NULL || output_capacity < sizing.offset) return CR_ERR_BUFFER_TOO_SMALL;
    writer_t writer = {.bytes = output, .capacity = output_capacity};
    result = encode_body(message, &writer);
    if (result != CR_OK) return result;
    *written = writer.offset;
    return CR_OK;
}
