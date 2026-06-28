#pragma once

#include "frame_presenter.h"
#include "surface_texture_cache.h"

#include <GLES3/gl3.h>

#include <string>

namespace winehua {

class GlCompositorPresenter : public IFramePresenter
{
public:
    bool Init(EGLDisplay display, EGLContext context, EGLSurface surface) override;
    void Resize(int hostWidth, int hostHeight) override;
    bool Present(const PresentFrameArgs& args, PresentFrameResult& result) override;
    void Destroy() override;

    FramePresenterPath Path() const override { return FramePresenterPath::GlCompositorDirect; }
    const GraphicsStats& GetStats() const override { return stats_; }
    bool UsesDamageUpload() const override { return true; }
    bool ZeroCopy() const override { return false; }
    const char* TransportMode() const override { return "wl_shm+surface_texture_cache+gl_compositor"; }
    std::string LastError() const override { return lastError_; }

private:
    void LogStatsIfNeeded() const;
    void DrawSurface(GLuint texture,
                     bool opaque,
                     int x,
                     int y,
                     int width,
                     int height,
                     int canvasWidth,
                     int canvasHeight,
                     const ViewportRect& viewport) const;

    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLSurface surface_ = EGL_NO_SURFACE;
    GLuint program_ = 0;
    GLuint vbo_ = 0;
    SurfaceTextureCache textureCache_;
    int hostWidth_ = 0;
    int hostHeight_ = 0;
    int lastPresentedHostWidth_ = 0;
    int lastPresentedHostHeight_ = 0;
    uint64_t lastSceneSerial_ = 0;
    bool rendered_ = false;
    mutable GraphicsStats stats_;
    std::string lastError_;
};

} // namespace winehua
