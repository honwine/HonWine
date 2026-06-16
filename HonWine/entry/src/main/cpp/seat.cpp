#include "seat.h"
#include <chrono>
#include <cstring>
#include <unistd.h>
#include <fcntl.h>

#undef LOG_TAG
#define LOG_TAG "WL_Seat"
#include <hilog/log.h>

// -- Linux evdev button codes --
enum {
    BTN_LEFT   = 0x110,  // 272
    BTN_RIGHT  = 0x111,  // 273
    BTN_MIDDLE = 0x112,  // 274
};

// -- wl_seat 接口实现表 --
static const struct wl_seat_interface kSeatImpl = {
    .get_pointer  = Seat::seat_get_pointer,
    .get_keyboard = Seat::seat_get_keyboard,
    .get_touch    = Seat::seat_get_touch,
    .release      = Seat::seat_release,
};

// -- wl_pointer 接口实现表 --
static void ptr_set_cursor(wl_client*, wl_resource*, uint32_t, wl_resource*, int32_t, int32_t) {}
static void ptr_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }

static const struct wl_pointer_interface kPointerImpl = {
    .set_cursor = ptr_set_cursor,
    .release    = ptr_release,
};

// -- wl_keyboard 接口实现表 --
static void kbd_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }

static const struct wl_keyboard_interface kKeyboardImpl = {
    .release = kbd_release,
};

// -- wl_touch 接口实现表 (不支持, 触控映射到 pointer) --
static void tch_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }

static const struct wl_touch_interface kTouchImpl = {
    .release = tch_release,
};

// -- 单例 --
Seat* Seat::GetInstance() {
    static Seat s;
    return &s;
}

// -- 辅助: 当前毫秒时间 --
static uint32_t NowMs() {
    auto now = std::chrono::steady_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
    return static_cast<uint32_t>(ms);
}

// -- Register / Unregister --
void Seat::Register(wl_display* display) {
    if (global_) {
        OH_LOG_WARN(LOG_APP, "[Seat] already registered");
        return;
    }
    display_ = display;

    // 创建 pipe: NAPI 线程写入 -> Wayland 线程读取, 唤醒事件循环
    int fds[2];
    if (pipe2(fds, O_NONBLOCK | O_CLOEXEC) != 0) {
        OH_LOG_ERROR(LOG_APP, "[Seat] pipe2 failed errno=%{public}d", errno);
        return;
    }
    pipeRead_  = fds[0];
    pipeWrite_ = fds[1];

    struct wl_event_loop* loop = wl_display_get_event_loop(display);
    pipeSource_ = wl_event_loop_add_fd(loop, pipeRead_, WL_EVENT_READABLE, OnPipeReadable, this);
    if (!pipeSource_) {
        OH_LOG_ERROR(LOG_APP, "[Seat] wl_event_loop_add_fd failed");
        close(pipeRead_); close(pipeWrite_);
        pipeRead_ = pipeWrite_ = -1;
        return;
    }

    global_ = wl_global_create(display, &wl_seat_interface, 5, this, seat_bind);
    OH_LOG_INFO(LOG_APP, "[Seat] wl_seat global registered OK (pipe r=%{public}d w=%{public}d)", pipeRead_, pipeWrite_);
}

void Seat::Unregister() {
    // 关闭 pipe 端 (按线程归属)
    if (pipeSource_) {
        wl_event_source_remove(pipeSource_);
        pipeSource_ = nullptr;
    }
    if (pipeRead_ >= 0)  { close(pipeRead_);  pipeRead_  = -1; }
    if (pipeWrite_ >= 0) { close(pipeWrite_); pipeWrite_ = -1; }

    if (global_) {
        wl_global_destroy(global_);
        global_ = nullptr;
    }
    pointerResource_.store(nullptr);
    keyboardResource_.store(nullptr);
    seatResource_ = nullptr;
    display_ = nullptr;
    OH_LOG_INFO(LOG_APP, "[Seat] unregistered OK");
}

