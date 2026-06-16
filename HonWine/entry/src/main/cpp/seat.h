#pragma once
#include <wayland-server-core.h>
#include <wayland-server-protocol.h>
#include <cstdint>
#include <atomic>
#include <unordered_map>
#include <mutex>
#include <vector>

// 管理 wl_seat global + wl_pointer/wl_keyboard 设备, 接收 PluginManager 注入的输入事件
//
// 线程模型:
//   - NAPI 主线程:  捕捉 XComponent 事件, 做坐标转换/surface 查找, 然后 Enqueue* 到队列
//   - Wayland 线程:  从队列取出事件, 调用 wl_*_send_* 发送给 Wine
//   所有 wl_*_send_* 必须在 Wayland 线程调用, 避免 socket 阻塞主线程和数据竞争

class Seat {
public:
    static Seat* GetInstance();

    void Register(wl_display* display);
    void Unregister();

    // -- 查询 (NAPI 线程安全, 只读) --
    bool HasPointerResource() const { return pointerResource_.load() != nullptr; }
    bool NeedsPointerEnter() const { return pointerResource_.load() && pointerEnterSerial_ == 0; }
    uint32_t GetFocusedToplevel() const { return focusedToplevel_; }

    bool HasKeyboardEnter() const { return keyboardEntered_; }
    uint32_t GetKeyboardFocusedToplevel() const { return keyboardFocusedToplevel_; }

    // -- 入队 (NAPI 线程调用, 非阻塞) --
    void EnqueuePointerEnter(uint32_t toplevelId, wl_resource* surface, wl_fixed_t sx, wl_fixed_t sy);
    void EnqueuePointerLeave();
    void EnqueuePointerMotion(wl_fixed_t sx, wl_fixed_t sy);
    void EnqueuePointerButton(uint32_t button, uint32_t state);
    void EnqueuePointerAxis(uint32_t axis, wl_fixed_t value);
    void EnqueueKeyboardEnter(uint32_t toplevelId, wl_resource* surface);
    void EnqueueKeyboardLeave();
    void EnqueueKeyboardKey(uint32_t key, uint32_t state);

    // -- 内部: Wayland 线程调用的真正 inject --
    void InjectPointerEnter(uint32_t toplevelId, wl_resource* surface, wl_fixed_t sx, wl_fixed_t sy);
    void InjectPointerMotion(wl_fixed_t sx, wl_fixed_t sy);
    void InjectPointerButton(uint32_t button, uint32_t state);
    void InjectPointerLeave();
    void InjectPointerAxis(uint32_t axis, wl_fixed_t value);

    void InjectKeyboardEnter(uint32_t toplevelId, wl_resource* surface);
    void InjectKeyboardKey(uint32_t key, uint32_t state);
    void InjectKeyboardLeave();

    // OHOS KEY_* -> Linux evdev scancode
    static uint32_t MapKeycode(int32_t ohosKeycode);

    // wl_seat bind 回调 (注册为 wl_global_create 的 bind)
    static void seat_bind(wl_client* client, void* data, uint32_t version, uint32_t id);

    // wl_seat_interface 方法 (通过函数指针表调用, 需 public)
    static void seat_get_pointer(wl_client*, wl_resource*, uint32_t id);
    static void seat_get_keyboard(wl_client*, wl_resource*, uint32_t id);
    static void seat_get_touch(wl_client*, wl_resource*, uint32_t id);
    static void seat_release(wl_client*, wl_resource*);

private:
    Seat() = default;

    // resource destructors
    static void pointer_destroy(wl_resource*);
    static void keyboard_destroy(wl_resource*);

    // -- 事件队列 (NAPI -> Wayland 线程) --
    struct InputEvent {
        enum Type { PTR_ENTER, PTR_LEAVE, PTR_MOTION, PTR_BUTTON, PTR_AXIS, KBD_ENTER, KBD_LEAVE, KBD_KEY } type;
        uint32_t toplevelId = 0;
        wl_resource* surface = nullptr;
        wl_fixed_t x = 0, y = 0;
        uint32_t button_or_key = 0;
        uint32_t state = 0;
    };
    std::mutex queueMutex_;
    std::vector<InputEvent> queue_;
    int pipeRead_ = -1;   // Wayland 线程读
    int pipeWrite_ = -1;  // NAPI 线程写
    struct wl_event_source* pipeSource_ = nullptr;

    void Enqueue(InputEvent::Type type, uint32_t tl, wl_resource* surface,
                 wl_fixed_t x, wl_fixed_t y, uint32_t button_or_key, uint32_t state);
    void FlushQueue();  // Wayland 线程回调
    static int OnPipeReadable(int fd, uint32_t mask, void* data);

    wl_global* global_ = nullptr;
    wl_display* display_ = nullptr;

    // 单 client, pointer/keyboard 各一个 resource
    // atomic: Wayland 线程创建, NAPI 线程读取 (HasPointerResource/HasKeyboardEnter)
    wl_resource* seatResource_ = nullptr;
    std::atomic<wl_resource*> pointerResource_{nullptr};
    std::atomic<wl_resource*> keyboardResource_{nullptr};

    // pointer focus tracking
    std::atomic<uint32_t> focusedToplevel_{0};
    wl_resource* focusedSurface_ = nullptr;
    std::atomic<uint32_t> serial_{1};
    std::atomic<uint32_t> pointerEnterSerial_{0};

    // keyboard focus tracking (独立于 pointer)
    std::atomic<uint32_t> keyboardFocusedToplevel_{0};
    wl_resource* keyboardFocusedSurface_ = nullptr;
    std::atomic<bool> keyboardEntered_{false};
};
