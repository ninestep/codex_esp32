#include "codex_remote/connection_mode_store.h"

#include "nvs.h"

#include <stdint.h>

#define CR_CONNECTION_MODE_NAMESPACE "cr_runtime"
#define CR_CONNECTION_MODE_SCHEMA_KEY "schema"
#define CR_CONNECTION_MODE_VALUE_KEY "mode"
#define CR_CONNECTION_MODE_SCHEMA_VERSION 1

esp_err_t cr_connection_mode_store_load(cr_connection_mode_t *mode)
{
    if (mode == NULL) return ESP_ERR_INVALID_ARG;
    *mode = CR_CONNECTION_MODE_UNCONFIGURED;

    nvs_handle_t handle;
    esp_err_t result = nvs_open(CR_CONNECTION_MODE_NAMESPACE, NVS_READONLY, &handle);
    if (result == ESP_ERR_NVS_NOT_FOUND) return ESP_OK;
    if (result != ESP_OK) return result;

    uint8_t schema = 0;
    uint8_t stored_mode = 0;
    result = nvs_get_u8(handle, CR_CONNECTION_MODE_SCHEMA_KEY, &schema);
    if (result == ESP_OK) {
        result = nvs_get_u8(handle, CR_CONNECTION_MODE_VALUE_KEY, &stored_mode);
    }
    nvs_close(handle);

    if (result != ESP_OK) return result;
    if (schema != CR_CONNECTION_MODE_SCHEMA_VERSION
        || !cr_connection_mode_is_valid(stored_mode)) {
        return ESP_ERR_INVALID_STATE;
    }

    *mode = (cr_connection_mode_t)stored_mode;
    return ESP_OK;
}

esp_err_t cr_connection_mode_store_save(cr_connection_mode_t mode)
{
    if (!cr_connection_mode_is_valid((uint8_t)mode)) return ESP_ERR_INVALID_ARG;

    nvs_handle_t handle;
    esp_err_t result = nvs_open(CR_CONNECTION_MODE_NAMESPACE, NVS_READWRITE, &handle);
    if (result != ESP_OK) return result;

    result = nvs_set_u8(handle, CR_CONNECTION_MODE_SCHEMA_KEY, CR_CONNECTION_MODE_SCHEMA_VERSION);
    if (result == ESP_OK) {
        result = nvs_set_u8(handle, CR_CONNECTION_MODE_VALUE_KEY, (uint8_t)mode);
    }
    if (result == ESP_OK) result = nvs_commit(handle);
    nvs_close(handle);
    return result;
}
