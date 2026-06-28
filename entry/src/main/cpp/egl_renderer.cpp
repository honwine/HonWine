#include "egl_renderer.h"

#include "backend_detector.h"
#include "cpu_shm_presenter.h"
#include "gl_compositor_presenter.h"
#include "graphics_broker.h"

#include <mutex>
#include <unistd.h>

#undef LOG_TAG
#define LOG_TAG "WL_EGL"
#include <hilog/log.h>

namespace {

EGLDisplay gSharedDisplay = EGL_NO_DISPLAY;
std::once_flag gDisplayOnce;

} // namespace

float EglRenderer::globalDisplayScale_ = 1.0f;

EGLDisplay EglRenderer::GetSharedDisplay() {
    std::call_once(gDisplayOnce, []() {
        gSharedDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (gSharedDisplay == EGL_NO_DISPLAY) {
            OH_LOG_ERROR(LOG_APP, "[EGL] eglGetDisplay FAILED");
            return;
        }
        EGLint major = 0;
        EGLint minor = 0;
        if (!eglInitialize(gSharedDisplay, &major, &minor)) {
            OH_LOG_ERROR(LOG_APP, "[EGL] eglInitialize FAILED: 0x%{public}x", eglGetError());
            gSharedDisplay = EGL_NO_DISPLAY;
            return;
        }
        OH_LOG_INFO(LOG_APP, "[EGL] shared display init OK EGL %{public}d.%{public}d", major, minor);
    });
    return gSharedDisplay;
}

bool EglRenderer::Init(OHNativeWindow* window, uint32_t toplevelId, int w, int h) {
    window_ = window;
    toplevelId_ = toplevelId;
    width_ = w;
    height_ = h;

    OH_LOG_INFO(LOG_APP, "[EGL] Init tl=%{public}u req=%{public}dx%{public}d", toplevelId_, w, h);

    display_ = GetSharedDisplay();
    if (display_ == EGL_NO_DISPLAY) {
        OH_LOG_ERROR(LOG_APP, "[EGL] shared display unavailable tl=%{public}u", toplevelId_);
        return false;
    }

    EGLConfig cfg = nullptr;
    EGLint nCfg = 0;
    EGLint attrs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_NONE
    };
    eglChooseConfig(display_, attrs, &cfg, 1, &nCfg);

    EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    context_ = eglCreateContext(display_, cfg, EGL_NO_CONTEXT, ctxAttrs);
    surface_ = eglCreateWindowSurface(display_, cfg,
                                      reinterpret_cast<EGLNativeWindowType>(window_), nullptr);
    if (surface_ == EGL_NO_SURFACE) {
        OH_LOG_ERROR(LOG_APP, "[EGL] eglCreateWindowSurface failed tl=%{public}u: 0x%{public}x",
                     toplevelId_, eglGetError());
        return false;
    }

    running_ = true;
    thread_ = std::thread(&EglRenderer::RenderLoop, this);
    OH_LOG_INFO(LOG_APP, "[EGL] tl=%{public}u Init done, render thread started", toplevelId_);
    return true;
}

bool EglRenderer::SwitchPresenter(winehua::FramePresenterPath requestedPath,
                                  bool fallbackActive,
                                  const std::string& reason) {
    std::unique_ptr<winehua::IFramePresenter> presenter;

    if (requestedPath == winehua::FramePresenterPath::GlCompositorDirect) {
        presenter = std::make_unique<winehua::GlCompositorPresenter>();
    } else {
        presenter = std::make_unique<winehua::CpuShmPresenter>();
    }

    if (!presenter->Init(display_, context_, surface_)) {
        std::string error = presenter->LastError();
        if (error.empty()) error = "presenter init failed";
        if (requestedPath != winehua::FramePresenterPath::CpuShmUpload) {
            OH_LOG_WARN(LOG_APP,
                        "[EGL] tl=%{public}u presenter %{public}s init failed (%{public}s), falling back to cpu",
                        toplevelId_,
                        winehua::FramePresenterPathName(requestedPath),
                        error.c_str());
            return SwitchPresenter(winehua::FramePresenterPath::CpuShmUpload, true,
                                   "fallback: " + error);
        }

        OH_LOG_ERROR(LOG_APP, "[EGL] tl=%{public}u cpu presenter init failed: %{public}s",
                     toplevelId_, error.c_str());
        return false;
    }

    if (presenter_) presenter_->Destroy();
    presenter_ = std::move(presenter);
    presenterFallbackActive_ = fallbackActive;
    presenterSelectionNote_ = reason;
    PublishPresenterState();
    OH_LOG_INFO(LOG_APP,
                "[EGL] tl=%{public}u presenter=%{public}s fallback=%{public}s note=%{public}s",
                toplevelId_,
                winehua::FramePresenterPathName(presenter_->Path()),
                presenterFallbackActive_ ? "true" : "false",
                presenterSelectionNote_.empty() ? "(none)" : presenterSelectionNote_.c_str());
    return true;
}

