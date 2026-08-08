idf_component_register(
    SRCS "src/connection_mode_store.c"
    INCLUDE_DIRS "include"
    REQUIRES codex_remote_core nvs_flash
)

target_compile_features(${COMPONENT_LIB} PUBLIC c_std_17)
