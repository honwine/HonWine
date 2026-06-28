#include "gl_compositor_presenter.h"

#include "graphics_broker.h"
#include "wayland_server.h"

#include <chrono>
#include <unordered_set>

#undef LOG_TAG
#define LOG_TAG "WL_GFX_GL"
#include <hilog/log.h>

namespace winehua {

namespace {

static const char* kVertexShader = R"(#version 300 es
layout(location=0) in vec2 aPos;
layout(location=1) in vec2 aUV;
out vec2 vUV;
void main() { vUV = aUV; gl_Position = vec4(aPos, 0.0, 1.0); }
)";

static const char* kFragmentShader = R"(#version 300 es
precision mediump float;
in vec2 vUV;
out vec4 oColor;
uniform sampler2D uTex;
void main() {
    vec4 texel = texture(uTex, vUV);
    oColor = vec4(texel.bgr, texel.a);
}
)";

GLuint CompileShader(GLenum type, const char* source)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);

    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled)
    {
        char log[1024] = {};
        glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        OH_LOG_ERROR(LOG_APP, "[GlCompositorPresenter] shader compile failed: %{public}s", log);
    }

    return shader;
}

GLuint BuildProgram()
{
    GLuint vertex = CompileShader(GL_VERTEX_SHADER, kVertexShader);
    GLuint fragment = CompileShader(GL_FRAGMENT_SHADER, kFragmentShader);
    GLuint program = glCreateProgram();

    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);

    return program;
}

} // namespace

bool GlCompositorPresenter::Init(EGLDisplay display, EGLContext, EGLSurface surface)
{
    static const float emptyQuad[24] = {};

    display_ = display;
    surface_ = surface;
    lastError_.clear();
    lastSceneSerial_ = 0;
    lastPresentedHostWidth_ = 0;
    lastPresentedHostHeight_ = 0;
    rendered_ = false;

    program_ = BuildProgram();
    glGenBuffers(1, &vbo_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(emptyQuad), emptyQuad, GL_DYNAMIC_DRAW);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    return true;
}

void GlCompositorPresenter::Resize(int hostWidth, int hostHeight)
{
    hostWidth_ = hostWidth;
    hostHeight_ = hostHeight;
}

bool GlCompositorPresenter::Present(const PresentFrameArgs& args, PresentFrameResult& result)
{
    using Clock = std::chrono::steady_clock;

    WaylandServer::SceneSnapshot scene;
    auto presentStart = Clock::now();

    stats_.frameCount++;

    if (!WaylandServer::GetInstance()->GetSceneSnapshot(args.rendererToplevelId, scene) ||
        scene.canvasWidth <= 0 || scene.canvasHeight <= 0 || scene.surfaces.empty())
    {
        stats_.skippedFrames++;
        lastError_.clear();
        LogStatsIfNeeded();
        return false;
    }

    int currentHostWidth = hostWidth_ > 0 ? hostWidth_ : args.hostWidth;
    int currentHostHeight = hostHeight_ > 0 ? hostHeight_ : args.hostHeight;
    bool hostResized = currentHostWidth != lastPresentedHostWidth_ ||
                       currentHostHeight != lastPresentedHostHeight_;
    bool sceneChanged = !rendered_ || scene.sceneSerial != lastSceneSerial_;

    if (!sceneChanged && !hostResized)
    {
        stats_.skippedFrames++;
        lastError_.clear();
        LogStatsIfNeeded();
        return false;
    }

    ViewportRect viewport = ComputeLetterboxViewport(
        currentHostWidth,
        currentHostHeight,
        scene.canvasWidth,
        scene.canvasHeight);
    std::unordered_set<uint64_t> liveKeys;
    auto uploadStart = Clock::now();

    glViewport(viewport.x, viewport.y, viewport.w, viewport.h);
    glClearColor(0.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(program_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, reinterpret_cast<void*>(0));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, reinterpret_cast<void*>(8));

    if (sceneChanged)
    {
        for (const WaylandServer::SceneSurfaceSnapshot& surface : scene.surfaces)
        {
            if (!surface.pixels || surface.width <= 0 || surface.height <= 0) continue;

            liveKeys.insert(surface.cacheKey);
            SurfaceTextureCache::UploadResult upload = textureCache_.UpdateTexture(
                surface.cacheKey,
                surface.width,
                surface.height,
                surface.bufferSerial,
                surface.damageSerial,
                surface.pixels,
                surface.damages);
            if (upload.uploaded)
            {
                stats_.glUploadBytes += upload.uploadBytes;
                stats_.damagePixels += upload.damagePixels;
                stats_.damageRectCount += upload.damageRectCount;
                stats_.mergedDamagePixels += upload.mergedDamagePixels;
                if (upload.fullSurfaceDamage) stats_.fullSurfaceDamageCount++;
                if (upload.partialDamage) stats_.partialDamageCount++;
                if (upload.fullUpload) stats_.fullUploadFrames++;
                else stats_.partialUploadFrames++;
            }
        }

        textureCache_.EraseMissing(liveKeys);
    }

    auto uploadEnd = Clock::now();

    for (const WaylandServer::SceneSurfaceSnapshot& surface : scene.surfaces)
    {
        if (!surface.pixels || surface.width <= 0 || surface.height <= 0) continue;
        GLuint texture = textureCache_.FindTexture(surface.cacheKey);
        if (texture == 0) continue;
        DrawSurface(texture,
                    surface.opaque,
                    surface.x,
                    surface.y,
                    surface.width,
                    surface.height,
                    scene.canvasWidth,
                    scene.canvasHeight,
                    viewport);
    }

    eglSwapBuffers(display_, surface_);

    auto presentEnd = Clock::now();
    UpdateGraphicsAverage(
        std::chrono::duration<double, std::milli>(uploadEnd - uploadStart).count(),
        stats_.lastUploadMs,
        stats_.avgUploadMs,
        stats_.frameCount);
    UpdateGraphicsAverage(
        std::chrono::duration<double, std::milli>(presentEnd - presentStart).count(),
        stats_.lastPresentMs,
        stats_.avgPresentMs,
        stats_.frameCount);

    rendered_ = true;
    lastSceneSerial_ = scene.sceneSerial;
    lastPresentedHostWidth_ = currentHostWidth;
    lastPresentedHostHeight_ = currentHostHeight;
    result.presented = true;
    result.contentAvailable = true;
    result.contentWidth = scene.canvasWidth;
    result.contentHeight = scene.canvasHeight;
    lastError_.clear();
    LogStatsIfNeeded();
    return true;
}

