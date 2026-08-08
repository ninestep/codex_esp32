#ifndef CODEX_REMOTE_CONNECTION_MODE_STORE_H
#define CODEX_REMOTE_CONNECTION_MODE_STORE_H

#include "codex_remote/connection_mode.h"

#include "esp_err.h"

esp_err_t cr_connection_mode_store_load(cr_connection_mode_t *mode);
esp_err_t cr_connection_mode_store_save(cr_connection_mode_t mode);

#endif
