#include "codex_remote/input_state.h"

#include <assert.h>
#include <stdio.h>

static cr_input_context_t active_context(void)
{
    return (cr_input_context_t){.detail_active = true, .session_selected = true, .screen_on = true};
}

static void test_short_press_sends_enter_after_double_click_window(void)
{
    cr_input_state_t state;
    cr_input_state_init(&state);
    cr_input_context_t context = active_context();

    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_DOWN, 100) == CR_INPUT_PRE_ROLL_BEGIN);
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_UP, 200) == CR_INPUT_PRE_ROLL_DISCARD);
    assert(cr_input_reduce(&state, context, CR_INPUT_TICK, 449) == CR_INPUT_NONE);
    assert(cr_input_reduce(&state, context, CR_INPUT_TICK, 450) == CR_INPUT_ENTER);
}

static void test_second_short_press_sends_escape(void)
{
    cr_input_state_t state;
    cr_input_state_init(&state);
    cr_input_context_t context = active_context();

    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_DOWN, 100) == CR_INPUT_PRE_ROLL_BEGIN);
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_UP, 180) == CR_INPUT_PRE_ROLL_DISCARD);
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_DOWN, 300) == CR_INPUT_PRE_ROLL_BEGIN);
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_UP, 360) == CR_INPUT_ESCAPE);
    assert(cr_input_reduce(&state, context, CR_INPUT_TICK, 700) == CR_INPUT_NONE);
}

static void test_350_millisecond_hold_becomes_ptt_once(void)
{
    cr_input_state_t state;
    cr_input_state_init(&state);
    cr_input_context_t context = active_context();

    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_DOWN, 1000) == CR_INPUT_PRE_ROLL_BEGIN);
    assert(cr_input_reduce(&state, context, CR_INPUT_TICK, 1349) == CR_INPUT_NONE);
    assert(cr_input_reduce(&state, context, CR_INPUT_TICK, 1350) == CR_INPUT_PTT_BEGIN);
    assert(cr_input_reduce(&state, context, CR_INPUT_TICK, 1400) == CR_INPUT_NONE);
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_UP, 1500) == CR_INPUT_PTT_END);
    assert(cr_input_reduce(&state, context, CR_INPUT_TICK, 1800) == CR_INPUT_NONE);
}

static void test_inactive_detail_and_wake_press_are_consumed(void)
{
    cr_input_state_t state;
    cr_input_state_init(&state);
    cr_input_context_t context = active_context();
    context.detail_active = false;
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_DOWN, 100) == CR_INPUT_NONE);
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_UP, 200) == CR_INPUT_NONE);

    context.detail_active = true;
    context.screen_on = false;
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_DOWN, 500) == CR_INPUT_WAKE);
    context.screen_on = true;
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_UP, 900) == CR_INPUT_NONE);
    assert(cr_input_reduce(&state, context, CR_INPUT_TICK, 1200) == CR_INPUT_NONE);
}

static void test_debounce_ignores_edges_within_twenty_milliseconds(void)
{
    cr_input_state_t state;
    cr_input_state_init(&state);
    cr_input_context_t context = active_context();
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_DOWN, 100) == CR_INPUT_PRE_ROLL_BEGIN);
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_UP, 110) == CR_INPUT_NONE);
    assert(cr_input_reduce(&state, context, CR_INPUT_BUTTON_UP, 130) == CR_INPUT_PRE_ROLL_DISCARD);
}

int main(void)
{
    test_short_press_sends_enter_after_double_click_window();
    test_second_short_press_sends_escape();
    test_350_millisecond_hold_becomes_ptt_once();
    test_inactive_detail_and_wake_press_are_consumed();
    test_debounce_ignores_edges_within_twenty_milliseconds();
    puts("test_input_state: PASS");
    return 0;
}
