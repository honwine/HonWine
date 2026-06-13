#include "plugin_manager.h"
#include <native_window/external_window.h>

#undef LOG_TAG
#define LOG_TAG "WL_Plugin"
#include <hilog/log.h>

PluginManager* PluginManager::GetInstance() {
    static PluginManager s;
    return &s;
}

void PluginManager::Export(napi_env env, napi_value exports) {
    napi_value xcVal = nullptr;
    napi_status st = napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &xcVal);
    OH_LOG_INFO(LOG_APP, "[Plugin] get XComponent property: status=%{public}d", st);
    if (st != napi_ok) {
        OH_LOG_WARN(LOG_APP, "[Plugin] no XComponent in exports");
        return;
    }

    napi_valuetype type;
    napi_typeof(env, xcVal, &type);
    OH_LOG_INFO(LOG_APP, "[Plugin] XComponent type=%{public}d (napi_object=%{public}d)", type, napi_object);

    OH_NativeXComponent* nxc = nullptr;
    napi_status uw = napi_unwrap(env, xcVal, reinterpret_cast<void**>(&nxc));
    OH_LOG_INFO(LOG_APP, "[Plugin] napi_unwrap: status=%{public}d ptr=%{public}p", uw, nxc);

    if (uw != napi_ok || !nxc) {
        OH_LOG_WARN(LOG_APP, "[Plugin] unwrap failed (status=%{public}d)", uw);
        return;
    }

    callback_.OnSurfaceCreated   = OnSurfaceCreated;
    callback_.OnSurfaceChanged   = OnSurfaceChanged;
    callback_.OnSurfaceDestroyed = OnSurfaceDestroyed;
    callback_.DispatchTouchEvent = DispatchTouchEvent;
    OH_NativeXComponent_RegisterCallback(nxc, &callback_);
    OH_LOG_INFO(LOG_APP, "[Plugin] XComponent registered ✓");
}

void PluginManager::OnSurfaceCreated(OH_NativeXComponent* component, void* window) {
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    OH_LOG_INFO(LOG_APP, "[Plugin] surface created %{public}llux%{public}llu", w, h);
    GetInstance()->renderer_.Init(reinterpret_cast<OHNativeWindow*>(window), (int)w, (int)h);
}

void PluginManager::OnSurfaceChanged(OH_NativeXComponent*, void*) {}

void PluginManager::OnSurfaceDestroyed(OH_NativeXComponent*, void*) {
    OH_LOG_INFO(LOG_APP, "[Plugin] surface destroyed");
    GetInstance()->renderer_.Shutdown();
}
