#pragma once
#include <wayland-server-core.h>
#include <wayland-server-protocol.h>
#include <string>
#include <thread>
#include <mutex>
#include <vector>
#include <functional>
#include <atomic>
#include <cstdint>

// 最小 Wayland Compositor: wl_compositor + wl_surface + wl_shm
class WaylandServer {
public:
    using StateCb = std::function<void(const char*)>;

    static WaylandServer* GetInstance();

    bool Start(const std::string& socketPath);
    void Stop();

    // EglRenderer 调用: 取最新一帧像素
    bool TakeFrame(std::vector<uint8_t>& outPixels, int& w, int& h);

    // 状态回调 (首帧到达 → 通知 ArkTS)
    void SetStateCallback(StateCb cb) { stateCb_ = std::move(cb); }
    void FireState(const char* s) { if (stateCb_) stateCb_(s); }
    void ResetFirstFrame() { firstFrame_ = false; }

    // ── wayland 协议实现 ──
    static void compositor_bind(wl_client*, void*, uint32_t, uint32_t);
    static void compositor_create_surface(wl_client*, wl_resource*, uint32_t);
    static void compositor_create_region(wl_client*, wl_resource*, uint32_t);

    static void surface_destroy(wl_client*, wl_resource*);
    static void surface_attach(wl_client*, wl_resource*, wl_resource*, int32_t, int32_t);
    static void surface_damage(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t);
    static void surface_frame(wl_client*, wl_resource*, uint32_t);
    static void surface_commit(wl_client*, wl_resource*);
    static void surface_set_opaque_region(wl_client*, wl_resource*, wl_resource*) {}
    static void surface_set_input_region(wl_client*, wl_resource*, wl_resource*) {}
    static void surface_set_buffer_transform(wl_client*, wl_resource*, int32_t) {}
    static void surface_set_buffer_scale(wl_client*, wl_resource*, int32_t) {}
    static void surface_damage_buffer(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}
    static void surface_offset(wl_client*, wl_resource*, int32_t, int32_t) {}

    static void region_destroy(wl_client*, wl_resource*) {}
    static void region_add(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}
    static void region_subtract(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}

    /* wl_subcompositor */
    static void subcompositor_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    static void subcompositor_get_subsurface(wl_client*, wl_resource*, uint32_t, wl_resource*, wl_resource*);
    /* wl_subsurface */
    static void subsurface_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    static void subsurface_set_position(wl_client*, wl_resource*, int32_t, int32_t) {}
    static void subsurface_place_above(wl_client*, wl_resource*, wl_resource*) {}
    static void subsurface_place_below(wl_client*, wl_resource*, wl_resource*) {}
    static void subsurface_set_sync(wl_client*, wl_resource*) {}
    static void subsurface_set_desync(wl_client*, wl_resource*) {}

    /* wp_viewporter */
    static void viewporter_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    static void viewporter_get_viewport(wl_client*, wl_resource*, uint32_t, wl_resource*);
    /* wp_viewport */
    static void viewport_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    static void viewport_set_source(wl_client*, wl_resource*, wl_fixed_t, wl_fixed_t, wl_fixed_t, wl_fixed_t) {}
    static void viewport_set_destination(wl_client*, wl_resource*, int32_t, int32_t) {}

    /* Globals bind */
    static void subcompositor_bind(wl_client*, void*, uint32_t, uint32_t);
    static void viewporter_bind(wl_client*, void*, uint32_t, uint32_t);
    static void output_bind(wl_client*, void*, uint32_t, uint32_t);
    /* wl_output */
    static void output_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }

private:
    WaylandServer() = default;
    void EventLoop();

    wl_display* display_ = nullptr;
    std::thread thread_;
    std::atomic<bool> running_{false};

    // 帧缓冲 (surface_commit → TakeFrame)
    std::mutex mutex_;
    std::vector<uint8_t> pixels_;
    int width_ = 0, height_ = 0;
    std::atomic<bool> dirty_{false};

    StateCb stateCb_;
    std::atomic<bool> firstFrame_{false};
};

// wl_surface 的每个实例携带的数据
struct SurfaceData {
    wl_resource* surface = nullptr;
    wl_resource* pendingBuffer = nullptr;
    std::vector<wl_resource*> frameCallbacks;
};
