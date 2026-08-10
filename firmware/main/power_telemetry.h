#ifndef CODEX_REMOTE_POWER_TELEMETRY_H
#define CODEX_REMOTE_POWER_TELEMETRY_H

#include "esp_err.h"

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    bool battery_present;
    bool charging;
    uint8_t battery_percent;
    uint16_t battery_voltage_mv;
} cr_power_telemetry_t;

esp_err_t cr_power_telemetry_init(void);
esp_err_t cr_power_telemetry_read(cr_power_telemetry_t *telemetry);

#endif
