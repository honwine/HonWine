#include "plugin_manager.h"
#include "wayland_server.h"
#include "seat.h"
#include <native_window/external_window.h>
#include <set>

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
    OH_LOG_INFO(LOG_APP, "[MW-Export]  status=%{public}d pendingToplevel=%{public}u existXC=%{public}zu existRender=%{public}zu",
                st, pendingToplevelId_, subXComponents_.size(), toplevelRenderers_.size());
    if (st != napi_ok) {
        OH_LOG_WARN(LOG_APP, "[MW-Export] ERR no XComponent in exports (status=%{public}d)", st);
        return;
    }

    napi_valuetype type;
    napi_typeof(env, xcVal, &type);
    OH_LOG_INFO(LOG_APP, "[MW-Export] XComponent type=%{public}d (napi_object=%{public}d)", type, napi_object);

    OH_NativeXComponent* nxc = nullptr;
    napi_status uw = napi_unwrap(env, xcVal, reinterpret_cast<void**>(&nxc));
    OH_LOG_INFO(LOG_APP, "[MW-Export] napi_unwrap: status=%{public}d ptr=%{public}p", uw, nxc);

    if (uw != napi_ok || !nxc) {
        OH_LOG_WARN(LOG_APP, "[MW-Export] ERR unwrap failed (status=%{public}d)", uw);
        return;
    }

    // 检查是否已注册 (防止重复注册)
    if (subXComponents_.count(nxc)) {
        OH_LOG_WARN(LOG_APP, "[MW-Export] WARN XComponent %{public}p ALREADY registered (pendingToplevel=%{public}u), SKIP -- keeping existing mapping",
                    nxc, pendingToplevelId_);
        return;  // 不覆盖已有的 xcToToplevelId_ 映射
    }

    callback_.OnSurfaceCreated   = OnSurfaceCreated;
    callback_.OnSurfaceChanged   = OnSurfaceChanged;
    callback_.OnSurfaceDestroyed = OnSurfaceDestroyed;
    callback_.DispatchTouchEvent = nullptr;  // 输入全部走 Stack ArkTS -> NAPI, 不注册 native 输入回调
    OH_NativeXComponent_RegisterCallback(nxc, &callback_);

    // 触控/鼠标走父 Stack 的 ArkTS 回调 -> ForwardMouseEvent NAPI
    // 键盘必须走 native callback: XComponent (native surface) 会抢占焦点, Stack.onKeyEvent 不触发
    OH_NativeXComponent_RegisterKeyEventCallback(nxc, OnKeyEvent);

    // 所有 XComponent 都属于子窗口 (主界面已无 XComponent)
    subXComponents_.insert(nxc);
    xcToToplevelId_[nxc] = pendingToplevelId_;
    OH_LOG_INFO(LOG_APP, "[MW-Export] OK XComponent %{public}p -> toplevel #%{public}u (total xc=%{public}zu renderers=%{public}zu)",
                nxc, pendingToplevelId_, subXComponents_.size(), toplevelRenderers_.size());
}

void PluginManager::OnSurfaceCreated(OH_NativeXComponent* component, void* window) {
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    auto* self = GetInstance();
    uint32_t tid = self->pendingToplevelId_;
    OH_LOG_INFO(LOG_APP, "[MW-Surface] created %{public}llux%{public}llu pendingToplevel=%{public}u window=%{public}p component=%{public}p",
                w, h, tid, window, component);

    if (tid != 0) {
        // 子窗口: 独立 EGLContext
        self->pendingToplevelId_ = 0;

        // 防御: 如果已有旧 renderer (XComponent 重建场景), 先 shutdown
        auto old = self->toplevelRenderers_.find(tid);
        if (old != self->toplevelRenderers_.end()) {
            OH_LOG_WARN(LOG_APP, "[MW-Surface] WARN toplevel #%{public}u already has renderer, shutting down old (XComponent recreate?)", tid);
            old->second->Shutdown();
            self->toplevelRenderers_.erase(old);
        }

        auto r = std::make_unique<EglRenderer>();
        OH_LOG_INFO(LOG_APP, "[MW-Surface] creating EglRenderer for toplevel #%{public}u (%{public}llux%{public}llu)...", tid, w, h);
        if (r->Init(reinterpret_cast<OHNativeWindow*>(window), (int)w, (int)h)) {
            r->SetToplevelId(tid);
            self->toplevelRenderers_[tid] = std::move(r);
            OH_LOG_INFO(LOG_APP, "[MW-Surface] OK toplevel #%{public}u renderer created (total=%{public}zu)", tid, self->toplevelRenderers_.size());
            // 通知 ArkTS surface 的物理像素尺寸, 用于动态计算标题栏高度
            char json[64];
            snprintf(json, sizeof(json), "{\"w\":%llu,\"h\":%llu}", w, h);
            WaylandServer::GetInstance()->FireToplevelEvent(tid, "surface", json);
        } else {
            OH_LOG_ERROR(LOG_APP, "[MW-Surface] ERR toplevel #%{public}u EglRenderer::Init FAILED", tid);
        }
    } else {
        OH_LOG_WARN(LOG_APP, "[MW-Surface] no pending toplevel (tid=0), skipping -- old main XComponent?");
    }
}

