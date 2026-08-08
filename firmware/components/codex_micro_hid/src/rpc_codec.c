#include "codex_micro/rpc_codec.h"

#include "cJSON.h"

#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static cr_micro_rpc_result_t print_json(
    cJSON *root,
    char *output,
    size_t capacity,
    size_t *length
)
{
    if (root == NULL || output == NULL || length == NULL || capacity == 0) {
        cJSON_Delete(root);
        return CR_MICRO_RPC_INVALID_REQUEST;
    }
    if (capacity > (size_t)INT_MAX
        || !cJSON_PrintPreallocated(root, output, (int)capacity, false)) {
        cJSON_Delete(root);
        return CR_MICRO_RPC_OUTPUT_TOO_SMALL;
    }
    *length = strlen(output);
    cJSON_Delete(root);
    return CR_MICRO_RPC_OK;
}

static cJSON *make_response(const cJSON *id)
{
    cJSON *response = cJSON_CreateObject();
    if (response == NULL) return NULL;
    cJSON *id_copy = cJSON_Duplicate(id, true);
    if (id_copy == NULL || !cJSON_AddItemToObject(response, "id", id_copy)) {
        cJSON_Delete(id_copy);
        cJSON_Delete(response);
        return NULL;
    }
    return response;
}

static bool parse_uint8(const cJSON *object, const char *name, uint8_t *value)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, name);
    if (item == NULL) return true;
    if (!cJSON_IsNumber(item) || !isfinite(item->valuedouble)
        || item->valuedouble < 0 || item->valuedouble > UINT8_MAX
        || floor(item->valuedouble) != item->valuedouble) return false;
    *value = (uint8_t)item->valuedouble;
    return true;
}

static bool parse_color(const cJSON *object, uint32_t *color)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, "c");
    if (item == NULL) return true;
    if (!cJSON_IsNumber(item) || !isfinite(item->valuedouble)
        || item->valuedouble < 0 || item->valuedouble > UINT32_C(0xffffff)
        || floor(item->valuedouble) != item->valuedouble) return false;
    *color = (uint32_t)item->valuedouble;
    return true;
}

static bool parse_unit_value(const cJSON *object, const char *name, uint8_t *value)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, name);
    if (item == NULL) return true;
    if (!cJSON_IsNumber(item) || !isfinite(item->valuedouble)
        || item->valuedouble < 0 || item->valuedouble > 1) return false;
    *value = (uint8_t)lround(item->valuedouble * UINT8_MAX);
    return true;
}

static bool parse_boolean(const cJSON *object, const char *name, bool *value)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, name);
    if (item == NULL) return true;
    if (cJSON_IsBool(item)) {
        *value = cJSON_IsTrue(item);
        return true;
    }
    if (cJSON_IsNumber(item)
        && (item->valuedouble == 0 || item->valuedouble == 1)) {
        *value = item->valuedouble == 1;
        return true;
    }
    return false;
}

static bool parse_light(
    const cJSON *object,
    const cr_micro_light_t *current,
    cr_micro_light_t *light
)
{
    if (!cJSON_IsObject(object) || light == NULL) return false;
    *light = current == NULL ? (cr_micro_light_t){0} : *current;
    if (!parse_color(object, &light->color)
        || !parse_unit_value(object, "b", &light->brightness)
        || !parse_uint8(object, "e", &light->effect)
        || !parse_unit_value(object, "s", &light->speed)
        || !parse_uint8(object, "m", &light->magic)
        || !parse_boolean(object, "sk", &light->sync_keys)
        || !parse_boolean(object, "sa", &light->sync_ambient)) return false;
    light->configured = true;
    return true;
}

static bool add_success(cJSON *output)
{
    return cJSON_AddBoolToObject(output, "result", true) != NULL;
}

static cr_micro_rpc_result_t encode_hid_key(
    const char *key,
    uint8_t action,
    int agent_index,
    char *json,
    size_t capacity,
    size_t *length
)
{
    if (key == NULL || json == NULL || length == NULL) {
        return CR_MICRO_RPC_INVALID_REQUEST;
    }
    cJSON *root = cJSON_CreateObject();
    cJSON *params = cJSON_CreateObject();
    if (root == NULL || params == NULL
        || !cJSON_AddStringToObject(root, "method", "v.oai.hid")
        || !cJSON_AddStringToObject(params, "k", key)
        || !cJSON_AddNumberToObject(params, "act", action)
        || (agent_index >= 0
            && !cJSON_AddNumberToObject(params, "ag", agent_index))
        || !cJSON_AddItemToObject(root, "params", params)) {
        cJSON_Delete(params);
        cJSON_Delete(root);
        return CR_MICRO_RPC_OUTPUT_TOO_SMALL;
    }
    return print_json(root, json, capacity, length);
}

