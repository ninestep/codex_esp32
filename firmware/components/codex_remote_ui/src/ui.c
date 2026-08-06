#include "codex_remote/ui.h"

#include "lvgl.h"
#include <stdio.h>
#include <string.h>

typedef struct {
    lv_obj_t *card;
    lv_obj_t *dot;
    lv_obj_t *title;
    lv_obj_t *directory;
    lv_obj_t *status;
    uint16_t session_key;
    bool active;
} card_view_t;

static cr_ui_callbacks_t actions;
static lv_obj_t *home_page;
static lv_obj_t *detail_page;
static lv_obj_t *screensaver_page;
static lv_obj_t *connection_label;
static lv_obj_t *detail_title;
static lv_obj_t *detail_directory;
static lv_obj_t *detail_status;
static card_view_t cards[CR_MAX_SESSIONS];
static uint16_t selected_session_key;
static bool interaction_locked;

static void note_interaction(void)
{
    if (actions.interaction != NULL) actions.interaction(actions.context);
}

static lv_color_t state_color(uint8_t state)
{
    switch (state) {
    case 0: return lv_color_hex(0xf4f4f5);
    case 1: return lv_color_hex(0x3b82f6);
    case 2: return lv_color_hex(0x22c55e);
    case 3: return lv_color_hex(0xf59e0b);
    case 4: return lv_color_hex(0xef4444);
    default: return lv_color_hex(0x71717a);
    }
}

static const char *state_text(uint8_t state)
{
    switch (state) {
    case 0: return "IDLE";
    case 1: return "THINKING";
    case 2: return "DONE";
    case 3: return "INPUT";
    case 4: return "ERROR";
    default: return "OFFLINE";
    }
}

static void card_clicked(lv_event_t *event)
{
    note_interaction();
    if (interaction_locked) return;
    card_view_t *card = lv_event_get_user_data(event);
    if (card->active && actions.select_session != NULL) {
        actions.select_session(card->session_key, actions.context);
    }
}