void PluginManager::OnSurfaceChanged(OH_NativeXComponent* component, void* window) {
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    auto* self = GetInstance();
    OH_LOG_INFO(LOG_APP, "[MW-Surface] changed component=%{public}p size=%{public}llux%{public}llu",
                component, w, h);

    auto it = self->xcToToplevelId_.find(component);
    if (it != self->xcToToplevelId_.end()) {
        uint32_t tid = it->second;
        auto rit = self->toplevelRenderers_.find(tid);
        if (rit != self->toplevelRenderers_.end() && rit->second->IsValid()) {
            rit->second->SetSize((int)w, (int)h);
            OH_LOG_INFO(LOG_APP, "[MW-Surface] toplevel #%{public}u renderer resized to %{public}llux%{public}llu",
                        tid, w, h);
            // 每次 surface 大小变化都回报给 ArkTS, 用于 titleBarH 校准
            char json[64];
            snprintf(json, sizeof(json), "{\"w\":%llu,\"h\":%llu}", w, h);
            WaylandServer::GetInstance()->FireToplevelEvent(tid, "surface", json);
        }
    }
}

void PluginManager::OnSurfaceDestroyed(OH_NativeXComponent* component, void*) {
    auto* self = GetInstance();
    if (self->subXComponents_.count(component)) {
        OH_LOG_INFO(LOG_APP, "[MW-Destroy] XComponent destroyed: %{public}p (remaining: %{public}zu)",
                    component, self->subXComponents_.size() - 1);
        self->subXComponents_.erase(component);
        // toplevel renderer 由 ArkTS destroyToplevel 清理
    } else {
        OH_LOG_WARN(LOG_APP, "[MW-Destroy] UNKNOWN XComponent destroyed: %{public}p", component);
    }
}

void PluginManager::DestroyToplevel(uint32_t toplevelId) {
    auto it = toplevelRenderers_.find(toplevelId);
    if (it != toplevelRenderers_.end()) {
        it->second->Shutdown();
        toplevelRenderers_.erase(it);
        OH_LOG_INFO(LOG_APP, "[MW-Destroy] toplevel #%{public}u renderer destroyed (remaining: %{public}zu)",
                    toplevelId, toplevelRenderers_.size());
    } else {
        OH_LOG_WARN(LOG_APP, "[MW-Destroy] toplevel #%{public}u NOT found (remaining: %{public}zu)",
                    toplevelId, toplevelRenderers_.size());
    }

    // 清理残留的 XComponent -> toplevelId 映射
    for (auto xit = xcToToplevelId_.begin(); xit != xcToToplevelId_.end(); ) {
        if (xit->second == toplevelId) {
            OH_LOG_INFO(LOG_APP, "[MW-Destroy] cleaned stale xcToToplevel: %{public}p -> #%{public}u",
                        xit->first, xit->second);
            xit = xcToToplevelId_.erase(xit);
        } else {
            ++xit;
        }
    }
}

