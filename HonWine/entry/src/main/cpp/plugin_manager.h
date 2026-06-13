#pragma once
#include <napi/native_api.h>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include "egl_renderer.h"

// XComponent 生命周期管理, 创建/销毁 EglRenderer
class PluginManager {
public:
    static PluginManager* GetInstance();
    void Export(napi_env env, napi_value exports);

    static void OnSurfaceCreated(OH_NativeXComponent*, void* window);
    static void OnSurfaceChanged(OH_NativeXComponent*, void* window);
    static void OnSurfaceDestroyed(OH_NativeXComponent*, void*);
    static void DispatchTouchEvent(OH_NativeXComponent*, void*) {}

private:
    PluginManager() = default;
    EglRenderer renderer_;
    OH_NativeXComponent_Callback callback_{};
};
