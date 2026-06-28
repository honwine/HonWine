#include "surface_texture_cache.h"

#include <algorithm>

namespace winehua {

namespace {

DamageRect MergeDamages(const std::vector<DamageRect>& damages,
                        int width,
                        int height,
                        uint64_t* outDamagePixels,
                        uint64_t* outDamageRectCount)
{
    DamageRect merged;
    bool haveRect = false;
    uint64_t pixels = 0;
    uint64_t rectCount = 0;

    for (const DamageRect& damage : damages)
    {
        DamageRect clipped = ClipDamageRect(damage, width, height);
        if (IsDamageRectEmpty(clipped)) continue;

        rectCount++;
        pixels += static_cast<uint64_t>(clipped.w) * static_cast<uint64_t>(clipped.h);
        if (!haveRect)
        {
            merged = clipped;
            haveRect = true;
            continue;
        }

        int x1 = std::min(merged.x, clipped.x);
        int y1 = std::min(merged.y, clipped.y);
        int x2 = std::max(merged.x + merged.w, clipped.x + clipped.w);
        int y2 = std::max(merged.y + merged.h, clipped.y + clipped.h);
        merged.x = x1;
        merged.y = y1;
        merged.w = x2 - x1;
        merged.h = y2 - y1;
    }

    if (outDamagePixels) *outDamagePixels = pixels;
    if (outDamageRectCount) *outDamageRectCount = rectCount;
    return haveRect ? merged : DamageRect{};
}

void DestroyTexture(GLuint texture)
{
    if (texture != 0) glDeleteTextures(1, &texture);
}

} // namespace

SurfaceTextureCache::UploadResult SurfaceTextureCache::UpdateTexture(uint64_t key,
                                                                     int width,
                                                                     int height,
                                                                     uint64_t bufferSerial,
                                                                     uint64_t damageSerial,
                                                                     const std::shared_ptr<const std::vector<uint8_t>>& pixels,
                                                                     const std::vector<DamageRect>& damages)
{
    UploadResult result;
    SurfaceTexture& surface = textures_[key];
    bool needRecreate = false;
    bool needFullUpload = false;
    bool needPartialUpload = false;
    DamageRect mergedDamage;

    if (!pixels || width <= 0 || height <= 0) return result;

    needRecreate = (surface.texture == 0 || surface.width != width || surface.height != height);
    if (needRecreate)
    {
        DestroyTexture(surface.texture);
        glGenTextures(1, &surface.texture);
        glBindTexture(GL_TEXTURE_2D, surface.texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        surface.width = width;
        surface.height = height;
        result.textureCreated = true;
        needFullUpload = true;
    }
    else
    {
        glBindTexture(GL_TEXTURE_2D, surface.texture);
    }

    if (surface.lastBufferSerial == bufferSerial && surface.lastDamageSerial == damageSerial) return result;

    if (!needFullUpload)
    {
        uint64_t damagePixels = 0;
        uint64_t damageRectCount = 0;
        mergedDamage = MergeDamages(damages, width, height, &damagePixels, &damageRectCount);
        result.damagePixels = damagePixels;
        result.damageRectCount = damageRectCount;

        if (IsDamageRectEmpty(mergedDamage))
        {
            needFullUpload = true;
            result.fullSurfaceDamage = true;
        }
        else
        {
            uint64_t surfacePixels = static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
            uint64_t mergedPixels = static_cast<uint64_t>(mergedDamage.w) * static_cast<uint64_t>(mergedDamage.h);
            result.mergedDamagePixels = mergedPixels;
            needFullUpload = mergedPixels * 100ULL >= surfacePixels * 60ULL;
            needPartialUpload = !needFullUpload;
            result.fullSurfaceDamage = needFullUpload;
            result.partialDamage = needPartialUpload;
        }
    }

    if (needFullUpload)
    {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels->data());
        result.uploaded = true;
        result.fullUpload = true;
        result.uploadBytes = static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4ULL;
        if (result.damageRectCount == 0)
        {
            result.fullSurfaceDamage = true;
            result.mergedDamagePixels = static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
        }
    }
    else if (needPartialUpload)
    {
        const uint8_t* src = pixels->data() + ((mergedDamage.y * width) + mergedDamage.x) * 4;
        glPixelStorei(GL_UNPACK_ROW_LENGTH, width);
        glTexSubImage2D(GL_TEXTURE_2D,
                        0,
                        mergedDamage.x,
                        mergedDamage.y,
                        mergedDamage.w,
                        mergedDamage.h,
                        GL_RGBA,
                        GL_UNSIGNED_BYTE,
                        src);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        result.uploaded = true;
        result.fullUpload = false;
        result.uploadBytes = static_cast<uint64_t>(mergedDamage.w) * static_cast<uint64_t>(mergedDamage.h) * 4ULL;
        result.partialDamage = true;
    }

    surface.lastBufferSerial = bufferSerial;
    surface.lastDamageSerial = damageSerial;
    return result;
}

GLuint SurfaceTextureCache::FindTexture(uint64_t key) const
{
    auto it = textures_.find(key);
    if (it == textures_.end()) return 0;
    return it->second.texture;
}

void SurfaceTextureCache::EraseMissing(const std::unordered_set<uint64_t>& liveKeys)
{
    for (auto it = textures_.begin(); it != textures_.end(); )
    {
        if (liveKeys.find(it->first) == liveKeys.end())
        {
            DestroyTexture(it->second.texture);
            it = textures_.erase(it);
            continue;
        }
        ++it;
    }
}

void SurfaceTextureCache::Clear()
{
    for (auto& entry : textures_) DestroyTexture(entry.second.texture);
    textures_.clear();
}

} // namespace winehua