// -- seat_bind --
void Seat::seat_bind(wl_client* client, void* data, uint32_t version, uint32_t id) {
    auto* self = static_cast<Seat*>(data);
    uint32_t v = std::min(version, 5u);

    wl_resource* res = wl_resource_create(client, &wl_seat_interface, v, id);
    wl_resource_set_implementation(res, &kSeatImpl, self, nullptr);

    // 声明能力: pointer + keyboard
    uint32_t caps = WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD;
    wl_seat_send_capabilities(res, caps);

    if (v >= WL_SEAT_NAME_SINCE_VERSION) {
        wl_seat_send_name(res, "Wine-Virtual-Seat");
    }

    self->seatResource_ = res;
    OH_LOG_INFO(LOG_APP, "[Seat] client bound v=%{public}u caps=0x%{public}x OK", v, caps);
}

// -- get_pointer --
void Seat::seat_get_pointer(wl_client* client, wl_resource* seatRes, uint32_t id) {
    auto* self = static_cast<Seat*>(wl_resource_get_user_data(seatRes));
    uint32_t version = wl_resource_get_version(seatRes);

    wl_resource* ptr = wl_resource_create(client, &wl_pointer_interface, version, id);
    wl_resource_set_implementation(ptr, &kPointerImpl, self, Seat::pointer_destroy);
    self->pointerResource_.store(ptr);

    OH_LOG_INFO(LOG_APP, "[Seat] wl_pointer created OK");
}

// -- get_keyboard --
void Seat::seat_get_keyboard(wl_client* client, wl_resource* seatRes, uint32_t id) {
    auto* self = static_cast<Seat*>(wl_resource_get_user_data(seatRes));
    uint32_t version = wl_resource_get_version(seatRes);

    wl_resource* kbd = wl_resource_create(client, &wl_keyboard_interface, version, id);
    wl_resource_set_implementation(kbd, &kKeyboardImpl, self, Seat::keyboard_destroy);
    self->keyboardResource_.store(kbd);

    // keymap: NO_KEYMAP -- Wine 需要 xkbcommon 处理 keymap,
    // 但在 NO_KEYMAP 下回退到 raw keycode (足够基本输入)
    wl_keyboard_send_keymap(kbd, WL_KEYBOARD_KEYMAP_FORMAT_NO_KEYMAP, 0, 0);
    wl_keyboard_send_repeat_info(kbd, 40, 400);

    OH_LOG_INFO(LOG_APP, "[Seat] wl_keyboard created OK (keymap=NO_KEYMAP)");
}

// -- get_touch (不支持) --
void Seat::seat_get_touch(wl_client* client, wl_resource* seatRes, uint32_t id) {
    // 触控通过 pointer 注入, touch 设备不暴露
    uint32_t version = wl_resource_get_version(seatRes);
    wl_resource* tch = wl_resource_create(client, &wl_touch_interface, version, id);
    wl_resource_set_implementation(tch, &kTouchImpl, nullptr, nullptr);
    OH_LOG_WARN(LOG_APP, "[Seat] wl_touch created (unsupported, use pointer)");
}

void Seat::seat_release(wl_client*, wl_resource* r) {
    wl_resource_destroy(r);
}

// -- resource destructors --
void Seat::pointer_destroy(wl_resource* r) {
    auto* self = static_cast<Seat*>(wl_resource_get_user_data(r));
    if (self->pointerResource_.load() == r) {
        self->pointerResource_.store(nullptr);
        self->pointerEnterSerial_ = 0;
        self->focusedSurface_ = nullptr;
        self->focusedToplevel_ = 0;
        OH_LOG_INFO(LOG_APP, "[Seat] wl_pointer destroyed (focus reset)");
    }
}

void Seat::keyboard_destroy(wl_resource* r) {
    auto* self = static_cast<Seat*>(wl_resource_get_user_data(r));
    if (self->keyboardResource_.load() == r) {
        self->keyboardResource_.store(nullptr);
        self->keyboardEntered_ = false;
        self->keyboardFocusedToplevel_ = 0;
        self->keyboardFocusedSurface_ = nullptr;
        OH_LOG_INFO(LOG_APP, "[Seat] wl_keyboard destroyed (kbd focus reset)");
    }
}

// -- 事件队列 (NAPI 线程 -> Wayland 线程) --

