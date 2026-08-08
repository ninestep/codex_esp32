#ifndef CODEX_MICRO_VENDOR_FRAME_H
#define CODEX_MICRO_VENDOR_FRAME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CR_MICRO_REPORT_ID UINT8_C(6)
#define CR_MICRO_MESSAGE_TYPE_JSON UINT8_C(2)
#define CR_MICRO_REPORT_BODY_BYTES ((size_t)63)
#define CR_MICRO_PAYLOAD_BYTES ((size_t)61)
#define CR_MICRO_MAX_MESSAGE_BYTES ((size_t)4096)
#define CR_MICRO_HID_REPORT_MAP_BYTES ((size_t)29)

extern const uint8_t cr_micro_hid_report_map[CR_MICRO_HID_REPORT_MAP_BYTES];

typedef enum {
    CR_MICRO_FRAME_OK = 0,
    CR_MICRO_FRAME_NEED_MORE,
    CR_MICRO_FRAME_MESSAGE_READY,
    CR_MICRO_FRAME_INVALID_ARGUMENT,
    CR_MICRO_FRAME_INVALID_REPORT,
    CR_MICRO_FRAME_INVALID_LENGTH,
    CR_MICRO_FRAME_INVALID_UTF8,
    CR_MICRO_FRAME_TOO_LARGE,
} cr_micro_frame_result_t;

typedef struct {
    char message[CR_MICRO_MAX_MESSAGE_BYTES + 1];
    size_t length;
} cr_micro_reassembler_t;

void cr_micro_reassembler_init(cr_micro_reassembler_t *state);
cr_micro_frame_result_t cr_micro_vendor_frame_encode(
    const uint8_t *payload,
    size_t payload_length,
    uint8_t report[CR_MICRO_REPORT_BODY_BYTES]
);
cr_micro_frame_result_t cr_micro_vendor_frame_encode_json_chunk(
    const char *json,
    size_t json_length,
    size_t *offset,
    uint8_t report[CR_MICRO_REPORT_BODY_BYTES],
    bool *done
);
cr_micro_frame_result_t cr_micro_reassembler_push(
    cr_micro_reassembler_t *state,
    const uint8_t *report,
    size_t report_length
);

#endif