void GlCompositorPresenter::Destroy()
{
    textureCache_.Clear();
    if (vbo_ != 0) glDeleteBuffers(1, &vbo_);
    if (program_ != 0) glDeleteProgram(program_);
    vbo_ = 0;
    program_ = 0;
    hostWidth_ = 0;
    hostHeight_ = 0;
    lastPresentedHostWidth_ = 0;
    lastPresentedHostHeight_ = 0;
    lastSceneSerial_ = 0;
    rendered_ = false;
}

void GlCompositorPresenter::LogStatsIfNeeded() const
{
    if (stats_.frameCount == 0 || (stats_.frameCount % 120ULL) != 0ULL) return;

    GraphicsBackendState state = GraphicsBroker::GetInstance().GetState();
    OH_LOG_INFO(LOG_APP,
                "[GraphicsStats] backend=%{public}s presenter=%{public}s frames=%{public}llu"
                " fallback=%{public}s damage_upload=%{public}s"
                " commit_count=%{public}llu snapshot_count=%{public}llu"
                " total_cpu_copy_mb=%{public}.2f commit_copy_mb=%{public}.2f snapshot_copy_mb=%{public}.2f"
                " gl_upload_mb=%{public}.2f skipped=%{public}llu"
                " damage_rects=%{public}llu damage_px=%{public}llu merged_damage_px=%{public}llu"
                " full_damage=%{public}llu partial_damage=%{public}llu"
                " full_upload=%{public}llu partial_upload=%{public}llu"
                " avg_present_ms=%{public}.2f avg_upload_ms=%{public}.2f",
                GraphicsBroker::BackendName(state.active),
                FramePresenterPathName(Path()),
                static_cast<unsigned long long>(stats_.frameCount),
                state.fallbackActive ? "true" : "false",
                state.damageUploadActive ? "true" : "false",
                static_cast<unsigned long long>(state.stats.surfaceCommitCount),
                static_cast<unsigned long long>(state.stats.snapshotCopyCount),
                static_cast<double>(state.stats.cpuCopyBytes) / (1024.0 * 1024.0),
                static_cast<double>(state.stats.surfaceCommitBytes) / (1024.0 * 1024.0),
                static_cast<double>(state.stats.snapshotCopyBytes) / (1024.0 * 1024.0),
                static_cast<double>(state.stats.glUploadBytes) / (1024.0 * 1024.0),
                static_cast<unsigned long long>(stats_.skippedFrames),
                static_cast<unsigned long long>(stats_.damageRectCount),
                static_cast<unsigned long long>(stats_.damagePixels),
                static_cast<unsigned long long>(stats_.mergedDamagePixels),
                static_cast<unsigned long long>(stats_.fullSurfaceDamageCount),
                static_cast<unsigned long long>(stats_.partialDamageCount),
                static_cast<unsigned long long>(stats_.fullUploadFrames),
                static_cast<unsigned long long>(stats_.partialUploadFrames),
                stats_.avgPresentMs,
                stats_.avgUploadMs);
}

void GlCompositorPresenter::DrawSurface(GLuint texture,
                                        bool opaque,
                                        int x,
                                        int y,
                                        int width,
                                        int height,
                                        int canvasWidth,
                                        int canvasHeight,
                                        const ViewportRect&) const
{
    float left = (static_cast<float>(x) / static_cast<float>(canvasWidth)) * 2.f - 1.f;
    float right = (static_cast<float>(x + width) / static_cast<float>(canvasWidth)) * 2.f - 1.f;
    float top = 1.f - (static_cast<float>(y) / static_cast<float>(canvasHeight)) * 2.f;
    float bottom = 1.f - (static_cast<float>(y + height) / static_cast<float>(canvasHeight)) * 2.f;
    const float quad[] = {
        left,  bottom, 0.f, 1.f,
        right, bottom, 1.f, 1.f,
        left,  top,    0.f, 0.f,
        right, bottom, 1.f, 1.f,
        right, top,    1.f, 0.f,
        left,  top,    0.f, 0.f,
    };

    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_DYNAMIC_DRAW);
    if (opaque) glDisable(GL_BLEND);
    else glEnable(GL_BLEND);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture);
    glUniform1i(glGetUniformLocation(program_, "uTex"), 0);
    glDrawArrays(GL_TRIANGLES, 0, 6);
}

} // namespace winehua
