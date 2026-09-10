#ifndef CR_POWER_LOG_H
#define CR_POWER_LOG_H

#include "power_telemetry.h"

/* 仅 battery_task 写入和导出；初始化阶段也可写入首次采样。 */
esp_err_t cr_power_log_init(void);
void cr_power_log_record(uint64_t uptime_ms, unsigned mode,
                         const cr_power_telemetry_t *sample, esp_err_t result);
void cr_power_log_poll_export(void);

#endif
