#pragma once

#include "graphics_types.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <wayland-server-core.h>
#include <wayland-server-protocol.h>

class WaylandServer {
public:
    enum class SceneSurfaceSource {
        CompatToplevel = 0,
        RawSurface = 1,
        SubsurfaceLayer = 2,
    };

    struct SceneSurfaceSnapshot {
        uint64_t cacheKey = 0;
        uint32_t toplevelId = 0;
        int x = 0;
        int y = 0;
        int width = 0;
        int height = 0;
        uint32_t shmFormat = WL_SHM_FORMAT_XRGB8888;
        uint64_t bufferSerial = 0;
        uint64_t damageSerial = 0;
        bool opaque = true;
        bool isRoot = false;
        bool isSubsurface = false;
        SceneSurfaceSource source = SceneSurfaceSource::CompatToplevel;
        std::shared_ptr<const std::vector<uint8_t>> pixels;
        std::vector<winehua::DamageRect> damages;
    };

    struct SceneSnapshot {
        bool desktopMode = false;
        uint32_t rootToplevelId = 0;
        int canvasWidth = 0;
        int canvasHeight = 0;
        uint64_t sceneSerial = 0;
        std::vector<SceneSurfaceSnapshot> surfaces;
    };

    struct CopyStats {
        uint64_t surfaceCommitCount = 0;
        uint64_t surfaceCommitBytes = 0;
        uint64_t snapshotCopyCount = 0;
        uint64_t snapshotCopyBytes = 0;
    };

    using StateCb = std::function<void(const char*)>;
    using ToplevelCb = std::function<void(uint32_t, const char*, const char*)>;

    static WaylandServer* GetInstance();

    wl_display* GetDisplay() const { return display_; }

    bool Start(const std::string& socketPath);
    void Stop();

    bool TakeFrame(std::vector<uint8_t>& outPixels, int& w, int& h);
    bool TakeToplevelFrame(uint32_t toplevelId, std::vector<uint8_t>& outPixels, int& w, int& h);
    bool GetSceneSnapshot(uint32_t rendererToplevelId, SceneSnapshot& outSnapshot);
    CopyStats GetGraphicsCopyStats() const;

    void SetStateCallback(StateCb cb) { stateCb_ = std::move(cb); }
    void FireState(const char* s) { if (stateCb_) stateCb_(s); }
    void ResetFirstFrame() { firstFrame_ = false; }

    void SetToplevelCallback(ToplevelCb cb) { toplevelCb_ = std::move(cb); }
    void FireToplevelEvent(uint32_t id, const char* event, const char* jsonData = "{}");

    uint32_t NextToplevelId() { return nextToplevelId_++; }

    void RegisterToplevelResource(uint32_t toplevelId, wl_resource* tl);
    void UnregisterToplevelResource(uint32_t toplevelId);
    void OnToplevelDestroyed(uint32_t toplevelId);
    void SendToplevelClose(uint32_t toplevelId);
    void NotifyWindowRestored(uint32_t toplevelId);
    void NotifyToplevelResize(uint32_t toplevelId, int32_t w, int32_t h);

    void SetOutputSize(int32_t w, int32_t h) { outputW_ = w; outputH_ = h; }
    int32_t outputW_ = 1280;
    int32_t outputH_ = 720;

    uint32_t FindToplevelAt(int x, int y);
    void RaiseToplevel(uint32_t id);
    int GetToplevelX(uint32_t id) { std::lock_guard<std::mutex> lk(toplevelMutex_); return toplevelX_[id]; }
    int GetToplevelY(uint32_t id) { std::lock_guard<std::mutex> lk(toplevelMutex_); return toplevelY_[id]; }

    void SetDesktopMode(bool on) { desktopMode_ = on; }
    bool IsDesktopMode() const { return desktopMode_; }
    void SetDesktopRootToplevelId(uint32_t id) { desktopRootToplevelId_ = id; }
    uint32_t GetDesktopRootToplevelId() const { return desktopRootToplevelId_; }

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
    static void surface_damage_buffer(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t);
    static void surface_offset(wl_client*, wl_resource*, int32_t, int32_t) {}

    static void region_destroy(wl_client*, wl_resource*) {}
    static void region_add(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}
    static void region_subtract(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}

    static void subcompositor_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    static void subcompositor_get_subsurface(wl_client*, wl_resource*, uint32_t, wl_resource*, wl_resource*);

    static void subsurface_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    static void subsurface_set_position(wl_client*, wl_resource*, int32_t, int32_t);
    static void subsurface_place_above(wl_client*, wl_resource*, wl_resource*) {}
    static void subsurface_place_below(wl_client*, wl_resource*, wl_resource*) {}
    static void subsurface_set_sync(wl_client*, wl_resource*) {}
    static void subsurface_set_desync(wl_client*, wl_resource*) {}

    static void viewporter_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    static void viewporter_get_viewport(wl_client*, wl_resource*, uint32_t, wl_resource*);

    static void viewport_destroy(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    static void viewport_set_source(wl_client*, wl_resource*, wl_fixed_t, wl_fixed_t, wl_fixed_t, wl_fixed_t) {}
    static void viewport_set_destination(wl_client*, wl_resource*, int32_t, int32_t) {}

    static void subcompositor_bind(wl_client*, void*, uint32_t, uint32_t);
    static void viewporter_bind(wl_client*, void*, uint32_t, uint32_t);
    static void output_bind(wl_client*, void*, uint32_t, uint32_t);
    static void output_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }

    wl_resource* GetSurfaceForToplevel(uint32_t toplevelId);

private:
    WaylandServer() = default;
    void EventLoop();
    void ResetCopyStats();
    void AddSurfaceCommitBytes(size_t bytes);
    void AddSnapshotCopyBytes(size_t bytes);
    bool MaterializeCompatToplevelFrameLocked(uint32_t toplevelId,
                                              std::vector<uint8_t>& outPixels,
                                              int& w,
                                              int& h);
    bool MaterializeDesktopRootFrameLocked(uint32_t toplevelId,
                                           std::vector<uint8_t>& outPixels,
                                           int& w,
                                           int& h);

    wl_display* display_ = nullptr;
    std::thread thread_;
    std::atomic<bool> running_{false};

    std::mutex mutex_;
    std::vector<uint8_t> pixels_;
    int width_ = 0;
    int height_ = 0;
    std::atomic<bool> dirty_{false};

    std::mutex toplevelMutex_;
    std::unordered_map<uint32_t, std::vector<uint8_t>> toplevelPixels_;
    std::unordered_map<uint32_t, std::shared_ptr<const std::vector<uint8_t>>> toplevelCanonicalPixels_;
    std::unordered_map<uint32_t, int> toplevelW_;
    std::unordered_map<uint32_t, int> toplevelH_;
    std::unordered_map<uint32_t, int> toplevelX_;
    std::unordered_map<uint32_t, int> toplevelY_;
    std::unordered_map<uint32_t, uint64_t> toplevelBufferSerial_;
    std::unordered_map<uint32_t, uint64_t> toplevelDamageSerial_;
    std::unordered_map<uint32_t, std::vector<winehua::DamageRect>> toplevelDamages_;
    std::unordered_map<uint32_t, bool> toplevelDirty_;
    std::unordered_map<uint32_t, int> toplevelLastReportedW_;
    std::unordered_map<uint32_t, int> toplevelLastReportedH_;

    StateCb stateCb_;
    ToplevelCb toplevelCb_;
    std::atomic<bool> firstFrame_{false};
    std::atomic<uint32_t> nextToplevelId_{1};
    std::unordered_map<uint32_t, wl_resource*> toplevelResources_;
    std::mutex toplevelResMutex_;

    std::unordered_map<uint32_t, wl_resource*> toplevelSurfaceMap_;
    std::mutex toplevelSurfaceMutex_;

    bool desktopMode_ = false;
    uint32_t desktopRootToplevelId_ = 0;

    struct SubsurfaceLayer {
        wl_resource* surface = nullptr;
        uint32_t parentToplevelId = 0;
        std::shared_ptr<std::vector<uint8_t>> pixels;
        int x = 0;
        int y = 0;
        int w = 0;
        int h = 0;
        uint32_t shmFormat = WL_SHM_FORMAT_XRGB8888;
        uint64_t bufferSerial = 0;
        uint64_t damageSerial = 0;
        bool opaque = true;
        std::vector<winehua::DamageRect> damages;
    };

    std::vector<SubsurfaceLayer> subsurfaceLayers_;
    std::vector<uint32_t> toplevelZOrder_;
    uint64_t sceneSerial_ = 0;
    uint32_t lastCommittedToplevelId_ = 0;
    std::atomic<uint64_t> surfaceCommitCount_{0};
    std::atomic<uint64_t> surfaceCommitBytes_{0};
    std::atomic<uint64_t> snapshotCopyCount_{0};
    std::atomic<uint64_t> snapshotCopyBytes_{0};
};

struct SurfaceData {
    wl_resource* surface = nullptr;
    wl_resource* pendingBuffer = nullptr;
    std::vector<wl_resource*> frameCallbacks;

    std::shared_ptr<std::vector<uint8_t>> pixels = std::make_shared<std::vector<uint8_t>>();
    int bufferW = 0;
    int bufferH = 0;
    int w = 0;
    int h = 0;
    int contentOffsetX = 0;
    int contentOffsetY = 0;
    uint32_t bufferFormat = WL_SHM_FORMAT_XRGB8888;
    bool dirty = false;
    bool opaque = true;
    uint64_t bufferSerial = 0;
    uint64_t damageSerial = 0;
    std::vector<winehua::DamageRect> pendingDamages;
    std::vector<winehua::DamageRect> committedDamages;

    uint32_t toplevelId = 0;
    bool hasToplevel = false;
    std::string title;
    int x = 0;
    int y = 0;
    int winW = 640;
    int winH = 480;

    bool hasWindowGeometry = false;
    int geoX = 0;
    int geoY = 0;
    int geoW = 0;
    int geoH = 0;

    wl_resource* parentSurface = nullptr;
    int32_t subsurfaceX = 0;
    int32_t subsurfaceY = 0;
    bool isSubsurface = false;

    bool minimized = false;
    bool maximized = false;

    bool hasSizeLimits = false;
    int32_t minWidth = 0;
    int32_t minHeight = 0;
    int32_t maxWidth = 0;
    int32_t maxHeight = 0;
};