// -- 触控事件 -> wl_pointer 转发 --
void PluginManager::DispatchTouchEvent(OH_NativeXComponent* component, void* window) {
    auto* self = GetInstance();

    // 查找 toplevelId
    auto xit = self->xcToToplevelId_.find(component);
    if (xit == self->xcToToplevelId_.end()) return;
    uint32_t tid = xit->second;

    // 获取 renderer 尺寸
    auto rit = self->toplevelRenderers_.find(tid);
    if (rit == self->toplevelRenderers_.end()) return;
    auto* r = rit->second.get();

    // 获取触控事件
    OH_NativeXComponent_TouchEvent te;
    if (OH_NativeXComponent_GetTouchEvent(component, window, &te) != 0) return;

    float x = te.x;
    float y = te.y;
    int action = te.type;

    int surfW = r->GetWidth();
    int surfH = r->GetHeight();
    int fw = r->GetFrameWidth();
    int fh = r->GetFrameHeight();

    if (surfW <= 0 || surfH <= 0 || fw <= 0 || fh <= 0) {
        OH_LOG_WARN(LOG_APP, "[MW-Touch] tl=%{public}u invalid dims: surf=%{public}dx%{public}d frame=%{public}dx%{public}d",
                    tid, surfW, surfH, fw, fh);
        return;
    }

    // 坐标转换: surface 坐标 -> wine 内容坐标 (无 letterbox, 全表面渲染)
    wl_fixed_t wx = wl_fixed_from_double((double)x * fw / surfW);
    wl_fixed_t wy = wl_fixed_from_double((double)y * fh / surfH);

    auto* seat = Seat::GetInstance();

    switch (action) {
        case OH_NATIVEXCOMPONENT_DOWN: {
            // 首次触控: enter + motion + button press (通过队列, 线程安全)
            wl_resource* surf = WaylandServer::GetInstance()->GetSurfaceForToplevel(tid);
            if (surf) {
                if (seat->GetFocusedToplevel() != 0 && seat->GetFocusedToplevel() != tid)
                    seat->EnqueuePointerLeave();
                seat->EnqueuePointerEnter(tid, surf, wx, wy);
                seat->EnqueuePointerMotion(wx, wy);
                seat->EnqueuePointerButton(0x110, WL_POINTER_BUTTON_STATE_PRESSED);  // BTN_LEFT
            }
            break;
        }
        case OH_NATIVEXCOMPONENT_MOVE:
            if (seat->NeedsPointerEnter() || seat->GetFocusedToplevel() != tid) {
                wl_resource* surf = WaylandServer::GetInstance()->GetSurfaceForToplevel(tid);
                if (surf) {
                    if (seat->GetFocusedToplevel() != 0 && seat->GetFocusedToplevel() != tid)
                        seat->EnqueuePointerLeave();
                    seat->EnqueuePointerEnter(tid, surf, wx, wy);
                }
            }
            seat->EnqueuePointerMotion(wx, wy);
            break;
        case OH_NATIVEXCOMPONENT_UP:
            seat->EnqueuePointerButton(0x110, WL_POINTER_BUTTON_STATE_RELEASED);  // BTN_LEFT
            break;
        default:
            break;
    }
}