void Seat::Enqueue(Seat::InputEvent::Type type, uint32_t tl, wl_resource* surface,
                   wl_fixed_t x, wl_fixed_t y, uint32_t button_or_key, uint32_t state) {
    {
        std::lock_guard<std::mutex> lk(queueMutex_);
        queue_.push_back({type, tl, surface, x, y, button_or_key, state});
    }
    if (type == InputEvent::PTR_ENTER || type == InputEvent::PTR_BUTTON) {
        OH_LOG_INFO(LOG_APP, "[CLICK-PIPE]  [Enqueue] type=%{public}d tl=%{public}u surf=%{public}p btn=0x%{public}x state=%{public}u",
                    (int)type, tl, surface, button_or_key, state);
    }
    // 唤醒 Wayland 线程 (写 1 字节到 pipe)
    if (pipeWrite_ >= 0) {
        char c = 1;
        ssize_t n = write(pipeWrite_, &c, 1);
        if (n < 0 && errno != EAGAIN) {
            OH_LOG_WARN(LOG_APP, "[Seat] pipe WRITE FAIL errno=%{public}d wfd=%{public}d", errno, pipeWrite_);
        } else if (n < 0) {
            // EAGAIN: pipe buffer full, event still in queue, will be flushed when Wayland wakes
            // (被抑制, 否则 MOVE 事件刷屏)
        }
    } else {
        OH_LOG_ERROR(LOG_APP, "[Seat] pipe WRITE CLOSED wfd=%{public}d!", pipeWrite_);
    }
}

void Seat::EnqueuePointerEnter(uint32_t tl, wl_resource* surface, wl_fixed_t sx, wl_fixed_t sy) {
    Enqueue(InputEvent::PTR_ENTER, tl, surface, sx, sy, 0, 0);
}
void Seat::EnqueuePointerMotion(wl_fixed_t sx, wl_fixed_t sy) {
    Enqueue(InputEvent::PTR_MOTION, 0, nullptr, sx, sy, 0, 0);
}
void Seat::EnqueuePointerButton(uint32_t button, uint32_t state) {
    Enqueue(InputEvent::PTR_BUTTON, 0, nullptr, 0, 0, button, state);
}
void Seat::EnqueuePointerLeave() {
    Enqueue(InputEvent::PTR_LEAVE, 0, nullptr, 0, 0, 0, 0);
}
void Seat::EnqueuePointerAxis(uint32_t axis, wl_fixed_t value) {
    Enqueue(InputEvent::PTR_AXIS, 0, nullptr, wl_fixed_from_int(0), value, axis, 0);
}
void Seat::EnqueueKeyboardEnter(uint32_t tl, wl_resource* surface) {
    Enqueue(InputEvent::KBD_ENTER, tl, surface, 0, 0, 0, 0);
}
void Seat::EnqueueKeyboardLeave() {
    Enqueue(InputEvent::KBD_LEAVE, 0, nullptr, 0, 0, 0, 0);
}
void Seat::EnqueueKeyboardKey(uint32_t key, uint32_t state) {
    Enqueue(InputEvent::KBD_KEY, 0, nullptr, 0, 0, key, state);
}

int Seat::OnPipeReadable(int fd, uint32_t mask, void* data) {
    // 排空 pipe 中的字节
    char buf[64];
    while (read(fd, buf, sizeof(buf)) > 0) {}
    static_cast<Seat*>(data)->FlushQueue();
    return 0;
}

