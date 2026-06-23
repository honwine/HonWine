---
name: winehua-harmony-build
description: Build, package, deploy, and troubleshoot WineHua in this repository across HarmonyOS targets. Use when working on WSL + Windows DevEco builds, HNP/HAP packaging, x86_64 PC emulator deployment, arm64 device builds, or runtime issues around wineserver, wineboot, notepad, cmd, and the shared rebuild scripts.
---

# WineHua Build

Use this skill for build and deployment work in `D:\Work\WineHua`.

## Quick Start

1. Read [`docs/BUILD_GUIDE.md`](../../../docs/BUILD_GUIDE.md) for the current canonical workflow.
2. If this is the first time touching the repository, read [`docs/ONBOARDING.md`](../../../docs/ONBOARDING.md) before doing anything else.
3. Read [`docs/CURRENT_STATUS.md`](../../../docs/CURRENT_STATUS.md) if the task involves runtime expectations or suspected regressions.
4. Prefer the shared rebuild entrypoints instead of hand-assembling `build.sh` commands:
   - Windows host: `scripts/rebuild_harmony.ps1`
   - WSL build-only: `scripts/rebuild_harmony.sh`

## Workflow

### Choose the entrypoint

- Use `scripts/rebuild_harmony.ps1` when the task includes build + install + start + log collection.
- Use `scripts/rebuild_harmony.sh` when the task is build-only inside WSL.
- Use raw `build.sh` only for step-by-step debugging of a single failing stage.

### Choose the mode

- Use `full` when `thirdparty/`, Wine, Box64, SDK env detection, or sysroot/deps changed.
- Use `incremental` when `entry/src/main/cpp`, ArkTS, HNP layout, signing, or packaging glue changed.
- Use `package` when only the HNP/HAP assembly or deploy path changed.
- Use `deploy` or `logs` when an existing HAP is already good enough to retest.
- Use `doctor` before blaming the codebase; it validates the current toolchain and visible `hdc` targets.

### Choose the target

- Use `-Target 127.0.0.1:5555` for the HarmonyOS PC emulator unless the user provides a different target.
- Use explicit `-Target <ip:port>` when multiple devices are connected.
- Use `auto` only when exactly one `hdc` target is visible.

## Important Rules

- Keep the full build chain inside one WSL shell. Do not split `deps`, `wine`, `native`, `hnp`, and `hap` across separate WSL invocations.
- Treat `scripts/rebuild_harmony.ps1` and `scripts/rebuild_harmony.sh` as the source of truth for future build automation changes.
- Remember that Mono/Gecko interactive installation is intentionally suppressed via `WINEDLLOVERRIDES=mscoree,mshtml=`. Do not file `.NET` or `mshtml` failures as unrelated regressions without checking this first.
- Treat missing optional Wayland protocols as known limitations unless the task is specifically about clipboard, pointer lock, relative pointer, or IME support.

## References

- Read [references/workflow.md](references/workflow.md) for command selection, artifacts, and validation.
- Read [references/known-issues.md](references/known-issues.md) for the current pitfalls and non-goals.
