#include "backend_detector.h"

#include "graphics_broker.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <optional>
#include <string>

namespace winehua {

namespace {

bool HasExtension(const char* extensions, const char* needle)
{
    std::string haystack;
    std::string token;

    if (!extensions || !needle || !needle[0]) return false;
    haystack = extensions;
    token = needle;

    return haystack.find(token) != std::string::npos;
}

} // namespace

BackendSelection BackendDetector::Detect(EGLDisplay display, EGLContext context, EGLSurface surface)
{
    BackendSelection selection;
    GraphicsBackendState state = GraphicsBroker::GetInstance().GetState();
    const char* requestedPresenter = std::getenv("WINEHUA_FRAME_PRESENTER");
    std::string requested = requestedPresenter ? requestedPresenter : "";
    std::optional<FramePresenterPath> overridePresenter =
        GraphicsBroker::GetInstance().GetPresenterOverride();
    const char* eglExtensions = nullptr;

    std::transform(requested.begin(), requested.end(), requested.begin(),
                   [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });

    selection.caps.virglAvailable = (state.active == GraphicsBackend::Virgl) ||
                                    (state.runtimeReady && state.virglLibraryPresent && state.virglSocketReady &&
                                     state.guestReceiverPresent);
    selection.caps.xcomponentEglAvailable = display != EGL_NO_DISPLAY &&
                                            context != EGL_NO_CONTEXT &&
                                            surface != EGL_NO_SURFACE;
    selection.caps.glCompositorAvailable = selection.caps.xcomponentEglAvailable;

    if (display != EGL_NO_DISPLAY)
    {
        eglExtensions = eglQueryString(display, EGL_EXTENSIONS);
        selection.caps.eglImageAvailable = HasExtension(eglExtensions, "EGL_KHR_image_base") ||
                                           HasExtension(eglExtensions, "EGL_KHR_gl_texture_2D_image");
    }

    selection.caps.nativeBufferAvailable = false;
    selection.caps.dmaBufAvailable = false;

    if (overridePresenter)
    {
        if (*overridePresenter == FramePresenterPath::CpuShmUpload)
        {
            selection.preferredPath = FramePresenterPath::CpuShmUpload;
            selection.reason = "frame presenter forced to cpu_shm_upload by runtime override";
            return selection;
        }

        if (selection.caps.glCompositorAvailable)
        {
            selection.preferredPath = FramePresenterPath::GlCompositorDirect;
            selection.reason = "frame presenter forced to gl_compositor_direct by runtime override";
            return selection;
        }

        selection.preferredPath = FramePresenterPath::CpuShmUpload;
        selection.fallback = true;
        selection.reason = "gl_compositor_direct was requested by runtime override but XComponent EGL is unavailable";
        return selection;
    }

    if (requested == "cpu_shm_upload" || requested == "cpu" || requested == "shm")
    {
        selection.preferredPath = FramePresenterPath::CpuShmUpload;
        selection.reason = "frame presenter forced to cpu_shm_upload";
        return selection;
    }

    if (requested == "gl_compositor_direct" || requested == "gl")
    {
        if (selection.caps.glCompositorAvailable)
        {
            selection.preferredPath = FramePresenterPath::GlCompositorDirect;
            selection.reason = "frame presenter forced to gl_compositor_direct";
            return selection;
        }

        selection.preferredPath = FramePresenterPath::CpuShmUpload;
        selection.fallback = true;
        selection.reason = "gl_compositor_direct was requested but XComponent EGL is unavailable";
        return selection;
    }

    if (selection.caps.glCompositorAvailable)
    {
        selection.preferredPath = FramePresenterPath::GlCompositorDirect;
        selection.reason = "gl compositor direct is available";
        return selection;
    }

    selection.preferredPath = FramePresenterPath::CpuShmUpload;
    selection.fallback = true;
    selection.reason = "XComponent EGL is unavailable; using cpu fallback";
    return selection;
}

} // namespace winehua
