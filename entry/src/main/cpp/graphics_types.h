#pragma once

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <string>

namespace winehua {

enum class FramePresenterPath
{
    CpuShmUpload = 0,
    GlCompositorDirect = 1,
};

inline const char* FramePresenterPathName(FramePresenterPath path)
{
    switch (path) {
    case FramePresenterPath::GlCompositorDirect:
        return "gl_compositor_direct";
    case FramePresenterPath::CpuShmUpload:
    default:
        return "cpu_shm_upload";
    }
}

inline bool ParseFramePresenterPathName(const std::string& name, FramePresenterPath* outPath)
{
    if (!outPath) return false;

    std::string lower = name;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });

    if (lower == "cpu_shm_upload" || lower == "cpu" || lower == "shm")
    {
        *outPath = FramePresenterPath::CpuShmUpload;
        return true;
    }
    if (lower == "gl_compositor_direct" || lower == "gl")
    {
        *outPath = FramePresenterPath::GlCompositorDirect;
        return true;
    }
    return false;
}

struct DamageRect
{
    int x = 0;
    int y = 0;
    int w = 0;
    int h = 0;
};

struct BackendCaps
{
    bool virglAvailable = false;
    bool xcomponentEglAvailable = false;
    bool glCompositorAvailable = false;
    bool nativeBufferAvailable = false;
    bool eglImageAvailable = false;
    bool dmaBufAvailable = false;
};

struct ViewportRect
{
    int x = 0;
    int y = 0;
    int w = 0;
    int h = 0;
};

inline ViewportRect ComputeLetterboxViewport(int hostWidth, int hostHeight, int contentWidth, int contentHeight)
{
    ViewportRect viewport;

    viewport.w = std::max(hostWidth, 0);
    viewport.h = std::max(hostHeight, 0);
    if (hostWidth <= 0 || hostHeight <= 0 || contentWidth <= 0 || contentHeight <= 0) return viewport;

    float frameAspect = static_cast<float>(contentWidth) / static_cast<float>(contentHeight);
    float hostAspect = static_cast<float>(hostWidth) / static_cast<float>(hostHeight);

    if (hostAspect > frameAspect)
    {
        viewport.h = hostHeight;
        viewport.w = std::max(1, static_cast<int>(hostHeight * frameAspect));
        viewport.x = (hostWidth - viewport.w) / 2;
        viewport.y = 0;
    }
    else
    {
        viewport.w = hostWidth;
        viewport.h = std::max(1, static_cast<int>(hostWidth / frameAspect));
        viewport.x = 0;
        viewport.y = (hostHeight - viewport.h) / 2;
    }

    return viewport;
}

inline bool IsDamageRectEmpty(const DamageRect& rect)
{
    return rect.w <= 0 || rect.h <= 0;
}

inline DamageRect ClipDamageRect(const DamageRect& rect, int width, int height)
{
    DamageRect clipped = rect;
    int x2 = rect.x + rect.w;
    int y2 = rect.y + rect.h;

    clipped.x = std::clamp(rect.x, 0, std::max(width, 0));
    clipped.y = std::clamp(rect.y, 0, std::max(height, 0));
    x2 = std::clamp(x2, 0, std::max(width, 0));
    y2 = std::clamp(y2, 0, std::max(height, 0));
    clipped.w = std::max(0, x2 - clipped.x);
    clipped.h = std::max(0, y2 - clipped.y);
    return clipped;
}

} // namespace winehua