cr_micro_rpc_result_t cr_micro_rpc_respond(
    const char *json,
    size_t json_length,
    uint8_t battery_percent,
    bool charging,
    char *response,
    size_t response_capacity,
    size_t *response_length
)
{
    return cr_micro_rpc_respond_with_state(
        json,
        json_length,
        battery_percent,
        charging,
        NULL,
        NULL,
        response,
        response_capacity,
        response_length
    );
}

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
)
{
    if (state_changed != NULL) *state_changed = false;
    if (json == NULL || json_length == 0 || response == NULL || response_length == NULL) {
        return CR_MICRO_RPC_INVALID_REQUEST;
    }
    const char *parse_end = NULL;
    cJSON *request = cJSON_ParseWithLengthOpts(json, json_length, &parse_end, false);
    if (request == NULL || parse_end != json + json_length) {
        cJSON_Delete(request);
        return CR_MICRO_RPC_INVALID_JSON;
    }
    const cJSON *method = cJSON_GetObjectItemCaseSensitive(request, "method");
    const cJSON *id = cJSON_GetObjectItemCaseSensitive(request, "id");
    bool valid_id = cJSON_IsString(id) || cJSON_IsNumber(id) || cJSON_IsNull(id);
    if (!cJSON_IsObject(request) || !cJSON_IsString(method)
        || method->valuestring == NULL || !valid_id) {
        cJSON_Delete(request);
        return CR_MICRO_RPC_INVALID_REQUEST;
    }

    cJSON *output = make_response(id);
    if (output == NULL) {
        cJSON_Delete(request);
        return CR_MICRO_RPC_OUTPUT_TOO_SMALL;
    }
    cr_micro_rpc_result_t result = CR_MICRO_RPC_OK;
    if (strcmp(method->valuestring, "sys.version") == 0) {
        cJSON *value = cJSON_CreateObject();
        if (value == NULL
            || !cJSON_AddStringToObject(value, "version", CR_MICRO_FIRMWARE_VERSION)
            || !cJSON_AddItemToObject(output, "result", value)) {
            cJSON_Delete(value);
            cJSON_Delete(output);
            cJSON_Delete(request);
            return CR_MICRO_RPC_OUTPUT_TOO_SMALL;
        }
    } else if (strcmp(method->valuestring, "device.status") == 0) {
        cJSON *value = cJSON_CreateObject();
        uint8_t bounded_battery = battery_percent > 100 ? 100 : battery_percent;
        if (value == NULL
            || !cJSON_AddStringToObject(value, "version", CR_MICRO_FIRMWARE_VERSION)
            || !cJSON_AddNumberToObject(value, "profile_index", 0)
            || !cJSON_AddNumberToObject(value, "layer_index", 1)
            || !cJSON_AddNumberToObject(value, "battery", bounded_battery)
            || !cJSON_AddBoolToObject(value, "is_charging", charging)
            || !cJSON_AddItemToObject(output, "result", value)) {
            cJSON_Delete(value);
            cJSON_Delete(output);
            cJSON_Delete(request);
            return CR_MICRO_RPC_OUTPUT_TOO_SMALL;
        }
    } else if (strcmp(method->valuestring, "v.oai.rgbcfg") == 0) {
        const cJSON *params = cJSON_GetObjectItemCaseSensitive(request, "params");
        const cJSON *ambient_json = cJSON_GetObjectItemCaseSensitive(params, "ambient");
        const cJSON *keys_json = cJSON_GetObjectItemCaseSensitive(params, "keys");
        cr_micro_light_t ambient;
        cr_micro_light_t keys;
        if (!cJSON_IsObject(params) || !parse_light(
                ambient_json, state == NULL ? NULL : &state->ambient, &ambient
            )
            || !parse_light(keys_json, state == NULL ? NULL : &state->keys, &keys)) {
            cJSON_Delete(output);
            cJSON_Delete(request);
            return CR_MICRO_RPC_INVALID_REQUEST;
        }
        if (state != NULL) {
            bool changed = cr_micro_state_set_global_lighting(state, &keys, &ambient);
            if (state_changed != NULL) *state_changed = changed;
        }
        if (!add_success(output)) {
            cJSON_Delete(output);
            cJSON_Delete(request);
            return CR_MICRO_RPC_OUTPUT_TOO_SMALL;
        }
    } else if (strcmp(method->valuestring, "v.oai.thstatus") == 0) {
        const cJSON *params = cJSON_GetObjectItemCaseSensitive(request, "params");
        cr_micro_state_t staged;
        if (!cJSON_IsArray(params)) {
            cJSON_Delete(output);
            cJSON_Delete(request);
            return CR_MICRO_RPC_INVALID_REQUEST;
        }
        if (state != NULL) staged = *state;
        const cJSON *item = NULL;
        cJSON_ArrayForEach(item, params) {
            const cJSON *id_item = cJSON_GetObjectItemCaseSensitive(item, "id");
            if (!cJSON_IsObject(item) || !cJSON_IsNumber(id_item)
                || !isfinite(id_item->valuedouble) || id_item->valuedouble < 0
                || id_item->valuedouble >= CR_MICRO_SLOT_COUNT
                || floor(id_item->valuedouble) != id_item->valuedouble) {
                cJSON_Delete(output);
                cJSON_Delete(request);
                return CR_MICRO_RPC_INVALID_REQUEST;
            }
            uint8_t index = (uint8_t)id_item->valuedouble;
            cr_micro_light_t light;
            const cr_micro_light_t *current = state == NULL ? NULL : &staged.slots[index];
            if (!parse_light(item, current, &light)) {
                cJSON_Delete(output);
                cJSON_Delete(request);
                return CR_MICRO_RPC_INVALID_REQUEST;
            }
            if (state != NULL) (void)cr_micro_state_set_slot(&staged, index, &light);
        }
        if (state != NULL && memcmp(state, &staged, sizeof(staged)) != 0) {
            *state = staged;
            if (state_changed != NULL) *state_changed = true;
        }
        if (!add_success(output)) {
            cJSON_Delete(output);
            cJSON_Delete(request);
            return CR_MICRO_RPC_OUTPUT_TOO_SMALL;
        }
    } else if (strcmp(method->valuestring, "host.focused_app") == 0) {
        if (!cJSON_IsObject(cJSON_GetObjectItemCaseSensitive(request, "params"))
            || !add_success(output)) {
            cJSON_Delete(output);
            cJSON_Delete(request);
            return CR_MICRO_RPC_INVALID_REQUEST;
        }
    } else {
        cJSON *error = cJSON_CreateObject();
        if (error == NULL
            || !cJSON_AddNumberToObject(error, "code", -32601)
            || !cJSON_AddStringToObject(error, "message", "Method not found")
            || !cJSON_AddItemToObject(output, "error", error)) {
            cJSON_Delete(error);
            cJSON_Delete(output);
            cJSON_Delete(request);
            return CR_MICRO_RPC_OUTPUT_TOO_SMALL;
        }
        result = CR_MICRO_RPC_METHOD_NOT_FOUND;
    }
    cJSON_Delete(request);

    cr_micro_rpc_result_t print_result = print_json(
        output, response, response_capacity, response_length
    );
    return print_result == CR_MICRO_RPC_OK ? result : print_result;
}