// -- 鼠标事件 -> wl_pointer 转发 --
void PluginManager::OnMouseEvent(OH_NativeXComponent* component, void* window) {
    auto* self = GetInstance();

    auto xit = self->xcToToplevelId_.find(component);
    if (xit == self->xcToToplevelId_.end()) {
        OH_LOG_WARN(LOG_APP, "[MW-Mouse] component %{public}p NOT in xcToToplevelId_", component);
        return;
    }
    uint32_t tid = xit->second;
    auto rit = self->toplevelRenderers_.find(tid);
    if (rit == self->toplevelRenderers_.end()) {
        OH_LOG_WARN(LOG_APP, "[MW-Mouse] tl=%{public}u renderer NOT found", tid);
        return;
    }
    auto* r = rit->second.get();

    OH_NativeXComponent_MouseEvent me;
    if (OH_NativeXComponent_GetMouseEvent(component, window, &me) != 0) return;

    if (me.action != OH_NATIVEXCOMPONENT_MOUSE_MOVE) {
        OH_LOG_INFO(LOG_APP, "[MW-Mouse]  tl=%{public}u action=%{public}d btn=0x%{public}x x=%{public}d y=%{public}d", tid, me.action, me.button, (int)me.x, (int)me.y);
    }

    int surfW = r->GetWidth();
    int surfH = r->GetHeight();
    int fw = r->GetFrameWidth();
    int fh = r->GetFrameHeight();

    if (surfW <= 0 || surfH <= 0 || fw <= 0 || fh <= 0) return;

    wl_fixed_t wx = wl_fixed_from_double((double)me.x * fw / surfW);
    wl_fixed_t wy = wl_fixed_from_double((double)me.y * fh / surfH);

    auto* seat = Seat::GetInstance();

    if (!seat->HasPointerResource()) {
        OH_LOG_WARN(LOG_APP, "[MW-Mouse] no pointer resource, skip");
        return;
    }

    switch (me.action) {
        case OH_NATIVEXCOMPONENT_MOUSE_PRESS: {
            OH_LOG_INFO(LOG_APP, "[MW-Mouse] PRESS begin tl=%{public}u", tid);
            if (seat->NeedsPointerEnter()) {
                OH_LOG_INFO(LOG_APP, "[MW-Mouse] needs enter, looking up surface...");
                wl_resource* surf = WaylandServer::GetInstance()->GetSurfaceForToplevel(tid);
                OH_LOG_INFO(LOG_APP, "[MW-Mouse] surface=%{public}p", surf);
                if (surf) {
                    OH_LOG_INFO(LOG_APP, "[MW-Mouse] enqueue enter...");
                    if (seat->GetFocusedToplevel() != 0 && seat->GetFocusedToplevel() != tid)
                        seat->EnqueuePointerLeave();
                    seat->EnqueuePointerEnter(tid, surf, wx, wy);
                    OH_LOG_INFO(LOG_APP, "[MW-Mouse] enqueue enter done");
                }
            }
            OH_LOG_INFO(LOG_APP, "[MW-Mouse] enqueue motion...");
            seat->EnqueuePointerMotion(wx, wy);
            OH_LOG_INFO(LOG_APP, "[MW-Mouse] enqueue motion done");
            uint32_t btn = 0;
            if (me.button & OH_NATIVEXCOMPONENT_LEFT_BUTTON)   btn = 0x110;
            if (me.button & OH_NATIVEXCOMPONENT_RIGHT_BUTTON)  btn = 0x111;
            if (me.button & OH_NATIVEXCOMPONENT_MIDDLE_BUTTON) btn = 0x112;
            if (btn) {
                OH_LOG_INFO(LOG_APP, "[MW-Mouse] enqueue button btn=0x%{public}x...", btn);
                seat->EnqueuePointerButton(btn, WL_POINTER_BUTTON_STATE_PRESSED);
                OH_LOG_INFO(LOG_APP, "[MW-Mouse] enqueue button done");
            }
            OH_LOG_INFO(LOG_APP, "[MW-Mouse] PRESS end tl=%{public}u", tid);
            break;
        }
        case OH_NATIVEXCOMPONENT_MOUSE_RELEASE: {
            uint32_t btn = 0;
            if (me.button & OH_NATIVEXCOMPONENT_LEFT_BUTTON)   btn = 0x110;
            if (me.button & OH_NATIVEXCOMPONENT_RIGHT_BUTTON)  btn = 0x111;
            if (me.button & OH_NATIVEXCOMPONENT_MIDDLE_BUTTON) btn = 0x112;
            OH_LOG_INFO(LOG_APP, "[MW-Mouse] RELEASE tl=%{public}u btn=0x%{public}x", tid, btn);
            if (btn) seat->EnqueuePointerButton(btn, WL_POINTER_BUTTON_STATE_RELEASED);
            break;
        }
        case OH_NATIVEXCOMPONENT_MOUSE_MOVE:
            // 当 pointer 未 enter 或焦点切换到不同 toplevel 时先 leave 旧 surface 再 enter 新 surface
            if (seat->NeedsPointerEnter() || seat->GetFocusedToplevel() != tid) {
                wl_resource* surf = WaylandServer::GetInstance()->GetSurfaceForToplevel(tid);
                if (surf) {
                    if (seat->GetFocusedToplevel() != 0 && seat->GetFocusedToplevel() != tid)
                        seat->EnqueuePointerLeave();
                    seat->EnqueuePointerEnter(tid, surf, wx, wy);
                }
            }
            seat->EnqueuePointerMotion(wx, wy);
            break;
        default:
            break;
    }

    // 滚轮
    if (me.button & OH_NATIVEXCOMPONENT_BACK_BUTTON) {
        seat->EnqueuePointerAxis(WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_int(-1));
    }
    if (me.button & OH_NATIVEXCOMPONENT_FORWARD_BUTTON) {
        seat->EnqueuePointerAxis(WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_int(1));
    }
}

