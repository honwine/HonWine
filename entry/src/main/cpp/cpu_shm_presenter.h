#pragma once

#include "frame_presenter.h"

#include <GLES3/gl3.h>

#include <string>
#include <vector>

namespace winehua {

class CpuShmPresenter : public IFramePresenter
{
public:
    bool Init(EGLDisplay display, EGLContext context, EGLSurface surface) override;
    void Resize(int hostWidth, int hostHeight) override;
    bool Present(const PresentFrameArgs& args, PresentFrameResult& result) override;
    void Destroy() override;

    FramePresenterPath Path() const override { return FramePresenterPath::CpuShmUpload; }
    const GraphicsStats& GetStats() const override { return stats_; }
    bool UsesDamageUpload() const override { return false; }
    bool ZeroCopy() const override { return false; }
    const char* TransportMode() const override { return "wl_shm+cpu_copy+gl_upload"; }
    std::string LastError() const override { return lastError_; }

private:
    void LogStatsIfNeeded() const;
    void DrawCurrentTexture(int hostWidth, int hostHeight, int frameWidth, int frameHeight);

    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLSurface surface_ = EGL_NO_SURFACE;
    GLuint texture_ = 0;
    GLuint program_ = 0;
    GLuint vbo_ = 0;
    int hostWidth_ = 0;
    int hostHeight_ = 0;
    int texWidth_ = 0;
    int texHeight_ = 0;
    int lastPresentedHostWidth_ = 0;
    int lastPresentedHostHeight_ = 0;
    bool rendered_ = false;
    mutable GraphicsStats stats_;
    std::string lastError_;
};

} // namespace winehua