void Seat::FlushQueue() {
    // Wayland 线程: 取出队列中所有事件并发送
    std::vector<InputEvent> batch;
    {
        std::lock_guard<std::mutex> lk(queueMutex_);
        batch.swap(queue_);
    }

    if (batch.empty()) return;

    // 去重: 连续相同事件合并 (touch + mouse 两条路径对同一点击会触发两次)
    std::vector<InputEvent> merged;
    for (auto& ev : batch) {
        if (!merged.empty()) {
            auto& last = merged.back();
            if (last.type == ev.type) {
                bool skip = false;
                switch (ev.type) {
                    case InputEvent::PTR_BUTTON:
                        skip = (last.button_or_key == ev.button_or_key && last.state == ev.state);
                        break;
                    case InputEvent::PTR_MOTION:
                        last = ev; continue;  // 连续 motion 只保留最后一个
                    case InputEvent::PTR_ENTER:
                        skip = (last.toplevelId == ev.toplevelId && last.surface == ev.surface);
                        break;
                    default: break;
                }
                if (skip) continue;
            }
        }
        merged.push_back(ev);
    }
    if (merged.size() != batch.size()) {
        OH_LOG_INFO(LOG_APP, "[Seat] dedup %{public}zu->%{public}zu events", batch.size(), merged.size());
    }

    if (!merged.empty()) {
        OH_LOG_INFO(LOG_APP, "[Seat]  CLICK-PIPE flush %{public}zu events firstType=%{public}d",
                    merged.size(), (int)merged[0].type);
    }
    for (auto& ev : merged) {
        switch (ev.type) {
            case InputEvent::PTR_ENTER:
                InjectPointerEnter(ev.toplevelId, ev.surface, ev.x, ev.y);
                break;
            case InputEvent::PTR_LEAVE:
                InjectPointerLeave();
                break;
            case InputEvent::PTR_MOTION:
                InjectPointerMotion(ev.x, ev.y);
                break;
            case InputEvent::PTR_BUTTON:
                InjectPointerButton(ev.button_or_key, ev.state);
                break;
            case InputEvent::PTR_AXIS:
                InjectPointerAxis(ev.button_or_key, ev.y);
                break;
            case InputEvent::KBD_ENTER:
                InjectKeyboardEnter(ev.toplevelId, ev.surface);
                break;
            case InputEvent::KBD_LEAVE:
                InjectKeyboardLeave();
                break;
            case InputEvent::KBD_KEY:
                InjectKeyboardKey(ev.button_or_key, ev.state);
                break;
        }
    }

    // 立即发送给 Wine
    if (display_) wl_display_flush_clients(display_);
}

// -- 真实事件注入 (Wayland 线程调用) --

void Seat::InjectPointerEnter(uint32_t toplevelId, wl_resource* surface, wl_fixed_t sx, wl_fixed_t sy) {
    if (!surface) return;
    if (!pointerResource_.load()) {
        OH_LOG_WARN(LOG_APP, "[Seat] ERR enter dropped: no wl_pointer resource (Wine hasn't created or already destroyed)");
        return;
    }
    focusedToplevel_ = toplevelId;
    focusedSurface_ = surface;
    uint32_t s = serial_++;
    pointerEnterSerial_ = s;
    OH_LOG_INFO(LOG_APP, "[CLICK-PIPE]  [InjectEnter] tl=%{public}u serial=%{public}u sx=%{public}.1f sy=%{public}.1f -> wl_pointer_send_enter",
                toplevelId, s, wl_fixed_to_double(sx), wl_fixed_to_double(sy));
    wl_pointer_send_enter(pointerResource_.load(), s, surface, sx, sy);
    wl_pointer_send_frame(pointerResource_);
    OH_LOG_INFO(LOG_APP, "[CLICK-PIPE]  [InjectEnter] done OK");
}

void Seat::InjectPointerMotion(wl_fixed_t sx, wl_fixed_t sy) {
    if (!pointerResource_.load()) {
        static int motionDropCount = 0;
        if (++motionDropCount <= 3)
            OH_LOG_WARN(LOG_APP, "[Seat] ERR motion dropped: no wl_pointer (%{public}d/3)", motionDropCount);
        return;
    }
    wl_pointer_send_motion(pointerResource_.load(), NowMs(), sx, sy);
    wl_pointer_send_frame(pointerResource_);
}

void Seat::InjectPointerButton(uint32_t button, uint32_t state) {
    if (!pointerResource_.load()) {
        OH_LOG_WARN(LOG_APP, "[Seat] ERR button dropped btn=0x%{public}x state=%{public}u: no wl_pointer", button, state);
        return;
    }
    // button 必须用最近一次 enter 的 serial (Wayland 协议要求)
    uint32_t enterSerial = pointerEnterSerial_.load(std::memory_order_relaxed);
    uint32_t s = enterSerial ? enterSerial : serial_++;
    OH_LOG_INFO(LOG_APP, "[CLICK-PIPE]  [InjectButton] btn=0x%{public}x state=%{public}u serial=%{public}u -> wl_pointer_send_button",
                button, state, s);
    wl_pointer_send_button(pointerResource_.load(), s, NowMs(), button, state);
    wl_pointer_send_frame(pointerResource_);
    OH_LOG_INFO(LOG_APP, "[CLICK-PIPE]  [InjectButton] done OK (wl_pointer_send_button sent)");
}

