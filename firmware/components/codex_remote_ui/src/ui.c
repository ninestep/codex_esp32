#include "codex_remote/ui.h"
#include "codex_micro/agent_status.h"

#include "lvgl.h"

LV_FONT_DECLARE(codex_remote_font_16);

typedef struct {
    lv_obj_t *card;
    lv_obj_t *title;
    lv_obj_t *directory;
    lv_obj_t *status;
    uint16_t session_key;
    uint8_t state;
    lv_color_t status_color;
    bool active;
} card_view_t;

typedef enum {
    MICRO_VIEW_ACTIONS = 0,
    MICRO_VIEW_ENCODER,
    MICRO_VIEW_JOYSTICK,
} micro_view_t;

static cr_ui_callbacks_t actions;
static lv_obj_t *home_page;
static lv_obj_t *detail_page;
static lv_obj_t *detail_content_page;
static lv_obj_t *shortcut_page;
static lv_obj_t *screensaver_page;
static lv_obj_t *mode_page;
static lv_obj_t *micro_action_page;
static lv_obj_t *micro_action_title;
static lv_obj_t *micro_action_status;
static lv_obj_t *micro_action_menu;
static lv_obj_t *micro_encoder_panel;
static lv_obj_t *micro_encoder_ring;
static lv_obj_t *micro_joystick_panel;
static lv_obj_t *mode_choices;
static lv_obj_t *mode_confirmation;
static lv_obj_t *mode_confirmation_label;
static lv_obj_t *home_heading;
static lv_obj_t *connection_label;
static lv_obj_t *detail_title;
static lv_obj_t *detail_directory;
static lv_obj_t *detail_status;
static lv_obj_t *page_toggle;
static lv_obj_t *page_toggle_label;
static card_view_t cards[CR_MAX_SESSIONS];
static uint16_t selected_session_key;
static uint16_t suppressed_session_key;
static bool interaction_locked;
static bool shortcut_page_active;
static bool micro_mode_active;
static bool micro_connected;
static bool micro_action_page_active;
static uint8_t selected_micro_agent = UINT8_MAX;
static int8_t pressed_micro_control = -1;
static int8_t pressed_micro_direction = -1;
static bool pressed_micro_encoder;
static micro_view_t micro_view = MICRO_VIEW_ACTIONS;

static void note_interaction(void)
{
    if (actions.interaction != NULL) actions.interaction(actions.context);
}

static lv_color_t state_background_color(uint8_t state)
{
    switch (state) {
    case 0: return lv_color_hex(0x27272a);
    case 1: return lv_color_hex(0x172d55);
    case 2: return lv_color_hex(0x153724);
    case 3: return lv_color_hex(0x4a3011);
    case 4: return lv_color_hex(0x4a1f23);
    default: return lv_color_hex(0x27272a);
    }
}

static lv_color_t state_border_color(uint8_t state)
{
    switch (state) {
    case 0: return lv_color_hex(0xa1a1aa);
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
    case 0: return "空闲";
    case 1: return "正在处理";
    case 2: return "已完成";
    case 3: return "需要输入";
    case 4: return "错误";
    default: return "离线";
    }
}

static uint8_t micro_light_state(const cr_micro_light_t *light)
{
    return (uint8_t)cr_micro_agent_status(light);
}

static lv_obj_t *make_button(lv_obj_t *parent, const char *text)
{
    lv_obj_t *button = lv_button_create(parent);
    lv_obj_set_height(button, 52);
    lv_obj_t *label = lv_label_create(button);
    lv_label_set_text(label, text);
    lv_obj_center(label);
    return button;
}

static lv_obj_t *make_positioned_button(
    lv_obj_t *parent,
    const char *text,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height,
    lv_event_cb_t callback,
    void *user_data
)
{
    lv_obj_t *button = make_button(parent, text);
    lv_obj_set_size(button, width, height);
    lv_obj_set_pos(button, x, y);
    lv_obj_add_event_cb(button, callback, LV_EVENT_CLICKED, user_data);
    return button;
}

static lv_obj_t *make_positioned_icon_button(
    lv_obj_t *parent,
    const char *symbol,
    int32_t x,
    int32_t y,
    lv_event_cb_t callback,
    void *user_data
)
{
    lv_obj_t *button = make_positioned_button(parent, symbol, x, y, 62, 62, callback, user_data);
    lv_obj_set_style_text_font(lv_obj_get_child(button, 0), LV_FONT_DEFAULT, 0);
    return button;
}

