#pragma once

#include "frame_presenter.h"

#include <atomic>
#include <cstdint>
#include <optional>
#include <mutex>
#include <string>
#include <vector>

namespace winehua {

enum class GraphicsBackend
{
    Auto = 0,
    Shm = 1,
    Virgl = 2,
};

struct GraphicsBackendState
{
    GraphicsBackend requested = GraphicsBackend::Auto;
    GraphicsBackend active = GraphicsBackend::Shm;
    std::string backend;
    std::string presenter;
    bool runtimeReady = false;
    bool guestReceiverPresent = false;
    bool virglSocketReady = false;
    bool virglLibraryPresent = false;
    bool virglSmokeAttempted = false;
    bool virglSmokeSucceeded = false;
    bool fallbackActive = false;
    bool damageUploadActive = false;
    bool zeroCopyFramePath = false;
    bool nativeBufferInUse = false;
    std::string runtimeDir;
    std::string guestReceiverRuntimeDir;
    std::string guestReceiverMode;
    std::string guestReceiverError;
    std::string virglSocketPath;
    std::string virglLibraryPath;
    std::string frameTransportMode;
    std::string virglSmokeError;
    std::string lastError;
    BackendCaps caps;
    GraphicsStats stats;
};

class GraphicsBroker
{
public:
    static GraphicsBroker& GetInstance();

    bool EnsureStarted(const std::string& runtimeDir);
    void Stop();
    void SetWineRuntimeBinaryDir(const std::string& wineBinDir);

    void SetRequestedBackend(GraphicsBackend backend);
    void SetPresenterOverride(std::optional<FramePresenterPath> presenterPath);
    std::optional<FramePresenterPath> GetPresenterOverride() const;
    GraphicsBackendState GetState() const;
    void ReportPresenterState(FramePresenterPath path,
                              bool fallbackActive,
                              bool damageUploadActive,
                              bool zeroCopyFramePath,
                              bool nativeBufferInUse,
                              const BackendCaps& caps,
                              const GraphicsStats& stats,
                              const std::string& transportMode,
                              const std::string& note);

    void AppendWineEnv(std::vector<std::string>& env) const;
    std::vector<std::string> BuildWineEnvOverrides() const;
    bool TakeFrameForToplevel(uint32_t rendererToplevelId,
                              std::vector<uint8_t>& outPixels,
                              int& w,
                              int& h,
                              uint32_t* outSourceToplevelId = nullptr);

    static const char* BackendName(GraphicsBackend backend);
    static bool ParseBackendName(const std::string& name, GraphicsBackend* outBackend);

private:
    GraphicsBroker();
    GraphicsBroker(const GraphicsBroker&) = delete;
    GraphicsBroker& operator=(const GraphicsBroker&) = delete;

    bool EnsureRuntimeLocked(const std::string& runtimeDir);
    bool IsVirglServerProcessAliveLocked();
    void RefreshVirglStateLocked();
    void RefreshGuestReceiverStateLocked();
    void ProbeVirglRuntimeSmokeLocked();
    void StartVirglSocketServerLocked();
    void UpdateActiveBackendLocked();
    std::string ProbeVirglLibraryLocked(bool* outLoaded) const;

    mutable std::mutex mutex_;
    GraphicsBackend requestedBackend_ = GraphicsBackend::Auto;
    GraphicsBackend activeBackend_ = GraphicsBackend::Shm;
    bool started_ = false;
    bool runtimeReady_ = false;
    bool guestReceiverPresent_ = false;
    bool virglSocketReady_ = false;
    bool virglLibraryPresent_ = false;
    bool virglSmokeAttempted_ = false;
    bool virglSmokeSucceeded_ = false;
    FramePresenterPath presenterPath_ = FramePresenterPath::CpuShmUpload;
    std::optional<FramePresenterPath> presenterOverride_;
    bool presenterFallbackActive_ = false;
    bool damageUploadActive_ = false;
    bool zeroCopyFramePath_ = false;
    bool nativeBufferInUse_ = false;
    BackendCaps caps_;
    GraphicsStats stats_;
    bool loggedVirglFallback_ = false;
    std::string runtimeDir_;
    std::string wineRuntimeBinDir_;
    std::string guestReceiverRuntimeDir_;
    std::string guestReceiverMode_;
    std::string guestReceiverError_;
    std::vector<std::string> guestReceiverEnv_;
    std::string virglServerProgramPath_;
    std::string virglSocketPath_;
    std::string virglLibraryPath_;
    std::string frameTransportMode_ = "wl_shm+cpu_copy+gl_upload";
    std::string presenterNote_;
    std::string virglSmokeError_;
    std::string lastError_;
    int virglServerPid_ = -1;
    std::atomic<bool> virglServerRunning_{false};
};

} // namespace winehua