// -- 键盘事件 -> wl_keyboard 转发 --
void PluginManager::OnKeyEvent(OH_NativeXComponent* component, void* window) {
    auto* self = GetInstance();

    auto xit = self->xcToToplevelId_.find(component);
    if (xit == self->xcToToplevelId_.end()) {
        OH_LOG_WARN(LOG_APP, "[KBD-PIPE] [NativeCb] component %{public}p NOT in xcToToplevelId_", component);
        return;
    }
    uint32_t tid = xit->second;

    OH_NativeXComponent_KeyEvent* ke = nullptr;
    int gk = OH_NativeXComponent_GetKeyEvent(component, &ke);
    int32_t retGetKey = gk;
    OH_LOG_INFO(LOG_APP, "[KBD-PIPE] [NativeCb]  tl=%{public}u GetKeyEvent=%{public}d ke=%{public}p", tid, gk, ke);
    if (gk != 0 || !ke) return;

    OH_NativeXComponent_KeyAction action;
    int ga = OH_NativeXComponent_GetKeyEventAction(ke, &action);
    OH_LOG_INFO(LOG_APP, "[KBD-PIPE] [NativeCb] GetKeyEventAction=%{public}d action=%{public}d", ga, (int)action);

    OH_NativeXComponent_KeyCode code;
    int gc = OH_NativeXComponent_GetKeyEventCode(ke, &code);
    OH_LOG_INFO(LOG_APP, "[KBD-PIPE] [NativeCb] GetKeyEventCode=%{public}d code=%{public}d", gc, (int)code);

    uint32_t evdev = Seat::MapKeycode((int32_t)code);
    OH_LOG_INFO(LOG_APP, "[KBD-PIPE] [NativeCb] MapKeycode(%{public}d) -> evdev=%{public}u", (int)code, evdev);
    if (evdev == 0) return;  // unmapped key

    auto* seat = Seat::GetInstance();

    // 首次按键或焦点切换: 先 leave 旧 surface 再 enter 新 surface
    if (!seat->HasKeyboardEnter() || seat->GetKeyboardFocusedToplevel() != tid) {
        wl_resource* surf = WaylandServer::GetInstance()->GetSurfaceForToplevel(tid);
        OH_LOG_INFO(LOG_APP, "[KBD-PIPE] [NativeCb] keyboard enter tid=%{public}u surf=%{public}p", tid, surf);
        if (surf) {
            if (seat->HasKeyboardEnter() && seat->GetKeyboardFocusedToplevel() != tid)
                seat->EnqueueKeyboardLeave();
            seat->EnqueueKeyboardEnter(tid, surf);
        } else {
            OH_LOG_WARN(LOG_APP, "[KBD-PIPE] [NativeCb] ERR no surface for tl=%{public}u, skip key", tid);
            return;
        }
    }

    // 防御: enter 失败则不发 key (避免协议违规)
    if (!seat->HasKeyboardEnter()) {
        OH_LOG_WARN(LOG_APP, "[KBD-PIPE] [NativeCb] ERR keyboard not entered, skip key event");
        return;
    }

    // OHOS: DOWN=0, UP=1; wl_keyboard: PRESSED=1, RELEASED=0
    uint32_t wlState = (action == OH_NATIVEXCOMPONENT_KEY_ACTION_DOWN)
                       ? WL_KEYBOARD_KEY_STATE_PRESSED
                       : WL_KEYBOARD_KEY_STATE_RELEASED;
    OH_LOG_INFO(LOG_APP, "[KBD-PIPE] [NativeCb] key evdev=%{public}u state=%{public}u", evdev, wlState);
    seat->EnqueueKeyboardKey(evdev, wlState);
}