void Seat::InjectPointerLeave() {
    if (!pointerResource_.load() || !focusedSurface_) return;
    uint32_t s = serial_++;
    wl_pointer_send_leave(pointerResource_.load(), s, focusedSurface_);
    focusedToplevel_ = 0;
    focusedSurface_ = nullptr;
    pointerEnterSerial_ = 0;
}

void Seat::InjectPointerAxis(uint32_t axis, wl_fixed_t value) {
    if (!pointerResource_.load()) return;
    wl_pointer_send_axis_source(pointerResource_.load(), WL_POINTER_AXIS_SOURCE_WHEEL);
    wl_pointer_send_axis(pointerResource_.load(), NowMs(), axis, value);
    wl_pointer_send_frame(pointerResource_);
}

void Seat::InjectKeyboardEnter(uint32_t toplevelId, wl_resource* surface) {
    if (!keyboardResource_.load() || !surface) return;
    keyboardFocusedToplevel_ = toplevelId;
    keyboardFocusedSurface_ = surface;
    keyboardEntered_ = true;
    uint32_t s = serial_++;

    wl_array keys;
    wl_array_init(&keys);
    wl_keyboard_send_enter(keyboardResource_.load(), s, surface, &keys);
    wl_array_release(&keys);

    wl_keyboard_send_modifiers(keyboardResource_, s, 0, 0, 0, 0);
    OH_LOG_INFO(LOG_APP, "[Seat] kbd_enter tl=%{public}u serial=%{public}u OK", toplevelId, s);
}

void Seat::InjectKeyboardKey(uint32_t key, uint32_t state) {
    if (!keyboardResource_.load()) return;
    uint32_t s = serial_++;
    OH_LOG_INFO(LOG_APP, "[Seat] key key=%{public}u state=%{public}u serial=%{public}u", key, state, s);
    wl_keyboard_send_key(keyboardResource_.load(), s, NowMs(), key, state);
}

void Seat::InjectKeyboardLeave() {
    if (!keyboardResource_.load() || !keyboardEntered_) return;
    uint32_t s = serial_++;
    wl_keyboard_send_leave(keyboardResource_.load(), s, keyboardFocusedSurface_);
    keyboardEntered_ = false;
    keyboardFocusedToplevel_ = 0;
    keyboardFocusedSurface_ = nullptr;
    OH_LOG_INFO(LOG_APP, "[Seat] kbd_leave OK");
}