cr_micro_rpc_result_t cr_micro_rpc_encode_agent_key(
    uint8_t agent_index,
    bool pressed,
    char *json,
    size_t capacity,
    size_t *length
)
{
    if (agent_index >= 6 || json == NULL || length == NULL) {
        return CR_MICRO_RPC_INVALID_REQUEST;
    }
    char key[5];
    int written = snprintf(key, sizeof(key), "AG%02u", (unsigned)agent_index);
    if (written != 4) return CR_MICRO_RPC_OUTPUT_TOO_SMALL;
    return encode_hid_key(key, pressed ? 1 : 0, agent_index, json, capacity, length);
}

cr_micro_rpc_result_t cr_micro_rpc_encode_control_key(
    cr_micro_control_t control,
    bool pressed,
    char *json,
    size_t capacity,
    size_t *length
)
{
    static const char *const keys[] = {
        "ACT06", "ACT07", "ACT08", "ACT09", "ACT10", "ACT12",
    };
    if (control < CR_MICRO_CONTROL_FAST || control > CR_MICRO_CONTROL_SEND) {
        return CR_MICRO_RPC_INVALID_REQUEST;
    }
    return encode_hid_key(
        keys[control], pressed ? 1 : 0, -1, json, capacity, length
    );
}

cr_micro_rpc_result_t cr_micro_rpc_encode_encoder(
    cr_micro_encoder_action_t action,
    char *json,
    size_t capacity,
    size_t *length
)
{
    static const char *const keys[] = {"ENC_PRESS", "ENC_CW", "ENC_CC"};
    if (action < CR_MICRO_ENCODER_PRESS
        || action > CR_MICRO_ENCODER_COUNTERCLOCKWISE) {
        return CR_MICRO_RPC_INVALID_REQUEST;
    }
    uint8_t act = action == CR_MICRO_ENCODER_PRESS ? 1 : 2;
    return encode_hid_key(keys[action], act, -1, json, capacity, length);
}

cr_micro_rpc_result_t cr_micro_rpc_encode_direction(
    cr_micro_direction_t direction,
    bool pressed,
    char *json,
    size_t capacity,
    size_t *length
)
{
    static const uint16_t angles[] = {90, 0, 270, 180};
    if (direction < CR_MICRO_DIRECTION_UP || direction > CR_MICRO_DIRECTION_LEFT
        || json == NULL || length == NULL) return CR_MICRO_RPC_INVALID_REQUEST;
    cJSON *root = cJSON_CreateObject();
    cJSON *params = cJSON_CreateObject();
    if (root == NULL || params == NULL
        || !cJSON_AddStringToObject(root, "method", "v.oai.rad")
        || !cJSON_AddNumberToObject(params, "a", angles[direction])
        || !cJSON_AddNumberToObject(params, "d", pressed ? 1 : 0)
        || !cJSON_AddItemToObject(root, "params", params)) {
        cJSON_Delete(params);
        cJSON_Delete(root);
        return CR_MICRO_RPC_OUTPUT_TOO_SMALL;
    }
    return print_json(root, json, capacity, length);
}
