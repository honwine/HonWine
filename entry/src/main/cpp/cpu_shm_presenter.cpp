#include "cpu_shm_presenter.h"

#include "graphics_broker.h"

#include <chrono>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "WL_GFX_CPU"
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
        OH_LOG_ERROR(LOG_APP, "[CpuShmPresenter] shader compile failed: %{public}s", log);
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

bool CpuShmPresenter::Init(EGLDisplay display, EGLContext, EGLSurface surface)
{
    static const float quad[] = {
        -1.f, -1.f, 0.f, 1.f,
         1.f, -1.f, 1.f, 1.f,
        -1.f,  1.f, 0.f, 0.f,
         1.f, -1.f, 1.f, 1.f,
         1.f,  1.f, 1.f, 0.f,
        -1.f,  1.f, 0.f, 0.f,
    };

    display_ = display;
    surface_ = surface;
    lastError_.clear();
    rendered_ = false;

    program_ = BuildProgram();
    glGenBuffers(1, &vbo_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);

    glGenTextures(1, &texture_);
    glBindTexture(GL_TEXTURE_2D, texture_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return true;
}

void CpuShmPresenter::Resize(int hostWidth, int hostHeight)
{
    hostWidth_ = hostWidth;
    hostHeight_ = hostHeight;
}

void CpuShmPresenter::DrawCurrentTexture(int hostWidth, int hostHeight, int frameWidth, int frameHeight)
{
    ViewportRect viewport = ComputeLetterboxViewport(hostWidth, hostHeight, frameWidth, frameHeight);
    glViewport(viewport.x, viewport.y, viewport.w, viewport.h);
    glClearColor(0.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);

    glUseProgram(program_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, reinterpret_cast<void*>(0));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, reinterpret_cast<void*>(8));
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture_);
    glUniform1i(glGetUniformLocation(program_, "uTex"), 0);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    eglSwapBuffers(display_, surface_);
}

bool CpuShmPresenter::Present(const PresentFrameArgs& args, PresentFrameResult& result)
{
    using Clock = std::chrono::steady_clock;

    std::vector<uint8_t> pixels;
    uint32_t sourceToplevelId = 0;
    int frameWidth = 0;
    int frameHeight = 0;
    auto presentStart = Clock::now();
    bool haveFrame = GraphicsBroker::GetInstance().TakeFrameForToplevel(
        args.rendererToplevelId, pixels, frameWidth, frameHeight, &sourceToplevelId);

    stats_.frameCount++;

    if (!haveFrame || frameWidth <= 0 || frameHeight <= 0)
    {
        int currentHostWidth = hostWidth_ > 0 ? hostWidth_ : args.hostWidth;
        int currentHostHeight = hostHeight_ > 0 ? hostHeight_ : args.hostHeight;
        bool hostResized = currentHostWidth != lastPresentedHostWidth_ ||
                           currentHostHeight != lastPresentedHostHeight_;
        if (rendered_ && texWidth_ > 0 && texHeight_ > 0 && hostResized)
        {
            DrawCurrentTexture(currentHostWidth, currentHostHeight, texWidth_, texHeight_);
            lastPresentedHostWidth_ = currentHostWidth;
            lastPresentedHostHeight_ = currentHostHeight;
            result.presented = true;
            result.contentAvailable = true;
            result.contentWidth = texWidth_;
            result.contentHeight = texHeight_;
            lastError_.clear();
            LogStatsIfNeeded();
            return true;
        }

        if (rendered_) stats_.skippedFrames++;
        lastError_.clear();
        LogStatsIfNeeded();
        return false;
    }

    auto uploadStart = Clock::now();
    glBindTexture(GL_TEXTURE_2D, texture_);
    if (frameWidth != texWidth_ || frameHeight != texHeight_)
    {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, frameWidth, frameHeight, 0,
                     GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
        texWidth_ = frameWidth;
        texHeight_ = frameHeight;
        stats_.fullUploadFrames++;
    }
    else
    {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, frameWidth, frameHeight,
                        GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
        stats_.fullUploadFrames++;
    }
    auto uploadEnd = Clock::now();

    int currentHostWidth = hostWidth_ > 0 ? hostWidth_ : args.hostWidth;
    int currentHostHeight = hostHeight_ > 0 ? hostHeight_ : args.hostHeight;
    DrawCurrentTexture(currentHostWidth, currentHostHeight, frameWidth, frameHeight);

    auto presentEnd = Clock::now();
    double uploadMs =
        std::chrono::duration<double, std::milli>(uploadEnd - uploadStart).count();
    double presentMs =
        std::chrono::duration<double, std::milli>(presentEnd - presentStart).count();

    stats_.glUploadBytes += pixels.size();
    UpdateGraphicsAverage(uploadMs, stats_.lastUploadMs, stats_.avgUploadMs, stats_.frameCount);
    UpdateGraphicsAverage(presentMs, stats_.lastPresentMs, stats_.avgPresentMs, stats_.frameCount);

    rendered_ = true;
    lastPresentedHostWidth_ = currentHostWidth;
    lastPresentedHostHeight_ = currentHostHeight;
    result.presented = true;
    result.contentAvailable = true;
    result.contentWidth = frameWidth;
    result.contentHeight = frameHeight;
    lastError_.clear();

    ViewportRect viewport = ComputeLetterboxViewport(currentHostWidth, currentHostHeight, frameWidth, frameHeight);
    OH_LOG_DEBUG(LOG_APP,
                 "[CpuShmPresenter] tl=%{public}u source=%{public}u frame=%{public}dx%{public}d viewport=%{public}dx%{public}d+%{public}d,%{public}d",
                 args.rendererToplevelId, sourceToplevelId, frameWidth, frameHeight,
                 viewport.w, viewport.h, viewport.x, viewport.y);
    LogStatsIfNeeded();
    return true;
}

void CpuShmPresenter::Destroy()
{
    if (texture_ != 0) glDeleteTextures(1, &texture_);
    if (vbo_ != 0) glDeleteBuffers(1, &vbo_);
    if (program_ != 0) glDeleteProgram(program_);

    texture_ = 0;
    vbo_ = 0;
    program_ = 0;
    hostWidth_ = 0;
    hostHeight_ = 0;
    texWidth_ = 0;
    texHeight_ = 0;
    lastPresentedHostWidth_ = 0;
    lastPresentedHostHeight_ = 0;
    rendered_ = false;
}

void CpuShmPresenter::LogStatsIfNeeded() const
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

} // namespace winehua