void EglRenderer::PublishPresenterState(const std::string& note) const {
    if (!presenter_) return;

    std::string effectiveNote = note;
    if (effectiveNote.empty() && presenterFallbackActive_) effectiveNote = presenterSelectionNote_;

    winehua::GraphicsBroker::GetInstance().ReportPresenterState(
        presenter_->Path(),
        presenterFallbackActive_,
        presenter_->UsesDamageUpload(),
        presenter_->ZeroCopy(),
        false,
        presenterCaps_,
        presenter_->GetStats(),
        presenter_->TransportMode(),
        effectiveNote);
}

void EglRenderer::RenderLoop() {
    if (!eglMakeCurrent(display_, surface_, surface_, context_)) {
        OH_LOG_ERROR(LOG_APP, "[EGL] eglMakeCurrent failed tl=%{public}u: 0x%{public}x",
                     toplevelId_, eglGetError());
        return;
    }

    winehua::BackendSelection selection = winehua::BackendDetector::Detect(display_, context_, surface_);
    presenterCaps_ = selection.caps;
    if (!SwitchPresenter(selection.preferredPath, selection.fallback, selection.reason)) return;

    while (running_) {
        EGLint surfW = 0;
        EGLint surfH = 0;
        eglQuerySurface(display_, surface_, EGL_WIDTH, &surfW);
        eglQuerySurface(display_, surface_, EGL_HEIGHT, &surfH);
        if (surfW > 0 && surfH > 0) {
            width_ = surfW;
            height_ = surfH;
        }

        if (presenter_) presenter_->Resize(width_, height_);

        winehua::PresentFrameArgs args;
        winehua::PresentFrameResult result;
        args.rendererToplevelId = toplevelId_;
        args.hostWidth = width_;
        args.hostHeight = height_;

        bool presented = presenter_ ? presenter_->Present(args, result) : false;
        if (result.contentAvailable && result.contentWidth > 0 && result.contentHeight > 0) {
            frameW_ = result.contentWidth;
            frameH_ = result.contentHeight;
            winehua::ViewportRect viewport =
                winehua::ComputeLetterboxViewport(width_, height_, frameW_, frameH_);
            vpX_ = viewport.x;
            vpY_ = viewport.y;
            vpW_ = viewport.w;
            vpH_ = viewport.h;
        }

        if (!presented && presenter_ &&
            presenter_->Path() != winehua::FramePresenterPath::CpuShmUpload &&
            !presenter_->LastError().empty()) {
            std::string reason = presenter_->LastError();
            if (!SwitchPresenter(winehua::FramePresenterPath::CpuShmUpload, true, "fallback: " + reason)) {
                PublishPresenterState(reason);
                return;
            }
            usleep(16667);
            continue;
        }

        PublishPresenterState();
        if ((width_ != lastLoggedW_ || height_ != lastLoggedH_) && frameW_ > 0 && frameH_ > 0) {
            lastLoggedW_ = width_;
            lastLoggedH_ = height_;
            OH_LOG_INFO(LOG_APP, "[MW-RESIZE] tl=%{public}u surface=%{public}dx%{public}d frame=%{public}dx%{public}d presenter=%{public}s",
                        toplevelId_, width_, height_, frameW_, frameH_,
                        presenter_ ? winehua::FramePresenterPathName(presenter_->Path()) : "none");
        }

        usleep(16667);
    }
}

void EglRenderer::Shutdown() {
    running_ = false;
    if (thread_.joinable()) thread_.join();
    if (display_ != EGL_NO_DISPLAY) {
        if (surface_ != EGL_NO_SURFACE && context_ != EGL_NO_CONTEXT) {
            eglMakeCurrent(display_, surface_, surface_, context_);
        }
        if (presenter_) {
            presenter_->Destroy();
            presenter_.reset();
        }
        eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (surface_ != EGL_NO_SURFACE) {
            eglDestroySurface(display_, surface_);
            surface_ = EGL_NO_SURFACE;
        }
        if (context_ != EGL_NO_CONTEXT) {
            eglDestroyContext(display_, context_);
            context_ = EGL_NO_CONTEXT;
        }
        OH_LOG_INFO(LOG_APP, "[EGL] tl=%{public}u Shutdown OK (display retained)", toplevelId_);
    }
    if (window_) {
        OH_NativeWindow_DestroyNativeWindow(window_);
        window_ = nullptr;
        OH_LOG_INFO(LOG_APP, "[EGL] tl=%{public}u native window destroyed", toplevelId_);
    }
}