// -- ArkTS NAPI 事件转发 (uitest / real device -> Seat) --

EglRenderer* PluginManager::GetRendererForToplevel(uint32_t tid) {
    auto rit = toplevelRenderers_.find(tid);
    if (rit == toplevelRenderers_.end()) return nullptr;
    return rit->second.get();
}

// touchEvent 的坐标转换已在 native 端完成 (需要 renderer frame 尺寸)
napi_value PluginManager::ForwardTouchEvent(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    uint32_t tid;
    int32_t action;
    double x, y;
    napi_get_value_uint32(env, args[0], &tid);
    napi_get_value_int32(env, args[1], &action);
    napi_get_value_double(env, args[2], &x);
    napi_get_value_double(env, args[3], &y);

    auto* r = PluginManager::GetInstance()->GetRendererForToplevel(tid);
    if (!r) {
        OH_LOG_WARN(LOG_APP, "[MW-TouchArkTS] tl=%{public}u renderer not found", tid);
        return nullptr;
    }

    int surfW = r->GetWidth();
    int surfH = r->GetHeight();
    int fw = r->GetFrameWidth();
    int fh = r->GetFrameHeight();
    int vpX = r->GetVpX();
    int vpY = r->GetVpY();
    int vpW = r->GetVpW();
    int vpH = r->GetVpH();

    if (surfW <= 0 || surfH <= 0 || fw <= 0 || fh <= 0 || vpW <= 0 || vpH <= 0) {
        return nullptr;
    }

    // Letterbox 坐标映射
    wl_fixed_t wx = wl_fixed_from_double((x - vpX) * fw / vpW);
    wl_fixed_t wy = wl_fixed_from_double((y - vpY) * fh / vpH);

    if (action != OH_NATIVEXCOMPONENT_MOVE) {
        OH_LOG_INFO(LOG_APP, "[MW-FwdTouch] tl=%{public}u action=%{public}d px=(%{public}.0f,%{public}.0f) vp=(%{public}d,%{public}d %{public}dx%{public}d) surf=%{public}dx%{public}d frame=%{public}dx%{public}d -> wine=(%{public}.0f,%{public}.0f)",
                    tid, action, x, y, vpX, vpY, vpW, vpH, surfW, surfH, fw, fh, wl_fixed_to_double(wx), wl_fixed_to_double(wy));
    }

    auto* seat = Seat::GetInstance();

    switch (action) {
        case OH_NATIVEXCOMPONENT_DOWN: {  // TouchType.Down == 0
            wl_resource* surf = WaylandServer::GetInstance()->GetSurfaceForToplevel(tid);
            OH_LOG_INFO(LOG_APP, "[MW-FwdTouch] DOWN tl=%{public}u surf=%{public}p ptr=%{public}d focused=%{public}u",
                        tid, surf, seat->HasPointerResource(), seat->GetFocusedToplevel());
            if (surf) {
                if (seat->GetFocusedToplevel() != 0 && seat->GetFocusedToplevel() != tid)
                    seat->EnqueuePointerLeave();
                seat->EnqueuePointerEnter(tid, surf, wx, wy);
                seat->EnqueuePointerMotion(wx, wy);
                seat->EnqueuePointerButton(0x110, WL_POINTER_BUTTON_STATE_PRESSED);
            }
            break;
        }
        case OH_NATIVEXCOMPONENT_MOVE:    // TouchType.Move == 2
            if (seat->NeedsPointerEnter() || seat->GetFocusedToplevel() != tid) {
                wl_resource* surf = WaylandServer::GetInstance()->GetSurfaceForToplevel(tid);
                if (surf) {
                    if (seat->GetFocusedToplevel() != 0 && seat->GetFocusedToplevel() != tid)
                        seat->EnqueuePointerLeave();
                    seat->EnqueuePointerEnter(tid, surf, wx, wy);
                }
            }
            seat->EnqueuePointerMotion(wx, wy);
            break;
        case OH_NATIVEXCOMPONENT_UP:     // TouchType.Up == 1
            seat->EnqueuePointerButton(0x110, WL_POINTER_BUTTON_STATE_RELEASED);
            break;
        default:
            break;
    }
    return nullptr;
}

