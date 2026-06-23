# Known Issues

## Intentional current limitations

- `WINEDLLOVERRIDES=mscoree,mshtml=` is set on purpose to suppress Mono/Gecko first-run dialogs.
- `.NET` and `mshtml` dependent apps are not a default success target right now.
- Optional Wayland protocols are still missing for:
  - clipboard
  - pointer lock / confinement
  - relative pointer motion
  - host IME integration
  - toplevel icons

## Build pitfalls

- Do not split `deps`, `wine`, `native`, `hnp`, and `hap` across separate WSL invocations.
- Treat `scripts/rebuild_harmony.sh` and `scripts/rebuild_harmony.ps1` as the anti-footgun layer; update them first when the workflow changes.
- A missing recursive `thirdparty/freetype/subprojects/dlg` checkout is currently a warning, not a proven blocker for the validated path.

## Runtime assumptions

- The working HNP runtime layout is centered around `opt/winehua/bin/`.
- `ntdll.so` must live in `opt/winehua/bin/`.
- Unix Wine `.so` files live in `opt/winehua/bin/x86_64-unix/`.
- PE runtime files live in `opt/winehua/bin/x86_64-windows/`.

## What is currently the strongest signal of success

- The app installs on the HarmonyOS `2in1` PC emulator.
- `wineserver` starts.
- `wineboot --init` is no longer blocked by `Wine Mono Installer`.
- `notepad.exe` launches.
