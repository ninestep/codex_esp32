#ifndef CODEX_REMOTE_INPUT_STATE_H
#define CODEX_REMOTE_INPUT_STATE_H

#include <stdbool.h>
#include <stdint.h>

#define CR_INPUT_DEBOUNCE_MS UINT64_C(20)
#define CR_INPUT_HOLD_MS UINT64_C(350)
#define CR_INPUT_DOUBLE_CLICK_MS UINT64_C(250)

typedef enum {
    CR_INPUT_BUTTON_DOWN = 0,
    CR_INPUT_BUTTON_UP,
    CR_INPUT_TICK,
} cr_input_event_t;

typedef enum {
    CR_INPUT_NONE = 0,
    CR_INPUT_PRE_ROLL_BEGIN,
    CR_INPUT_PRE_ROLL_DISCARD,
    CR_INPUT_ENTER,
    CR_INPUT_ESCAPE,
    CR_INPUT_PTT_BEGIN,
    CR_INPUT_PTT_END,
    CR_INPUT_WAKE,
} cr_input_action_t;

typedef struct {
    bool detail_active;
    bool session_selected;
    bool screen_on;
    bool interaction_locked;
} cr_input_context_t;

typedef struct {
    bool button_down;
    bool consume_until_release;
    bool ptt_started;
    bool waiting_for_second_click;
    bool second_click_down;
    bool has_last_edge;
    uint64_t press_started_at;
    uint64_t first_release_at;
    uint64_t last_edge_at;
} cr_input_state_t;

void cr_input_state_init(cr_input_state_t *state);
cr_input_action_t cr_input_reduce(
    cr_input_state_t *state,
    cr_input_context_t context,
    cr_input_event_t event,
    uint64_t now_ms
);

#endif