napi_value PluginManager::ForwardMouseEvent(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    uint32_t tid;
    int32_t action;
    double x, y;
    int32_t button;
    napi_get_value_uint32(env, args[0], &tid);
    napi_get_value_int32(env, args[1], &action);
    napi_get_value_double(env, args[2], &x);
    napi_get_value_double(env, args[3], &y);
    napi_get_value_int32(env, args[4], &button);

    auto* r = PluginManager::GetInstance()->GetRendererForToplevel(tid);
    if (!r) return nullptr;

    int surfW = r->GetWidth();
    int surfH = r->GetHeight();
    int fw = r->GetFrameWidth();
    int fh = r->GetFrameHeight();
    int vpX = r->GetVpX();
    int vpY = r->GetVpY();
    int vpW = r->GetVpW();
    int vpH = r->GetVpH();
    if (surfW <= 0 || surfH <= 0 || fw <= 0 || fh <= 0 || vpW <= 0 || vpH <= 0) return nullptr;

    // Letterbox 坐标映射: (px - viewport_offset) / viewport_size * frame_size
    wl_fixed_t wx = wl_fixed_from_double((x - vpX) * fw / vpW);
    wl_fixed_t wy = wl_fixed_from_double((y - vpY) * fh / vpH);

    auto* seat = Seat::GetInstance();

    if (action != OH_NATIVEXCOMPONENT_MOUSE_MOVE) {
        OH_LOG_INFO(LOG_APP, "[MW-FwdMouse] tl=%{public}u action=%{public}d px=(%{public}.0f,%{public}.0f) vp=(%{public}d,%{public}d %{public}dx%{public}d) surf=%{public}dx%{public}d frame=%{public}dx%{public}d -> wine=(%{public}.0f,%{public}.0f)",
                    tid, action, x, y, vpX, vpY, vpW, vpH, surfW, surfH, fw, fh, wl_fixed_to_double(wx), wl_fixed_to_double(wy));
    }

    if (!seat->HasPointerResource()) {
        OH_LOG_WARN(LOG_APP, "[MW-FwdMouse] ERR no pointer resource, dropped");
        return nullptr;
    }

    switch (action) {
        case OH_NATIVEXCOMPONENT_MOUSE_PRESS: {
            OH_LOG_INFO(LOG_APP, "[CLICK-PIPE]  [NAPI-FwdMouse] PRESS tl=%{public}u px=(%{public}.0f,%{public}.0f) btn=0x%{public}x ptrRes=%{public}d needsEnter=%{public}d",
                        tid, x, y, button, seat->HasPointerResource(), seat->NeedsPointerEnter());
            if (seat->NeedsPointerEnter()) {
                wl_resource* surf = WaylandServer::GetInstance()->GetSurfaceForToplevel(tid);
                OH_LOG_INFO(LOG_APP, "[CLICK-PIPE]  [NAPI-FwdMouse] surf=%{public}p for tl=%{public}u", surf, tid);
                if (surf) {
                    if (seat->GetFocusedToplevel() != 0 && seat->GetFocusedToplevel() != tid)
                        seat->EnqueuePointerLeave();
                    seat->EnqueuePointerEnter(tid, surf, wx, wy);
                    OH_LOG_INFO(LOG_APP, "[CLICK-PIPE]  [NAPI-FwdMouse] -> EnqueuePointerEnter(wx=%{public}.0f,wy=%{public}.0f)", wl_fixed_to_double(wx), wl_fixed_to_double(wy));
                }
            }
            seat->EnqueuePointerMotion(wx, wy);
            uint32_t btn = 0;
            if (button & OH_NATIVEXCOMPONENT_LEFT_BUTTON)   btn = 0x110;
            if (button & OH_NATIVEXCOMPONENT_RIGHT_BUTTON)  btn = 0x111;
            if (button & OH_NATIVEXCOMPONENT_MIDDLE_BUTTON) btn = 0x112;
            if (btn) {
                OH_LOG_INFO(LOG_APP, "[CLICK-PIPE]  [NAPI-FwdMouse] -> EnqueuePointerButton(btn=0x%{public}x,PRESSED)", btn);
                seat->EnqueuePointerButton(btn, WL_POINTER_BUTTON_STATE_PRESSED);
            }
            break;
        }
        case OH_NATIVEXCOMPONENT_MOUSE_RELEASE: {
            uint32_t btn = 0;
            if (button & OH_NATIVEXCOMPONENT_LEFT_BUTTON)   btn = 0x110;
            if (button & OH_NATIVEXCOMPONENT_RIGHT_BUTTON)  btn = 0x111;
            if (button & OH_NATIVEXCOMPONENT_MIDDLE_BUTTON) btn = 0x112;
            if (btn) seat->EnqueuePointerButton(btn, WL_POINTER_BUTTON_STATE_RELEASED);
            break;
        }
        case OH_NATIVEXCOMPONENT_MOUSE_MOVE:
            if (seat->NeedsPointerEnter() || seat->GetFocusedToplevel() != tid) {
                wl_resource* surf = WaylandServer::GetInstance()->GetSurfaceForToplevel(tid);
                if (surf) {
                    if (seat->GetFocusedToplevel() != 0 && seat->GetFocusedToplevel() != tid)
                        seat->EnqueuePointerLeave();
                    seat->EnqueuePointerEnter(tid, surf, wx, wy);
                }
            }
            seat->EnqueuePointerMotion(wx, wy);
            break;
        default:
            break;
    }
    return nullptr;
}

