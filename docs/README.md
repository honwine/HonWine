# WineHua 文档索引

> 更新日期: 2026-06-22

## 先看这四份

- [ONBOARDING.md](ONBOARDING.md): 第一次接手仓库时的 10 分钟上手清单。
- [BUILD_GUIDE.md](BUILD_GUIDE.md): 当前推荐的快速构建、打包、安装与日志流程。
- [CURRENT_STATUS.md](CURRENT_STATUS.md): 已验证能力、剩余问题和当前默认假设。
- [ARCHITECTURE.md](ARCHITECTURE.md): 代码主链路、Wayland compositor、NAPI 和多窗口结构。
- [AUDIO_ARCHITECTURE.md](AUDIO_ARCHITECTURE.md): 当前音频 broker、共享内存、混频和格式策略。

## 当前推荐入口

- Windows 宿主机一键入口: `scripts/rebuild_harmony.ps1`
- WSL 内单 shell 构建入口: `scripts/rebuild_harmony.sh`
- 底层原子命令入口: `build.sh`

推荐顺序是先看 `ONBOARDING.md`，再用 `rebuild_harmony.ps1`，只有在需要拆解单步排查时再直接调用 `build.sh`。

## 历史/研究文档

- [SOURCE_MANAGEMENT.md](SOURCE_MANAGEMENT.md): thirdparty 源码和 submodule 管理。
- [NOEXEC_MMAP_ANALYSIS.md](NOEXEC_MMAP_ANALYSIS.md): noexec 与可执行映射问题分析。
- [OHOS_MMAP_ANALYSIS.md](OHOS_MMAP_ANALYSIS.md): OHOS mmap 行为研究。
- [WINE_MUSL_GLIBC_DIFF.md](WINE_MUSL_GLIBC_DIFF.md): musl/glibc 差异排查记录。
- [UNCERTAINTIES.md](UNCERTAINTIES.md): 历史风险清单。
- [PHASE2_ARM64_RESEARCH.md](PHASE2_ARM64_RESEARCH.md): ARM64 方向的研究草稿。

## 文档使用建议

- 第一次接手仓库: 先读 `ONBOARDING.md`。
- 想快速复现环境或重建 HAP: 再读 `BUILD_GUIDE.md`。
- 想知道现在“到底跑到了什么程度”: 读 `CURRENT_STATUS.md`。
- 想改代码而不是只会构建: 再补 `ARCHITECTURE.md`。
- 想继续做音频、多格式验证或排查“有解码没出声”: 再读 `AUDIO_ARCHITECTURE.md`。
