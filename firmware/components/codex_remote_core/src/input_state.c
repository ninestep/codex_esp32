#include "codex_remote/input_state.h"

#include <string.h>

void cr_input_state_init(cr_input_state_t *state)
{
    memset(state, 0, sizeof(*state));
}

static bool edge_is_debounced(cr_input_state_t *state, uint64_t now_ms)
{
    if (state->has_last_edge && now_ms - state->last_edge_at < CR_INPUT_DEBOUNCE_MS) {
        return true;
    }
    state->has_last_edge = true;
    state->last_edge_at = now_ms;
    return false;
}

static bool context_allows_input(cr_input_context_t context)
{
    return context.detail_active && context.session_selected && !context.interaction_locked;
}

static cr_input_action_t handle_down(
    cr_input_state_t *state,
    cr_input_context_t context,
    uint64_t now_ms
)
{
    if (edge_is_debounced(state, now_ms) || state->button_down) return CR_INPUT_NONE;
    state->button_down = true;
    state->press_started_at = now_ms;

    if (!context.screen_on) {
        state->consume_until_release = true;
        state->waiting_for_second_click = false;
        state->second_click_down = false;
        return CR_INPUT_WAKE;
    }
    if (!context_allows_input(context)) {
        state->consume_until_release = true;
        return CR_INPUT_NONE;
    }

    state->second_click_down = state->waiting_for_second_click
        && now_ms - state->first_release_at <= CR_INPUT_DOUBLE_CLICK_MS;
    return CR_INPUT_PRE_ROLL_BEGIN;
}

static cr_input_action_t handle_up(
    cr_input_state_t *state,
    cr_input_context_t context,
    uint64_t now_ms
)
{
    if (edge_is_debounced(state, now_ms) || !state->button_down) return CR_INPUT_NONE;
    state->button_down = false;

    if (state->consume_until_release) {
        state->consume_until_release = false;
        state->ptt_started = false;
        state->second_click_down = false;
        return CR_INPUT_NONE;
    }
    if (state->ptt_started) {
        state->ptt_started = false;
        state->waiting_for_second_click = false;
        state->second_click_down = false;
        return CR_INPUT_PTT_END;
    }
    if (!context_allows_input(context)) {
        state->waiting_for_second_click = false;
        state->second_click_down = false;
        return CR_INPUT_PRE_ROLL_DISCARD;
    }
    if (state->second_click_down) {
        state->waiting_for_second_click = false;
        state->second_click_down = false;
        return CR_INPUT_ESCAPE;
    }

    state->waiting_for_second_click = true;
    state->first_release_at = now_ms;
    return CR_INPUT_PRE_ROLL_DISCARD;
}

static cr_input_action_t handle_tick(
    cr_input_state_t *state,
    cr_input_context_t context,
    uint64_t now_ms
)
{
    if (state->button_down && !state->consume_until_release && !state->ptt_started
        && context_allows_input(context)
        && now_ms - state->press_started_at >= CR_INPUT_HOLD_MS) {
        state->ptt_started = true;
        state->waiting_for_second_click = false;
        state->second_click_down = false;
        return CR_INPUT_PTT_BEGIN;
    }
    if (!state->button_down && state->waiting_for_second_click
        && now_ms - state->first_release_at >= CR_INPUT_DOUBLE_CLICK_MS) {
        state->waiting_for_second_click = false;
        return context_allows_input(context) ? CR_INPUT_ENTER : CR_INPUT_NONE;
    }
    return CR_INPUT_NONE;
}

cr_input_action_t cr_input_reduce(
    cr_input_state_t *state,
    cr_input_context_t context,
    cr_input_event_t event,
    uint64_t now_ms
)
{
    if (state == NULL) return CR_INPUT_NONE;
    switch (event) {
    case CR_INPUT_BUTTON_DOWN:
        return handle_down(state, context, now_ms);
    case CR_INPUT_BUTTON_UP:
        return handle_up(state, context, now_ms);
    case CR_INPUT_TICK:
        return handle_tick(state, context, now_ms);
    }
    return CR_INPUT_NONE;
}