// -- Keycode 映射: OHOS KEY_* -> Linux evdev scancode --
uint32_t Seat::MapKeycode(int32_t ohos) {
    // OHOS keycode 范围 ~2000-2122, evdev 1-255
    switch (ohos) {
        // -- 数字行 --
        case 2000: return 11;   // KEYCODE_0 -> KEY_0
        case 2001: return 2;    // KEYCODE_1 -> KEY_1
        case 2002: return 3;    // KEYCODE_2 -> KEY_2
        case 2003: return 4;    // KEYCODE_3 -> KEY_3
        case 2004: return 5;    // KEYCODE_4 -> KEY_4
        case 2005: return 6;    // KEYCODE_5 -> KEY_5
        case 2006: return 7;    // KEYCODE_6 -> KEY_6
        case 2007: return 8;    // KEYCODE_7 -> KEY_7
        case 2008: return 9;    // KEYCODE_8 -> KEY_8
        case 2009: return 10;   // KEYCODE_9 -> KEY_9

        // -- 方向键 --
        case 2012: return 103;  // KEY_DPAD_UP     -> KEY_UP
        case 2013: return 108;  // KEY_DPAD_DOWN   -> KEY_DOWN
        case 2014: return 105;  // KEY_DPAD_LEFT   -> KEY_LEFT
        case 2015: return 106;  // KEY_DPAD_RIGHT  -> KEY_RIGHT

        // -- 字母 A-Z (2017-2042) -> evdev 30-44 + 46-49 --
        // 注意: evdev 按键码不连续 (KEY_Q=16, KEY_W=17, ...)
        // 实际上 evdev 布局: Q=16 W=17 E=18 R=19 T=20 Y=21 U=22 I=23 O=24 P=25
        // A=30 B=48 C=46 D=32 E=18 F=33 G=34 H=35 I=23 J=36 K=37 L=38
        // M=50 N=49 O=24 P=25 Q=16 R=19 S=31 T=20 U=22 V=47 W=17 X=45 Y=21 Z=44

        case 2017: return 30;   // KEY_A -> KEY_A
        case 2018: return 48;   // KEY_B -> KEY_B
        case 2019: return 46;   // KEY_C -> KEY_C
        case 2020: return 32;   // KEY_D -> KEY_D
        case 2021: return 18;   // KEY_E -> KEY_E
        case 2022: return 33;   // KEY_F -> KEY_F
        case 2023: return 34;   // KEY_G -> KEY_G
        case 2024: return 35;   // KEY_H -> KEY_H
        case 2025: return 23;   // KEY_I -> KEY_I
        case 2026: return 36;   // KEY_J -> KEY_J
        case 2027: return 37;   // KEY_K -> KEY_K
        case 2028: return 38;   // KEY_L -> KEY_L
        case 2029: return 50;   // KEY_M -> KEY_M
        case 2030: return 49;   // KEY_N -> KEY_N
        case 2031: return 24;   // KEY_O -> KEY_O
        case 2032: return 25;   // KEY_P -> KEY_P
        case 2033: return 16;   // KEY_Q -> KEY_Q
        case 2034: return 19;   // KEY_R -> KEY_R
        case 2035: return 31;   // KEY_S -> KEY_S
        case 2036: return 20;   // KEY_T -> KEY_T
        case 2037: return 22;   // KEY_U -> KEY_U
        case 2038: return 47;   // KEY_V -> KEY_V
        case 2039: return 17;   // KEY_W -> KEY_W
        case 2040: return 45;   // KEY_X -> KEY_X
        case 2041: return 21;   // KEY_Y -> KEY_Y
        case 2042: return 44;   // KEY_Z -> KEY_Z

        // -- 标点/符号 --
        case 2043: return 51;   // KEY_COMMA        -> KEY_COMMA
        case 2044: return 52;   // KEY_PERIOD       -> KEY_DOT
        case 2056: return 41;   // KEY_GRAVE        -> KEY_GRAVE
        case 2057: return 12;   // KEY_MINUS        -> KEY_MINUS
        case 2058: return 13;   // KEY_EQUALS       -> KEY_EQUAL
        case 2059: return 26;   // KEY_LEFT_BRACKET  -> KEY_LEFTBRACE
        case 2060: return 27;   // KEY_RIGHT_BRACKET -> KEY_RIGHTBRACE
        case 2061: return 43;   // KEY_BACKSLASH    -> KEY_BACKSLASH
        case 2062: return 39;   // KEY_SEMICOLON    -> KEY_SEMICOLON
        case 2063: return 40;   // KEY_APOSTROPHE   -> KEY_APOSTROPHE
        case 2064: return 53;   // KEY_SLASH        -> KEY_SLASH
        case 2065: return 2;    // KEY_AT           -> KEY_1 (shift needed)
        case 2066: return 13;   // KEY_PLUS         -> KEY_EQUAL (shift needed)

        // -- 修饰键 --
        case 2045: return 56;   // KEY_ALT_LEFT     -> KEY_LEFTALT
        case 2046: return 100;  // KEY_ALT_RIGHT    -> KEY_RIGHTALT
        case 2047: return 42;   // KEY_SHIFT_LEFT   -> KEY_LEFTSHIFT
        case 2048: return 54;   // KEY_SHIFT_RIGHT  -> KEY_RIGHTSHIFT
        case 2072: return 29;   // KEY_CTRL_LEFT    -> KEY_LEFTCTRL
        case 2073: return 97;   // KEY_CTRL_RIGHT   -> KEY_RIGHTCTRL
        case 2074: return 58;   // KEY_CAPS_LOCK    -> KEY_CAPSLOCK
        case 2076: return 125;  // KEY_META_LEFT    -> KEY_LEFTMETA
        case 2077: return 126;  // KEY_META_RIGHT   -> KEY_RIGHTMETA

        // -- 常用键 --
        case 2049: return 15;   // KEY_TAB          -> KEY_TAB
        case 2050: return 57;   // KEY_SPACE        -> KEY_SPACE
        case 2054: return 28;   // KEY_ENTER        -> KEY_ENTER
        case 2070: return 1;    // KEY_ESCAPE       -> KEY_ESC
        case 2055: return 14;   // KEY_DEL          -> KEY_BACKSPACE
        case 2071: return 111;  // KEY_FORWARD_DEL  -> KEY_DELETE
        case 2067: return 139;  // KEY_MENU         -> KEY_MENU

        // -- 导航键 --
        case 2068: return 104;  // KEY_PAGE_UP      -> KEY_PAGEUP
        case 2069: return 109;  // KEY_PAGE_DOWN    -> KEY_PAGEDOWN
        case 2081: return 102;  // KEY_MOVE_HOME    -> KEY_HOME
        case 2082: return 107;  // KEY_MOVE_END     -> KEY_END
        case 2083: return 110;  // KEY_INSERT       -> KEY_INSERT
        case 2052: return 150;  // KEY_EXPLORER     -> KEY_WWW
        case 2053: return 155;  // KEY_ENVELOPE     -> KEY_MAIL
        case 2084: return 159;  // KEY_FORWARD      -> KEY_FORWARD

        // -- F1-F12 --
        case 2090: return 59;   case 2091: return 60;
        case 2092: return 61;   case 2093: return 62;
        case 2094: return 63;   case 2095: return 64;
        case 2096: return 65;   case 2097: return 66;
        case 2098: return 67;   case 2099: return 68;
        case 2100: return 87;   // KEY_F11 -> KEY_F11
        case 2101: return 88;   // KEY_F12 -> KEY_F12

        // -- 小键盘 --
        case 2102: return 69;   // KEY_NUM_LOCK       -> KEY_NUMLOCK
        case 2103: return 82;   // KEY_NUMPAD_0       -> KEY_KP0
        case 2104: return 79;   // KEY_NUMPAD_1       -> KEY_KP1
        case 2105: return 80;   // KEY_NUMPAD_2       -> KEY_KP2
        case 2106: return 81;   // KEY_NUMPAD_3       -> KEY_KP3
        case 2107: return 75;   // KEY_NUMPAD_4       -> KEY_KP4
        case 2108: return 76;   // KEY_NUMPAD_5       -> KEY_KP5
        case 2109: return 77;   // KEY_NUMPAD_6       -> KEY_KP6
        case 2110: return 71;   // KEY_NUMPAD_7       -> KEY_KP7
        case 2111: return 72;   // KEY_NUMPAD_8       -> KEY_KP8
        case 2112: return 73;   // KEY_NUMPAD_9       -> KEY_KP9
        case 2113: return 98;   // KEY_NUMPAD_DIVIDE  -> KEY_KPSLASH
        case 2114: return 55;   // KEY_NUMPAD_MULTIPLY-> KEY_KPASTERISK
        case 2115: return 74;   // KEY_NUMPAD_SUBTRACT-> KEY_KPMINUS
        case 2116: return 78;   // KEY_NUMPAD_ADD     -> KEY_KPPLUS
        case 2117: return 83;   // KEY_NUMPAD_DOT     -> KEY_KPDOT
        case 2119: return 96;   // KEY_NUMPAD_ENTER   -> KEY_KPENTER

        // -- 媒体键 (少用, 映射到 evdev 对应) --
        case 2085: return 207;  // KEY_MEDIA_PLAY     -> KEY_PLAY
        case 2086: return 119;  // KEY_MEDIA_PAUSE    -> KEY_PAUSE
        case 2087: return 128;  // KEY_MEDIA_CLOSE    -> KEY_STOP
        case 2089: return 167;  // KEY_MEDIA_RECORD   -> KEY_RECORD

        // -- 系统键 --
        case 2051: return 99;   // KEY_SYM           -> KEY_SYSRQ

        default:
            OH_LOG_WARN(LOG_APP, "[Seat] unmapped keycode: %{public}d", ohos);
            return 0;  // KEY_RESERVED
    }
}