static void show_detail_content(void)
{
    shortcut_page_active = false;
    lv_obj_add_flag(shortcut_page, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(detail_content_page, LV_OBJ_FLAG_HIDDEN);
    lv_label_set_text(page_toggle_label, "快捷键 >");
}

static void card_clicked(lv_event_t *event)
{
    note_interaction();
    if (interaction_locked) return;
    card_view_t *card = lv_event_get_user_data(event);
    if (micro_mode_active) {
        if (!micro_connected || !card->active) return;
        selected_micro_agent = (uint8_t)(card - cards);
        micro_action_page_active = true;
        micro_view = MICRO_VIEW_ACTIONS;
        lv_label_set_text(micro_action_status, state_text(card->state));
        lv_obj_set_style_text_color(micro_action_status, card->status_color, 0);
        lv_label_set_text_fmt(
            micro_action_title,
            "AGENT %u",
            (unsigned)(selected_micro_agent + 1)
        );
        lv_obj_remove_flag(micro_action_menu, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(micro_encoder_panel, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(micro_joystick_panel, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(home_page, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(micro_action_page, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    if (card->active && actions.select_session != NULL) {
        suppressed_session_key = 0;
        actions.select_session(card->session_key, actions.context);
    }
}

static void micro_action_back_clicked(lv_event_t *event)
{
    (void)event;
    note_interaction();
    if (interaction_locked || pressed_micro_control >= 0
        || pressed_micro_direction >= 0 || pressed_micro_encoder) return;
    if (micro_view != MICRO_VIEW_ACTIONS) {
        micro_view = MICRO_VIEW_ACTIONS;
        lv_label_set_text_fmt(
            micro_action_title,
            "AGENT %u",
            (unsigned)(selected_micro_agent + 1)
        );
        lv_obj_remove_flag(micro_action_menu, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(micro_encoder_panel, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(micro_joystick_panel, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    micro_action_page_active = false;
    selected_micro_agent = UINT8_MAX;
    lv_obj_add_flag(micro_action_page, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(home_page, LV_OBJ_FLAG_HIDDEN);
}

static void micro_control_key(lv_event_t *event)
{
    if (!micro_mode_active || !micro_connected || interaction_locked
        || actions.micro_control_key == NULL) return;
    cr_micro_control_t control = (cr_micro_control_t)(uintptr_t)lv_event_get_user_data(event);
    lv_event_code_t code = lv_event_get_code(event);
    if (code == LV_EVENT_PRESSED) {
        if (pressed_micro_control >= 0 || pressed_micro_direction >= 0
            || pressed_micro_encoder) return;
        note_interaction();
        pressed_micro_control = (int8_t)control;
        actions.micro_control_key(control, true, actions.context);
    } else if ((code == LV_EVENT_RELEASED || code == LV_EVENT_PRESS_LOST)
               && pressed_micro_control == (int8_t)control) {
        pressed_micro_control = -1;
        actions.micro_control_key(control, false, actions.context);
    }
}

static void micro_keyboard_action(lv_event_t *event)
{
    note_interaction();
    if (!micro_mode_active || !micro_connected || interaction_locked
        || pressed_micro_control >= 0 || pressed_micro_direction >= 0
        || pressed_micro_encoder || actions.micro_keyboard_action == NULL) return;
    cr_micro_keyboard_action_t action =
        (cr_micro_keyboard_action_t)(uintptr_t)lv_event_get_user_data(event);
    actions.micro_keyboard_action(action, actions.context);
}

static void micro_encoder_press(lv_event_t *event)
{
    if (!micro_mode_active || !micro_connected || interaction_locked
        || actions.micro_encoder_press == NULL) return;
    lv_event_code_t code = lv_event_get_code(event);
    if (code == LV_EVENT_PRESSED) {
        if (pressed_micro_control >= 0 || pressed_micro_direction >= 0
            || pressed_micro_encoder) return;
        note_interaction();
        pressed_micro_encoder = true;
        actions.micro_encoder_press(true, actions.context);
    } else if ((code == LV_EVENT_RELEASED || code == LV_EVENT_PRESS_LOST)
               && pressed_micro_encoder) {
        pressed_micro_encoder = false;
        actions.micro_encoder_press(false, actions.context);
    }
}

static void micro_encoder_turn(lv_event_t *event)
{
    if (!micro_mode_active || !micro_connected || interaction_locked
        || pressed_micro_control >= 0 || pressed_micro_direction >= 0
        || pressed_micro_encoder || actions.micro_encoder_turn == NULL) return;
    lv_event_code_t code = lv_event_get_code(event);
    if (code != LV_EVENT_SHORT_CLICKED && code != LV_EVENT_LONG_PRESSED
        && code != LV_EVENT_LONG_PRESSED_REPEAT) return;
    note_interaction();
    cr_micro_encoder_action_t action =
        (cr_micro_encoder_action_t)(uintptr_t)lv_event_get_user_data(event);
    actions.micro_encoder_turn(action, actions.context);
}

static lv_obj_t *make_micro_encoder_zone(
    lv_obj_t *parent,
    const char *symbol,
    int32_t x,
    cr_micro_encoder_action_t action
)
{
    lv_obj_t *zone = lv_button_create(parent);
    lv_obj_set_size(zone, 160, 320);
    lv_obj_set_pos(zone, x, 0);
    lv_obj_set_style_bg_opa(zone, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(zone, 0, 0);
    lv_obj_set_style_shadow_width(zone, 0, 0);
    lv_obj_t *label = lv_label_create(zone);
    lv_label_set_text(label, symbol);
    lv_obj_set_style_text_font(label, LV_FONT_DEFAULT, 0);
    lv_obj_align(label, x == 0 ? LV_ALIGN_LEFT_MID : LV_ALIGN_RIGHT_MID,
                 x == 0 ? 28 : -28, 0);
    void *user_data = (void *)(uintptr_t)action;
    lv_obj_add_event_cb(zone, micro_encoder_turn, LV_EVENT_SHORT_CLICKED, user_data);
    lv_obj_add_event_cb(zone, micro_encoder_turn, LV_EVENT_LONG_PRESSED, user_data);
    lv_obj_add_event_cb(zone, micro_encoder_turn, LV_EVENT_LONG_PRESSED_REPEAT, user_data);
    return zone;
}

static void micro_direction(lv_event_t *event)
{
    if (!micro_mode_active || !micro_connected || interaction_locked
        || actions.micro_direction == NULL) return;
    cr_micro_direction_t direction =
        (cr_micro_direction_t)(uintptr_t)lv_event_get_user_data(event);
    lv_event_code_t code = lv_event_get_code(event);
    if (code == LV_EVENT_PRESSED) {
        if (pressed_micro_control >= 0 || pressed_micro_direction >= 0
            || pressed_micro_encoder) return;
        note_interaction();
        pressed_micro_direction = (int8_t)direction;
        actions.micro_direction(direction, true, actions.context);
    } else if ((code == LV_EVENT_RELEASED || code == LV_EVENT_PRESS_LOST)
               && pressed_micro_direction == (int8_t)direction) {
        pressed_micro_direction = -1;
        actions.micro_direction(direction, false, actions.context);
    }
}

static void micro_view_opened(lv_event_t *event)
{
    if (pressed_micro_control >= 0 || pressed_micro_direction >= 0
        || pressed_micro_encoder) return;
    note_interaction();
    micro_view = (micro_view_t)(uintptr_t)lv_event_get_user_data(event);
    lv_obj_add_flag(micro_action_menu, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(micro_encoder_panel, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(micro_joystick_panel, LV_OBJ_FLAG_HIDDEN);
    if (micro_view == MICRO_VIEW_ENCODER) {
        lv_label_set_text(micro_action_title, "旋钮");
        lv_obj_remove_flag(micro_encoder_panel, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_label_set_text(micro_action_title, "摇杆");
        lv_obj_remove_flag(micro_joystick_panel, LV_OBJ_FLAG_HIDDEN);
    }
}

static lv_obj_t *make_micro_action_button(
    const char *text,
    cr_micro_control_t control,
    int32_t x,
    int32_t y,
    uint32_t color
)
{
    lv_obj_t *button = make_button(micro_action_menu, text);
    lv_obj_set_size(button, 210, 76);
    lv_obj_set_pos(button, x, y);
    lv_obj_set_style_bg_color(button, lv_color_hex(color), 0);
    lv_obj_add_event_cb(
        button, micro_control_key, LV_EVENT_PRESSED, (void *)(uintptr_t)control
    );
    lv_obj_add_event_cb(
        button, micro_control_key, LV_EVENT_RELEASED, (void *)(uintptr_t)control
    );
    lv_obj_add_event_cb(
        button, micro_control_key, LV_EVENT_PRESS_LOST, (void *)(uintptr_t)control
    );
    return button;
}

static lv_obj_t *make_micro_hold_button(
    lv_obj_t *parent,
    const char *text,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height,
    lv_event_cb_t callback,
    void *user_data
)
{
    lv_obj_t *button = make_button(parent, text);
    lv_obj_set_size(button, width, height);
    lv_obj_set_pos(button, x, y);
    lv_obj_add_event_cb(button, callback, LV_EVENT_PRESSED, user_data);
    lv_obj_add_event_cb(button, callback, LV_EVENT_RELEASED, user_data);
    lv_obj_add_event_cb(button, callback, LV_EVENT_PRESS_LOST, user_data);
    return button;
}

static void micro_card_key(lv_event_t *event)
{
    if (!micro_mode_active || interaction_locked || actions.micro_agent_key == NULL) return;
    card_view_t *card = lv_event_get_user_data(event);
    uint8_t index = (uint8_t)(card - cards);
    lv_event_code_t code = lv_event_get_code(event);
    if (code == LV_EVENT_PRESSED) {
        note_interaction();
        actions.micro_agent_key(index, true, actions.context);
    } else if (code == LV_EVENT_RELEASED || code == LV_EVENT_PRESS_LOST) {
        actions.micro_agent_key(index, false, actions.context);
    }
}

static void back_clicked(lv_event_t *event)
{
    (void)event;
    note_interaction();
    if (interaction_locked) return;
    suppressed_session_key = selected_session_key;
    selected_session_key = 0;
    show_detail_content();
    lv_obj_add_flag(detail_page, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(home_page, LV_OBJ_FLAG_HIDDEN);
}

static void page_toggle_clicked(lv_event_t *event)
{
    (void)event;
    note_interaction();
    if (interaction_locked || lv_obj_has_flag(page_toggle, LV_OBJ_FLAG_HIDDEN)) return;
    shortcut_page_active = !shortcut_page_active;
    if (shortcut_page_active) {
        lv_obj_add_flag(detail_content_page, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(shortcut_page, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(page_toggle_label, "< 状态");
    } else {
        show_detail_content();
    }
}

static void key_clicked(lv_event_t *event)
{
    note_interaction();
    if (interaction_locked) return;
    if (actions.terminal_key == NULL || selected_session_key == 0) return;
    uintptr_t key = (uintptr_t)lv_event_get_user_data(event);
    actions.terminal_key(selected_session_key, (uint8_t)key, actions.context);
}

static void shortcut_clicked(lv_event_t *event)
{
    note_interaction();
    if (interaction_locked) return;
    if (actions.terminal_shortcut == NULL || selected_session_key == 0) return;
    uintptr_t shortcut = (uintptr_t)lv_event_get_user_data(event);
    actions.terminal_shortcut(selected_session_key, (uint8_t)shortcut, actions.context);
}

static void delete_input(lv_event_t *event)
{
    note_interaction();
    if (interaction_locked) return;
    if (actions.terminal_key == NULL || selected_session_key == 0) return;
    uint8_t key = lv_event_get_code(event) == LV_EVENT_LONG_PRESSED
        ? CR_TERMINAL_KEY_CLEAR_LINE
        : CR_TERMINAL_KEY_BACKSPACE;
    actions.terminal_key(selected_session_key, key, actions.context);
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

static void screensaver_pressed(lv_event_t *event)
{
    (void)event;
    note_interaction();
}

static void mode_requested(lv_event_t *event)
{
    note_interaction();
    if (actions.request_connection_mode == NULL) return;
    uintptr_t mode = (uintptr_t)lv_event_get_user_data(event);
    actions.request_connection_mode((cr_connection_mode_t)mode, actions.context);
}

static void mode_confirmed(lv_event_t *event)
{
    (void)event;
    note_interaction();
    if (actions.confirm_connection_mode != NULL) {
        actions.confirm_connection_mode(actions.context);
    }
}

static void mode_cancelled(lv_event_t *event)
{
    (void)event;
    note_interaction();
    if (actions.cancel_connection_mode != NULL) {
        actions.cancel_connection_mode(actions.context);
    }
}

void cr_ui_init(const cr_ui_callbacks_t *config)
{
    actions = *config;
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(0x09090b), 0);
    lv_obj_set_style_text_color(screen, lv_color_hex(0xfafafa), 0);
    lv_obj_set_style_text_font(screen, &codex_remote_font_16, 0);

    home_page = lv_obj_create(screen);
    lv_obj_remove_style_all(home_page);
    lv_obj_set_size(home_page, LV_PCT(100), LV_PCT(100));

    home_heading = lv_label_create(home_page);
    lv_label_set_text(home_heading, "CODEX REMOTE");
    lv_obj_align(home_heading, LV_ALIGN_TOP_LEFT, 18, 16);

    connection_label = lv_label_create(home_page);
    lv_label_set_text(connection_label, "等待 Mac...");
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
        lv_obj_set_style_bg_color(card->card, state_background_color(5), 0);
        lv_obj_set_style_border_color(card->card, state_border_color(5), 0);
        lv_obj_set_style_border_width(card->card, 2, 0);
        lv_obj_set_style_radius(card->card, 18, 0);
        lv_obj_add_event_cb(card->card, card_clicked, LV_EVENT_CLICKED, card);
        lv_obj_add_event_cb(card->card, micro_card_key, LV_EVENT_PRESSED, card);
        lv_obj_add_event_cb(card->card, micro_card_key, LV_EVENT_RELEASED, card);
        lv_obj_add_event_cb(card->card, micro_card_key, LV_EVENT_PRESS_LOST, card);

        card->status = lv_label_create(card->card);
        lv_obj_align(card->status, LV_ALIGN_TOP_RIGHT, 0, 0);

        card->title = lv_label_create(card->card);
        lv_obj_set_width(card->title, 182);
        lv_label_set_long_mode(card->title, LV_LABEL_LONG_DOT);
        lv_obj_align(card->title, LV_ALIGN_TOP_LEFT, 0, 38);

        card->directory = lv_label_create(card->card);
        lv_obj_set_width(card->directory, 182);
        lv_label_set_long_mode(card->directory, LV_LABEL_LONG_DOT);
        lv_obj_set_style_text_color(card->directory, lv_color_hex(0xd4d4d8), 0);
        lv_obj_align(card->directory, LV_ALIGN_BOTTOM_LEFT, 0, -4);
        lv_obj_add_flag(card->card, LV_OBJ_FLAG_HIDDEN);
    }

    detail_page = lv_obj_create(screen);
    lv_obj_remove_style_all(detail_page);
    lv_obj_set_size(detail_page, LV_PCT(100), LV_PCT(100));
    lv_obj_add_flag(detail_page, LV_OBJ_FLAG_HIDDEN);

    lv_obj_t *back = make_button(detail_page, "返回");
    lv_obj_set_size(back, 90, 46);
    lv_obj_align(back, LV_ALIGN_TOP_LEFT, 14, 14);
    lv_obj_add_event_cb(back, back_clicked, LV_EVENT_CLICKED, NULL);

    detail_title = lv_label_create(detail_page);
    lv_obj_set_width(detail_title, 240);
    lv_label_set_long_mode(detail_title, LV_LABEL_LONG_DOT);
    lv_obj_align(detail_title, LV_ALIGN_TOP_LEFT, 120, 16);

    detail_directory = lv_label_create(detail_page);
    lv_obj_set_width(detail_directory, 240);
    lv_label_set_long_mode(detail_directory, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_color(detail_directory, lv_color_hex(0xa1a1aa), 0);
    lv_obj_align(detail_directory, LV_ALIGN_TOP_LEFT, 120, 45);

    page_toggle = make_button(detail_page, "");
    lv_obj_set_size(page_toggle, 90, 46);
    lv_obj_align(page_toggle, LV_ALIGN_TOP_RIGHT, -14, 14);
    page_toggle_label = lv_obj_get_child(page_toggle, 0);
    lv_label_set_text(page_toggle_label, "快捷键 >");
    lv_obj_add_event_cb(page_toggle, page_toggle_clicked, LV_EVENT_CLICKED, NULL);

    detail_content_page = lv_obj_create(detail_page);
    lv_obj_remove_style_all(detail_content_page);
    lv_obj_set_size(detail_content_page, 480, 410);
    lv_obj_set_pos(detail_content_page, 0, 70);

    lv_obj_t *gesture = lv_obj_create(detail_content_page);
    lv_obj_set_size(gesture, 450, 270);
    lv_obj_set_pos(gesture, 15, 0);
    lv_obj_set_style_bg_color(gesture, lv_color_hex(0x18181b), 0);
    lv_obj_set_style_radius(gesture, 18, 0);
    lv_obj_add_event_cb(gesture, detail_pointer, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(gesture, detail_pointer, LV_EVENT_RELEASED, NULL);
    detail_status = lv_label_create(gesture);
    lv_obj_set_width(detail_status, 410);
    lv_label_set_long_mode(detail_status, LV_LABEL_LONG_WRAP);
    lv_obj_center(detail_status);

    make_positioned_button(
        detail_content_page, "取消  ESC", 122, 338, 108, 52,
        key_clicked, (void *)(uintptr_t)CR_TERMINAL_KEY_ESCAPE
    );
    make_positioned_button(
        detail_content_page, "确认  ENTER", 242, 338, 115, 52,
        key_clicked, (void *)(uintptr_t)CR_TERMINAL_KEY_ENTER
    );
    lv_obj_t *delete_button = make_button(detail_content_page, "删除");
    lv_obj_set_size(delete_button, 108, 52);
    lv_obj_set_pos(delete_button, 365, 338);
    lv_obj_set_style_bg_color(delete_button, lv_color_hex(0x991b1b), 0);
    lv_obj_add_event_cb(delete_button, delete_input, LV_EVENT_SHORT_CLICKED, NULL);
    lv_obj_add_event_cb(delete_button, delete_input, LV_EVENT_LONG_PRESSED, NULL);

    shortcut_page = lv_obj_create(detail_page);
    lv_obj_remove_style_all(shortcut_page);
    lv_obj_set_size(shortcut_page, 480, 410);
    lv_obj_set_pos(shortcut_page, 0, 70);
    lv_obj_add_flag(shortcut_page, LV_OBJ_FLAG_HIDDEN);

    make_positioned_button(shortcut_page, "/new", 14, 14, 104, 52, shortcut_clicked, (void *)(uintptr_t)CR_TERMINAL_SHORTCUT_NEW_SESSION);
    make_positioned_button(shortcut_page, "/q", 362, 14, 104, 52, shortcut_clicked, (void *)(uintptr_t)CR_TERMINAL_SHORTCUT_QUIT);
    make_positioned_button(shortcut_page, "/w", 14, 344, 104, 52, shortcut_clicked, (void *)(uintptr_t)CR_TERMINAL_SHORTCUT_WRITE);
    make_positioned_button(shortcut_page, "/plan", 346, 344, 120, 52, shortcut_clicked, (void *)(uintptr_t)CR_TERMINAL_SHORTCUT_PLAN);
    make_positioned_button(shortcut_page, "/compact", 170, 180, 140, 62, shortcut_clicked, (void *)(uintptr_t)CR_TERMINAL_SHORTCUT_COMPACT);
    make_positioned_icon_button(shortcut_page, LV_SYMBOL_UP, 209, 100, key_clicked, (void *)(uintptr_t)CR_TERMINAL_KEY_UP);
    make_positioned_icon_button(shortcut_page, LV_SYMBOL_DOWN, 209, 260, key_clicked, (void *)(uintptr_t)CR_TERMINAL_KEY_DOWN);
    make_positioned_icon_button(shortcut_page, LV_SYMBOL_LEFT, 90, 180, key_clicked, (void *)(uintptr_t)CR_TERMINAL_KEY_LEFT);
    make_positioned_icon_button(shortcut_page, LV_SYMBOL_RIGHT, 328, 180, key_clicked, (void *)(uintptr_t)CR_TERMINAL_KEY_RIGHT);

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

    micro_action_page = lv_obj_create(screen);
    lv_obj_remove_style_all(micro_action_page);
    lv_obj_set_size(micro_action_page, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_bg_color(micro_action_page, lv_color_hex(0x09090b), 0);
    lv_obj_set_style_bg_opa(micro_action_page, LV_OPA_COVER, 0);

    lv_obj_t *micro_back = make_button(micro_action_page, "返回");
    lv_obj_set_size(micro_back, 90, 46);
    lv_obj_align(micro_back, LV_ALIGN_TOP_LEFT, 14, 14);
    lv_obj_add_event_cb(micro_back, micro_action_back_clicked, LV_EVENT_CLICKED, NULL);

    micro_action_title = lv_label_create(micro_action_page);
    lv_label_set_text(micro_action_title, "AGENT 1");
    lv_obj_align(micro_action_title, LV_ALIGN_TOP_LEFT, 120, 16);

    micro_action_status = lv_label_create(micro_action_page);
    lv_label_set_text(micro_action_status, "离线");
    lv_obj_align(micro_action_status, LV_ALIGN_TOP_RIGHT, -14, 20);

    micro_action_menu = lv_obj_create(micro_action_page);
    lv_obj_remove_style_all(micro_action_menu);
    lv_obj_set_size(micro_action_menu, LV_PCT(100), LV_PCT(100));
    make_micro_action_button("批准", CR_MICRO_CONTROL_APPROVE, 20, 76, 0x166534);
    make_micro_action_button("拒绝", CR_MICRO_CONTROL_DECLINE, 250, 76, 0x991b1b);
    make_micro_action_button("继续", CR_MICRO_CONTROL_CONTINUE, 20, 164, 0x27272a);
    make_positioned_button(
        micro_action_menu, "删除", 250, 164, 210, 76,
        micro_keyboard_action, (void *)(uintptr_t)CR_MICRO_KEYBOARD_DELETE
    );
    make_positioned_button(
        micro_action_menu, "清除", 20, 252, 210, 76,
        micro_keyboard_action, (void *)(uintptr_t)CR_MICRO_KEYBOARD_CLEAR
    );
    make_positioned_button(
        micro_action_menu, "旋钮", 20, 340, 210, 76,
        micro_view_opened, (void *)(uintptr_t)MICRO_VIEW_ENCODER
    );
    make_positioned_button(
        micro_action_menu, "摇杆", 250, 340, 210, 76,
        micro_view_opened, (void *)(uintptr_t)MICRO_VIEW_JOYSTICK
    );

    micro_encoder_panel = lv_obj_create(micro_action_page);
    lv_obj_remove_style_all(micro_encoder_panel);
    lv_obj_set_size(micro_encoder_panel, LV_PCT(100), LV_PCT(100));
    micro_encoder_ring = lv_obj_create(micro_encoder_panel);
    lv_obj_set_size(micro_encoder_ring, 320, 320);
    lv_obj_set_pos(micro_encoder_ring, 80, 92);
    lv_obj_set_style_radius(micro_encoder_ring, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(micro_encoder_ring, lv_color_hex(0x18181b), 0);
    lv_obj_set_style_bg_opa(micro_encoder_ring, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(micro_encoder_ring, 8, 0);
    lv_obj_set_style_border_color(micro_encoder_ring, lv_color_hex(0x52525b), 0);
    lv_obj_set_style_pad_all(micro_encoder_ring, 0, 0);
    make_micro_encoder_zone(
        micro_encoder_ring, LV_SYMBOL_LEFT, 0,
        CR_MICRO_ENCODER_COUNTERCLOCKWISE
    );
    make_micro_encoder_zone(
        micro_encoder_ring, LV_SYMBOL_RIGHT, 160,
        CR_MICRO_ENCODER_CLOCKWISE
    );
    lv_obj_t *encoder_center = make_micro_hold_button(
        micro_encoder_ring, "点击 / 长按", 85, 85, 150, 150,
        micro_encoder_press, NULL
    );
    lv_obj_set_style_radius(encoder_center, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(encoder_center, lv_color_hex(0x27272a), 0);
    lv_obj_set_style_border_width(encoder_center, 4, 0);
    lv_obj_set_style_border_color(encoder_center, lv_color_hex(0xa1a1aa), 0);
    lv_obj_move_foreground(encoder_center);
    lv_obj_add_flag(micro_encoder_panel, LV_OBJ_FLAG_HIDDEN);

    micro_joystick_panel = lv_obj_create(micro_action_page);
    lv_obj_remove_style_all(micro_joystick_panel);
    lv_obj_set_size(micro_joystick_panel, LV_PCT(100), LV_PCT(100));
    lv_obj_t *joystick_up = make_micro_hold_button(
        micro_joystick_panel, LV_SYMBOL_UP, 190, 82, 100, 86,
        micro_direction, (void *)(uintptr_t)CR_MICRO_DIRECTION_UP
    );
    lv_obj_t *joystick_left = make_micro_hold_button(
        micro_joystick_panel, LV_SYMBOL_LEFT, 74, 190, 100, 86,
        micro_direction, (void *)(uintptr_t)CR_MICRO_DIRECTION_LEFT
    );
    lv_obj_t *joystick_right = make_micro_hold_button(
        micro_joystick_panel, LV_SYMBOL_RIGHT, 306, 190, 100, 86,
        micro_direction, (void *)(uintptr_t)CR_MICRO_DIRECTION_RIGHT
    );
    lv_obj_t *joystick_down = make_micro_hold_button(
        micro_joystick_panel, LV_SYMBOL_DOWN, 190, 298, 100, 86,
        micro_direction, (void *)(uintptr_t)CR_MICRO_DIRECTION_DOWN
    );
    lv_obj_set_style_text_font(lv_obj_get_child(joystick_up, 0), LV_FONT_DEFAULT, 0);
    lv_obj_set_style_text_font(lv_obj_get_child(joystick_left, 0), LV_FONT_DEFAULT, 0);
    lv_obj_set_style_text_font(lv_obj_get_child(joystick_right, 0), LV_FONT_DEFAULT, 0);
    lv_obj_set_style_text_font(lv_obj_get_child(joystick_down, 0), LV_FONT_DEFAULT, 0);
    lv_obj_add_flag(micro_joystick_panel, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(micro_back);
    lv_obj_move_foreground(micro_action_title);
    lv_obj_move_foreground(micro_action_status);
    lv_obj_add_flag(micro_action_page, LV_OBJ_FLAG_HIDDEN);

    mode_page = lv_obj_create(screen);
    lv_obj_remove_style_all(mode_page);
    lv_obj_set_size(mode_page, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_bg_color(mode_page, lv_color_hex(0x09090b), 0);
    lv_obj_set_style_bg_opa(mode_page, LV_OPA_COVER, 0);

    lv_obj_t *mode_title = lv_label_create(mode_page);
    lv_label_set_text(mode_title, "CONNECTION MODE");
    lv_obj_align(mode_title, LV_ALIGN_TOP_MID, 0, 54);

    mode_choices = lv_obj_create(mode_page);
    lv_obj_remove_style_all(mode_choices);
    lv_obj_set_size(mode_choices, 420, 260);
    lv_obj_align(mode_choices, LV_ALIGN_CENTER, 0, 28);
    make_positioned_button(
        mode_choices, "CODEX MICRO", 30, 24, 360, 82,
        mode_requested, (void *)(uintptr_t)CR_CONNECTION_MODE_NATIVE_MICRO
    );
    make_positioned_button(
        mode_choices, "MAC APP", 30, 142, 360, 82,
        mode_requested, (void *)(uintptr_t)CR_CONNECTION_MODE_MAC_COMPANION
    );

    mode_confirmation = lv_obj_create(mode_page);
    lv_obj_remove_style_all(mode_confirmation);
    lv_obj_set_size(mode_confirmation, 420, 260);
    lv_obj_align(mode_confirmation, LV_ALIGN_CENTER, 0, 28);
    mode_confirmation_label = lv_label_create(mode_confirmation);
    lv_obj_set_width(mode_confirmation_label, 390);
    lv_obj_set_style_text_align(mode_confirmation_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(mode_confirmation_label, LV_ALIGN_TOP_MID, 0, 48);
    make_positioned_button(
        mode_confirmation, "取消", 40, 156, 150, 62,
        mode_cancelled, NULL
    );
    make_positioned_button(
        mode_confirmation, "确认", 230, 156, 150, 62,
        mode_confirmed, NULL
    );
    lv_obj_add_flag(mode_confirmation, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(mode_page, LV_OBJ_FLAG_HIDDEN);
}

void cr_ui_update(const cr_device_state_t *state)
{
    micro_mode_active = false;
    micro_connected = false;
    micro_action_page_active = false;
    selected_micro_agent = UINT8_MAX;
    pressed_micro_control = -1;
    pressed_micro_direction = -1;
    pressed_micro_encoder = false;
    micro_view = MICRO_VIEW_ACTIONS;
    lv_obj_remove_flag(micro_action_menu, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(micro_encoder_panel, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(micro_joystick_panel, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(micro_action_page, LV_OBJ_FLAG_HIDDEN);
    lv_label_set_text(home_heading, "CODEX REMOTE");
    interaction_locked = state->ptt_active;
    lv_label_set_text(connection_label, state->has_snapshot ? "Mac 已连接" : "等待 Mac...");
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
        card->state = session->state;
        card->status_color = state_border_color(session->state);
        lv_obj_set_size(card->card, 214, 184);
        lv_obj_set_pos(card->card, (index % 2) * 224, (index / 2) * 194);
        lv_obj_align(card->title, LV_ALIGN_TOP_LEFT, 0, 38);
        lv_obj_remove_flag(card->directory, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(card->title, session->display_title);
        lv_label_set_text(card->directory, session->working_directory_label);
        lv_label_set_text(card->status, state_text(session->state));
        lv_obj_set_style_text_color(card->status, state_border_color(session->state), 0);
        lv_obj_set_style_bg_color(card->card, state_background_color(session->state), 0);
        lv_obj_set_style_border_color(card->card, state_border_color(session->state), 0);
        lv_obj_remove_flag(card->card, LV_OBJ_FLAG_HIDDEN);
    }

    if (!state->has_selection || state->selected_session_key == suppressed_session_key) {
        selected_session_key = 0;
        show_detail_content();
        lv_obj_add_flag(detail_page, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(home_page, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    suppressed_session_key = 0;
    for (size_t index = 0; index < state->session_count; index++) {
        const cr_device_session_t *session = &state->sessions[index];
        if (session->session_key != state->selected_session_key) continue;
        selected_session_key = session->session_key;
        lv_label_set_text(detail_title, session->display_title);
        lv_label_set_text(detail_directory, session->working_directory_label);
        lv_label_set_text(detail_status, session->status_detail[0] == '\0' ? state_text(session->state) : session->status_detail);
        bool supports_shortcuts = (session->capabilities
            & (CR_SESSION_CAPABILITY_NAVIGATION_KEYS | CR_SESSION_CAPABILITY_TERMINAL_SHORTCUTS))
            == (CR_SESSION_CAPABILITY_NAVIGATION_KEYS | CR_SESSION_CAPABILITY_TERMINAL_SHORTCUTS);
        if (supports_shortcuts) {
            lv_obj_remove_flag(page_toggle, LV_OBJ_FLAG_HIDDEN);
        } else {
            show_detail_content();
            lv_obj_add_flag(page_toggle, LV_OBJ_FLAG_HIDDEN);
        }
        lv_obj_add_flag(home_page, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(detail_page, LV_OBJ_FLAG_HIDDEN);
        return;
    }
}

void cr_ui_update_micro(const cr_micro_state_t *state)
{
    if (state == NULL) return;
    micro_mode_active = true;
    micro_connected = state->connected;
    interaction_locked = false;
    selected_session_key = 0;
    show_detail_content();
    lv_obj_add_flag(detail_page, LV_OBJ_FLAG_HIDDEN);
    if (!micro_connected) {
        micro_action_page_active = false;
        selected_micro_agent = UINT8_MAX;
        pressed_micro_control = -1;
        pressed_micro_direction = -1;
        pressed_micro_encoder = false;
        micro_view = MICRO_VIEW_ACTIONS;
        lv_obj_remove_flag(micro_action_menu, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(micro_encoder_panel, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(micro_joystick_panel, LV_OBJ_FLAG_HIDDEN);
    }
    lv_label_set_text(home_heading, "CODEX MICRO");
    lv_label_set_text(
        connection_label,
        state->connected ? "Codex 已连接" : "等待 Codex..."
    );

    for (size_t index = 0; index < CR_MAX_SESSIONS; index++) {
        card_view_t *card = &cards[index];
        if (index >= CR_MICRO_SLOT_COUNT) {
            card->active = false;
            lv_obj_add_flag(card->card, LV_OBJ_FLAG_HIDDEN);
            continue;
        }

        const cr_micro_light_t *slot = &state->slots[index];
        uint8_t slot_state = micro_light_state(slot);
        card->active = true;
        card->session_key = (uint16_t)(index + 1);
        card->state = slot_state;
        lv_obj_set_size(card->card, 214, 116);
        lv_obj_set_pos(card->card, (index % 2) * 224, (index / 2) * 126);
        lv_obj_align(card->title, LV_ALIGN_BOTTOM_LEFT, 0, -4);
        lv_obj_add_flag(card->directory, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text_fmt(card->title, "AGENT %u", (unsigned)(index + 1));
        lv_label_set_text(card->status, state_text(slot_state));
        if (!slot->configured) {
            card->status_color = lv_color_hex(0xa1a1aa);
            lv_obj_set_style_bg_color(card->card, lv_color_hex(0x18181b), 0);
            lv_obj_set_style_border_color(card->card, lv_color_hex(0x52525b), 0);
            lv_obj_set_style_text_color(card->status, card->status_color, 0);
        } else {
            lv_color_t color = lv_color_hex(slot->color);
            card->status_color = color;
            lv_obj_set_style_bg_color(card->card, lv_color_mix(color, lv_color_hex(0x09090b), 96), 0);
            lv_obj_set_style_border_color(card->card, color, 0);
            lv_obj_set_style_text_color(card->status, card->status_color, 0);
        }
        lv_obj_remove_flag(card->card, LV_OBJ_FLAG_HIDDEN);
    }

    if (micro_action_page_active && selected_micro_agent < CR_MICRO_SLOT_COUNT) {
        const cr_micro_light_t *slot = &state->slots[selected_micro_agent];
        uint8_t slot_state = micro_light_state(slot);
        lv_label_set_text(micro_action_status, state_text(slot_state));
        lv_obj_set_style_text_color(
            micro_action_status,
            slot->configured ? lv_color_hex(slot->color) : lv_color_hex(0xa1a1aa),
            0
        );
        lv_obj_add_flag(home_page, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(micro_action_page, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(micro_action_page, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(home_page, LV_OBJ_FLAG_HIDDEN);
    }
}

void cr_ui_set_connection_mode(const cr_connection_mode_state_t *state)
{
    if (state == NULL) return;
    if (state->active != CR_CONNECTION_MODE_UNCONFIGURED
        && !state->confirmation_required) {
        lv_obj_add_flag(mode_page, LV_OBJ_FLAG_HIDDEN);
        return;
    }

    lv_obj_remove_flag(mode_page, LV_OBJ_FLAG_HIDDEN);
    if (!state->confirmation_required) {
        lv_obj_remove_flag(mode_choices, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(mode_confirmation, LV_OBJ_FLAG_HIDDEN);
        return;
    }

    const char *mode_name = state->pending == CR_CONNECTION_MODE_NATIVE_MICRO
        ? "CODEX MICRO" : "MAC APP";
    lv_label_set_text_fmt(mode_confirmation_label, "USE %s?\nDEVICE WILL RESTART", mode_name);
    lv_obj_add_flag(mode_choices, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(mode_confirmation, LV_OBJ_FLAG_HIDDEN);
}

void cr_ui_set_power(cr_power_mode_t mode, size_t asset_index)
{
    (void)asset_index;
    if (mode == CR_POWER_SCREENSAVER || mode == CR_POWER_OFF) {
        lv_obj_move_foreground(screensaver_page);
        lv_obj_remove_flag(screensaver_page, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(screensaver_page, LV_OBJ_FLAG_HIDDEN);
    }
}

bool cr_ui_is_detail_active(void)
{
    return micro_mode_active
        ? micro_action_page_active
        : !lv_obj_has_flag(detail_page, LV_OBJ_FLAG_HIDDEN);
}

bool cr_ui_return_to_list(void)
{
    if (!cr_ui_is_detail_active() || interaction_locked
        || pressed_micro_control >= 0 || pressed_micro_direction >= 0
        || pressed_micro_encoder) return false;

    if (micro_mode_active) {
        micro_action_page_active = false;
        selected_micro_agent = UINT8_MAX;
        micro_view = MICRO_VIEW_ACTIONS;
        lv_obj_remove_flag(micro_action_menu, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(micro_encoder_panel, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(micro_joystick_panel, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(micro_action_page, LV_OBJ_FLAG_HIDDEN);
    } else {
        suppressed_session_key = selected_session_key;
        selected_session_key = 0;
        show_detail_content();
        lv_obj_add_flag(detail_page, LV_OBJ_FLAG_HIDDEN);
    }
    lv_obj_remove_flag(home_page, LV_OBJ_FLAG_HIDDEN);
    return true;
}
