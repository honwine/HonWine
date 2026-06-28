#pragma once

#include "graphics_types.h"

#include <GLES3/gl3.h>

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace winehua {

struct SurfaceTexture
{
    GLuint texture = 0;
    int width = 0;
    int height = 0;
    uint64_t lastBufferSerial = 0;
    uint64_t lastDamageSerial = 0;
};

class SurfaceTextureCache
{
public:
    struct UploadResult
    {
        bool textureCreated = false;
        bool uploaded = false;
        bool fullUpload = false;
        uint64_t uploadBytes = 0;
        uint64_t damagePixels = 0;
        uint64_t damageRectCount = 0;
        uint64_t mergedDamagePixels = 0;
        bool fullSurfaceDamage = false;
        bool partialDamage = false;
    };

    UploadResult UpdateTexture(uint64_t key,
                               int width,
                               int height,
                               uint64_t bufferSerial,
                               uint64_t damageSerial,
                               const std::shared_ptr<const std::vector<uint8_t>>& pixels,
                               const std::vector<DamageRect>& damages);
    GLuint FindTexture(uint64_t key) const;
    void EraseMissing(const std::unordered_set<uint64_t>& liveKeys);
    void Clear();

private:
    std::unordered_map<uint64_t, SurfaceTexture> textures_;
};

} // namespace winehua
