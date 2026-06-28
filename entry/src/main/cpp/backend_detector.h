#pragma once

#include "frame_presenter.h"

#include <EGL/egl.h>

namespace winehua {

class BackendDetector
{
public:
    static BackendSelection Detect(EGLDisplay display, EGLContext context, EGLSurface surface);
};

} // namespace winehua