napi_value PluginManager::ForwardKeyEvent(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    uint32_t tid;
    int32_t keyCode;
    int32_t keyAction;
    napi_get_value_uint32(env, args[0], &tid);
    napi_get_value_int32(env, args[1], &keyCode);
    napi_get_value_int32(env, args[2], &keyAction);

    auto* seat = Seat::GetInstance();
    uint32_t evdev = Seat::MapKeycode(keyCode);
    const char* actName = (keyAction == 0) ? "DOWN" : "UP";
    OH_LOG_INFO(LOG_APP, "[KBD-PIPE]  [NAPI-Fwd] tl=%{public}u ohosCode=%{public}d -> evdev=%{public}u action=%{public}s kbdEntered=%{public}d kbdFocused=%{public}u",
                tid, keyCode, evdev, actName, seat->HasKeyboardEnter(), seat->GetKeyboardFocusedToplevel());
    if (evdev == 0) {
        OH_LOG_WARN(LOG_APP, "[KBD-PIPE]  [NAPI-Fwd] ERR unmapped ohosCode=%{public}d, dropped", keyCode);
        return nullptr;
    }

    if (!seat->HasKeyboardEnter() || seat->GetKeyboardFocusedToplevel() != tid) {
        wl_resource* surf = WaylandServer::GetInstance()->GetSurfaceForToplevel(tid);
        OH_LOG_INFO(LOG_APP, "[KBD-PIPE]  [NAPI-Enter] need kbd_enter: tid=%{public}u surf=%{public}p", tid, surf);
        if (surf) {
            if (seat->HasKeyboardEnter() && seat->GetKeyboardFocusedToplevel() != tid)
                seat->EnqueueKeyboardLeave();
            seat->EnqueueKeyboardEnter(tid, surf);
        } else {
            OH_LOG_WARN(LOG_APP, "[KBD-PIPE]  [NAPI-Enter] ERR no surface for tl=%{public}u, dropped", tid);
            return nullptr;
        }
    }

    if (!seat->HasKeyboardEnter()) {
        OH_LOG_WARN(LOG_APP, "[KBD-PIPE]  [NAPI-Enter] ERR kbd enter failed, dropped");
        return nullptr;
    }

    // KeyType.Down=0, KeyType.Up=1; wl: PRESSED=1, RELEASED=0
    uint32_t wlState = (keyAction == 0) ? WL_KEYBOARD_KEY_STATE_PRESSED
                                         : WL_KEYBOARD_KEY_STATE_RELEASED;
    OH_LOG_INFO(LOG_APP, "[KBD-PIPE]  [NAPI-Enqueue] key evdev=%{public}u wlState=%{public}u OK", evdev, wlState);
    seat->EnqueueKeyboardKey(evdev, wlState);
    return nullptr;
}
