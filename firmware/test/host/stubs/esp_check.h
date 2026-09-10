#ifndef TEST_ESP_CHECK_H
#define TEST_ESP_CHECK_H

#include "esp_err.h"
#include "esp_log.h"

#define ESP_RETURN_ON_ERROR(expression, tag, ...) do { \
    esp_err_t test_result = (expression); \
    if (test_result != ESP_OK) { \
        ESP_LOGE(tag, __VA_ARGS__); \
        return test_result; \
    } \
} while (0)
#define ESP_RETURN_ON_FALSE(condition, error, tag, ...) do { \
    if (!(condition)) { \
        ESP_LOGE(tag, __VA_ARGS__); \
        return (error); \
    } \
} while (0)

#endif
