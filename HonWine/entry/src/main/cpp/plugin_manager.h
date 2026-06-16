#pragma once
#include <napi/native_api.h>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include "egl_renderer.h"
#include <unordered_map>
#include <set>
#include <memory>
#include <cstdint>

// XComponent 生命周期管理, 为每个 toplevel 创建独立的 EglRenderer
class PluginManager {
public:
    static PluginManager* GetInstance();
    void Export(napi_env env, napi_value exports);

    void SetPendingToplevel(uint32_t toplevelId) { pendingToplevelId_ = toplevelId; currentToplevelId_ = toplevelId; }
    uint32_t GetCurrentToplevelId() const { return currentToplevelId_; }
    void DestroyToplevel(uint32_t toplevelId);

    static void OnSurfaceCreated(OH_NativeXComponent*, void* window);
    static void OnSurfaceChanged(OH_NativeXComponent*, void* window);
    static void OnSurfaceDestroyed(OH_NativeXComponent*, void*);

    // 输入事件回调 (native 注册, 用于 real device)
    static void DispatchTouchEvent(OH_NativeXComponent*, void*);
    static void OnMouseEvent(OH_NativeXComponent*, void*);
    static void OnKeyEvent(OH_NativeXComponent*, void*);

    // 辅助: toplevelId -> EglRenderer 查找
    EglRenderer* GetRendererForToplevel(uint32_t tid);

    // 输入事件转发 (ArkTS NAPI 路径, 用于 uitest + real device)
    static napi_value ForwardTouchEvent(napi_env env, napi_callback_info info);
    static napi_value ForwardMouseEvent(napi_env env, napi_callback_info info);
    static napi_value ForwardKeyEvent(napi_env env, napi_callback_info info);

private:
    PluginManager() = default;

    // 每个 toplevel 一个独立 EGLContext 渲染器
    std::unordered_map<uint32_t, std::unique_ptr<EglRenderer>> toplevelRenderers_;
    // ArkTS 在创建子窗口前调用 setPendingToplevel, native 在 OnSurfaceCreated 消费
    uint32_t pendingToplevelId_ = 0;
    uint32_t currentToplevelId_ = 0;  // 持久保存, 供 ArkTS WineWindow 查询

    // 跟踪 XComponent -> toplevelId 映射
    std::set<OH_NativeXComponent*> subXComponents_;
    std::unordered_map<OH_NativeXComponent*, uint32_t> xcToToplevelId_;

    OH_NativeXComponent_Callback callback_{};
    OH_NativeXComponent_MouseEvent_Callback mouseCallback_{};
};
