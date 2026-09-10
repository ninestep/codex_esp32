#ifndef TEST_ESP_LOG_H
#define TEST_ESP_LOG_H

void test_esp_log(const char *tag, const char *format, ...)
    __attribute__((format(printf, 2, 3)));
#define ESP_LOGI test_esp_log
#define ESP_LOGW test_esp_log
#define ESP_LOGE test_esp_log

#endif