static void back_clicked(lv_event_t *event)
{
    (void)event;
    note_interaction();
    if (interaction_locked) return;
    lv_obj_add_flag(detail_page, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(home_page, LV_OBJ_FLAG_HIDDEN);
}

static void key_clicked(lv_event_t *event)
{
    note_interaction();
    if (interaction_locked) return;
    if (actions.terminal_key == NULL || selected_session_key == 0) return;
    uintptr_t key = (uintptr_t)lv_event_get_user_data(event);
    actions.terminal_key(selected_session_key, (uint8_t)key, actions.context);
}

static int32_t detail_press_y;

static void detail_pointer(lv_event_t *event)
{
    lv_point_t point;
    lv_indev_get_point(lv_indev_active(), &point);
    if (lv_event_get_code(event) == LV_EVENT_PRESSED) {
        detail_press_y = point.y;
        return;
    }

    note_interaction();
    if (interaction_locked) return;
    if (actions.scroll == NULL || selected_session_key == 0) return;
    int32_t delta_y = point.y - detail_press_y;
    if (delta_y < -24) actions.scroll(selected_session_key, 120, actions.context);
    else if (delta_y > 24) actions.scroll(selected_session_key, -120, actions.context);
}

static lv_obj_t *make_button(lv_obj_t *parent, const char *text)
{
    lv_obj_t *button = lv_button_create(parent);
    lv_obj_set_height(button, 54);
    lv_obj_t *label = lv_label_create(button);
    lv_label_set_text(label, text);
    lv_obj_center(label);
    return button;
}

static void screensaver_pressed(lv_event_t *event)
{
    (void)event;
    note_interaction();
}

void cr_ui_init(const cr_ui_callbacks_t *config)
{
    actions = *config;
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(0x09090b), 0);
    lv_obj_set_style_text_color(screen, lv_color_hex(0xfafafa), 0);

    home_page = lv_obj_create(screen);
    lv_obj_remove_style_all(home_page);
    lv_obj_set_size(home_page, LV_PCT(100), LV_PCT(100));

    lv_obj_t *heading = lv_label_create(home_page);
    lv_label_set_text(heading, "CODEX REMOTE");
    lv_obj_align(heading, LV_ALIGN_TOP_LEFT, 18, 16);

    connection_label = lv_label_create(home_page);
    lv_label_set_text(connection_label, "Waiting for Mac...");
    lv_obj_set_style_text_color(connection_label, lv_color_hex(0xa1a1aa), 0);
    lv_obj_align(connection_label, LV_ALIGN_TOP_RIGHT, -18, 20);

    lv_obj_t *list = lv_obj_create(home_page);
    lv_obj_set_size(list, 460, 402);
    lv_obj_align(list, LV_ALIGN_BOTTOM_MID, 0, -8);
    lv_obj_set_style_bg_opa(list, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(list, 0, 0);
    lv_obj_set_style_pad_all(list, 4, 0);
    lv_obj_set_scroll_dir(list, LV_DIR_VER);
    lv_obj_set_scroll_snap_y(list, LV_SCROLL_SNAP_START);

    for (size_t index = 0; index < CR_MAX_SESSIONS; index++) {
        card_view_t *card = &cards[index];
        card->card = lv_button_create(list);
        lv_obj_set_size(card->card, 214, 184);
        lv_obj_set_pos(card->card, (index % 2) * 224, (index / 2) * 194);
        lv_obj_set_style_bg_color(card->card, lv_color_hex(0x18181b), 0);
        lv_obj_set_style_radius(card->card, 18, 0);
        lv_obj_add_event_cb(card->card, card_clicked, LV_EVENT_CLICKED, card);

        card->dot = lv_obj_create(card->card);
        lv_obj_remove_style_all(card->dot);
        lv_obj_set_size(card->dot, 12, 12);
        lv_obj_set_style_radius(card->dot, LV_RADIUS_CIRCLE, 0);
        lv_obj_align(card->dot, LV_ALIGN_TOP_LEFT, 0, 2);

        card->status = lv_label_create(card->card);
        lv_obj_align(card->status, LV_ALIGN_TOP_RIGHT, 0, 0);

        card->title = lv_label_create(card->card);
        lv_obj_set_width(card->title, 182);
        lv_label_set_long_mode(card->title, LV_LABEL_LONG_DOT);
        lv_obj_align(card->title, LV_ALIGN_TOP_LEFT, 0, 38);

        card->directory = lv_label_create(card->card);
        lv_obj_set_width(card->directory, 182);
        lv_label_set_long_mode(card->directory, LV_LABEL_LONG_DOT);
        lv_obj_set_style_text_color(card->directory, lv_color_hex(0xa1a1aa), 0);
        lv_obj_align(card->directory, LV_ALIGN_BOTTOM_LEFT, 0, -4);
        lv_obj_add_flag(card->card, LV_OBJ_FLAG_HIDDEN);
    }

    detail_page = lv_obj_create(screen);
    lv_obj_remove_style_all(detail_page);
    lv_obj_set_size(detail_page, LV_PCT(100), LV_PCT(100));
    lv_obj_add_flag(detail_page, LV_OBJ_FLAG_HIDDEN);

    lv_obj_t *back = make_button(detail_page, "BACK");
    lv_obj_set_size(back, 90, 46);
    lv_obj_align(back, LV_ALIGN_TOP_LEFT, 14, 14);
    lv_obj_add_event_cb(back, back_clicked, LV_EVENT_CLICKED, NULL);

    detail_title = lv_label_create(detail_page);
    lv_obj_set_width(detail_title, 330);
    lv_label_set_long_mode(detail_title, LV_LABEL_LONG_DOT);
    lv_obj_align(detail_title, LV_ALIGN_TOP_LEFT, 120, 16);

    detail_directory = lv_label_create(detail_page);
    lv_obj_set_width(detail_directory, 330);
    lv_label_set_long_mode(detail_directory, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_color(detail_directory, lv_color_hex(0xa1a1aa), 0);
    lv_obj_align(detail_directory, LV_ALIGN_TOP_LEFT, 120, 45);

    lv_obj_t *gesture = lv_obj_create(detail_page);
    lv_obj_set_size(gesture, 450, 270);
    lv_obj_align(gesture, LV_ALIGN_CENTER, 0, -10);
    lv_obj_set_style_bg_color(gesture, lv_color_hex(0x18181b), 0);
    lv_obj_set_style_radius(gesture, 18, 0);
    lv_obj_add_event_cb(gesture, detail_pointer, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(gesture, detail_pointer, LV_EVENT_RELEASED, NULL);
    detail_status = lv_label_create(gesture);
    lv_obj_set_width(detail_status, 410);
    lv_label_set_long_mode(detail_status, LV_LABEL_LONG_WRAP);
    lv_obj_center(detail_status);

    lv_obj_t *escape = make_button(detail_page, "CANCEL  ESC");
    lv_obj_set_size(escape, 216, 58);
    lv_obj_align(escape, LV_ALIGN_BOTTOM_LEFT, 14, -14);
    lv_obj_add_event_cb(escape, key_clicked, LV_EVENT_CLICKED, (void *)(uintptr_t)2);

    lv_obj_t *enter = make_button(detail_page, "CONFIRM  ENTER");
    lv_obj_set_size(enter, 230, 58);
    lv_obj_align(enter, LV_ALIGN_BOTTOM_RIGHT, -14, -14);
    lv_obj_add_event_cb(enter, key_clicked, LV_EVENT_CLICKED, (void *)(uintptr_t)1);

    screensaver_page = lv_obj_create(screen);
    lv_obj_remove_style_all(screensaver_page);
    lv_obj_set_size(screensaver_page, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_bg_color(screensaver_page, lv_color_hex(0x050508), 0);
    lv_obj_set_style_bg_opa(screensaver_page, LV_OPA_COVER, 0);
    lv_obj_add_flag(screensaver_page, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(screensaver_page, screensaver_pressed, LV_EVENT_PRESSED, NULL);
    lv_obj_t *saver_title = lv_label_create(screensaver_page);
    lv_label_set_text(saver_title, "CODEX");
    lv_obj_set_style_text_color(saver_title, lv_color_hex(0x3b82f6), 0);
    lv_obj_align(saver_title, LV_ALIGN_CENTER, 0, -24);
    lv_obj_t *saver_subtitle = lv_label_create(screensaver_page);
    lv_label_set_text(saver_subtitle, "REMOTE READY");
    lv_obj_set_style_text_color(saver_subtitle, lv_color_hex(0x71717a), 0);
    lv_obj_align(saver_subtitle, LV_ALIGN_CENTER, 0, 32);
    lv_obj_add_flag(screensaver_page, LV_OBJ_FLAG_HIDDEN);
}

void cr_ui_update(const cr_device_state_t *state)
{
    interaction_locked = state->ptt_active;
    lv_label_set_text(connection_label, state->has_snapshot ? "Mac connected" : "Waiting for Mac...");
    for (size_t index = 0; index < CR_MAX_SESSIONS; index++) {
        card_view_t *card = &cards[index];
        if (index >= state->session_count) {
            card->active = false;
            lv_obj_add_flag(card->card, LV_OBJ_FLAG_HIDDEN);
            continue;
        }
        const cr_device_session_t *session = &state->sessions[index];
        card->active = true;
        card->session_key = session->session_key;
        lv_label_set_text(card->title, session->display_title);
        lv_label_set_text(card->directory, session->working_directory_label);
        lv_label_set_text(card->status, state_text(session->state));
        lv_obj_set_style_text_color(card->status, state_color(session->state), 0);
        lv_obj_set_style_bg_color(card->dot, state_color(session->state), 0);
        lv_obj_remove_flag(card->card, LV_OBJ_FLAG_HIDDEN);
    }

    if (!state->has_selection) {
        selected_session_key = 0;
        lv_obj_add_flag(detail_page, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(home_page, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    for (size_t index = 0; index < state->session_count; index++) {
        const cr_device_session_t *session = &state->sessions[index];
        if (session->session_key != state->selected_session_key) continue;
        selected_session_key = session->session_key;
        lv_label_set_text(detail_title, session->display_title);
        lv_label_set_text(detail_directory, session->working_directory_label);
        lv_label_set_text(detail_status, session->status_detail[0] == '\0' ? state_text(session->state) : session->status_detail);
        lv_obj_add_flag(home_page, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(detail_page, LV_OBJ_FLAG_HIDDEN);
        return;
    }
}

void cr_ui_set_power(cr_power_mode_t mode, size_t asset_index)
{
    (void)asset_index;
    if (mode == CR_POWER_SCREENSAVER || mode == CR_POWER_OFF) {
        lv_obj_remove_flag(screensaver_page, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(screensaver_page, LV_OBJ_FLAG_HIDDEN);
    }
}
