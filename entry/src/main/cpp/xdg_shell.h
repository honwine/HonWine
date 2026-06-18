#pragma once
#include <wayland-server-core.h>

// 注册 xdg_wm_base global 到 display
extern "C" void RegisterXdgShell(wl_display* display);
