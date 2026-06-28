#pragma once

#include "graphics_stats.h"
#include "graphics_types.h"

#include <EGL/egl.h>

#include <cstdint>
#include <memory>
#include <string>

namespace winehua {

struct PresentFrameArgs
{
    uint32_t rendererToplevelId = 0;
    int hostWidth = 0;
    int hostHeight = 0;
};

struct PresentFrameResult
{
    bool presented = false;
    bool contentAvailable = false;
    int contentWidth = 0;
    int contentHeight = 0;
};

class IFramePresenter
{
public:
    virtual ~IFramePresenter() = default;

    virtual bool Init(EGLDisplay display, EGLContext context, EGLSurface surface) = 0;
    virtual void Resize(int hostWidth, int hostHeight) = 0;
    virtual bool Present(const PresentFrameArgs& args, PresentFrameResult& result) = 0;
    virtual void Destroy() = 0;

    virtual FramePresenterPath Path() const = 0;
    virtual const GraphicsStats& GetStats() const = 0;
    virtual bool UsesDamageUpload() const = 0;
    virtual bool ZeroCopy() const = 0;
    virtual const char* TransportMode() const = 0;
    virtual std::string LastError() const = 0;
};

struct BackendSelection
{
    FramePresenterPath preferredPath = FramePresenterPath::CpuShmUpload;
    BackendCaps caps;
    bool fallback = false;
    std::string reason;
};

} // namespace winehua
