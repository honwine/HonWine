#pragma once

#include <cstdint>

namespace winehua {

struct GraphicsStats
{
    uint64_t frameCount = 0;
    uint64_t cpuCopyBytes = 0;
    uint64_t surfaceCommitCount = 0;
    uint64_t surfaceCommitBytes = 0;
    uint64_t snapshotCopyCount = 0;
    uint64_t snapshotCopyBytes = 0;
    uint64_t glUploadBytes = 0;
    uint64_t skippedFrames = 0;
    uint64_t damagePixels = 0;
    uint64_t damageRectCount = 0;
    uint64_t mergedDamagePixels = 0;
    uint64_t fullSurfaceDamageCount = 0;
    uint64_t partialDamageCount = 0;
    uint64_t fullUploadFrames = 0;
    uint64_t partialUploadFrames = 0;

    double lastPresentMs = 0.0;
    double avgPresentMs = 0.0;
    double lastUploadMs = 0.0;
    double avgUploadMs = 0.0;
};

inline void UpdateGraphicsAverage(double sample, double& lastValue, double& avgValue, uint64_t count)
{
    lastValue = sample;
    if (count <= 1)
    {
        avgValue = sample;
        return;
    }

    avgValue = ((avgValue * static_cast<double>(count - 1)) + sample) / static_cast<double>(count);
}

} // namespace winehua
