# Wallpaper Engine for Omarchy

<p align="center">
  <img src="preview.png" alt="Wallpaper Engine for Omarchy interface" width="100%">
</p>

Omarchy / Hyprland / Quickshell plugin that plays [Steam Wallpaper Engine](https://store.steampowered.com/app/431960/) Workshop items through [Almamu/linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine). Per-display panel and optional bar widget, Style menu entries, gum TUI, boot/theme hooks. **Hyprland + Omarchy only.**

https://github.com/user-attachments/assets/8a745361-9db8-40a0-b371-2725e26a6d5e

## Requirements

This plugin is not an AUR package.

**Required** (before `omarchy-we apply`):

- [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) — AUR.

```bash
omarchy pkg aur add linux-wallpaperengine-git
```

- Steam + Wallpaper Engine Workshop items with `project.json` (`scene`, `video`, or `web`). Steam does not need to be running. Extra disks: panel folder button or `omarchy-we set-wallpaper-dirs`.

```bash
omarchy install gaming steam
```

**Optional:**

- `python-pillow` — auto-match theme only (ImageMagick can still compose stills). Not needed to apply a wallpaper.

```bash
omarchy pkg add python-pillow
```

**Paths:** plugins, config, hooks, and themes live under `~/.config/omarchy`. Runtime state is `~/.local/state/omarchy`. `XDG_CONFIG_HOME` / `XDG_STATE_HOME` are ignored. Install as a **real directory** named `io.github.14brussell.wallpaper-engine`. Do **not** symlink a mixed-case checkout (QML rejects the path).

**Layer:** leave `omarchy.background` enabled. The engine is forced to `--layer bottom`.

`install.sh` ends with `omarchy-we doctor || true`. A missing **engine** is a broken setup. `python-pillow` may show missing and still be optional.

## Install

```bash
omarchy plugin add https://github.com/14brussell/Wallpaper-Engine-Omarchy.git --enable
~/.config/omarchy/plugins/io.github.14brussell.wallpaper-engine/scripts/install.sh
```

`plugin add` clones a git checkout. `install.sh` keeps that `.git`, installs Style menu entries and hook wrappers, links `omarchy-we` / `we-omarchy`, and runs `doctor`. Do **not** run `we install-hooks` as a second setup step.

Local tree: run that tree's `scripts/install.sh`, then `omarchy plugin enable io.github.14brussell.wallpaper-engine`. Re-run the installer after source changes.

If the legacy `wallpaper-engine-omarchy` id is present, the installer prints migration commands and stops. Config is preserved.

Panel missing: `omarchy-shell shell rescanPlugins`

### Update

```bash
omarchy plugin update io.github.14brussell.wallpaper-engine
~/.config/omarchy/plugins/io.github.14brussell.wallpaper-engine/scripts/install.sh
```

Copy installs with **no** `.git` cannot use `plugin update`. This is a **one-time reinstall** (config in `~/.config/omarchy/wallpaper-engine/` is kept). Never `--purge` for an update.

```bash
omarchy plugin remove io.github.14brussell.wallpaper-engine
omarchy plugin add https://github.com/14brussell/Wallpaper-Engine-Omarchy.git --enable
~/.config/omarchy/plugins/io.github.14brussell.wallpaper-engine/scripts/install.sh
```

## Remove

Run `uninstall.sh` **before** `omarchy plugin remove` (while the plugin files still exist):

```bash
~/.config/omarchy/plugins/io.github.14brussell.wallpaper-engine/scripts/uninstall.sh
omarchy plugin remove io.github.14brussell.wallpaper-engine
```

Default: restore theme background, remove plugin-owned hooks/menu/CLI links. **Keeps** `~/.config/omarchy/wallpaper-engine/` and `~/.local/state/omarchy/wallpaper-engine/`. Does **not** delete the plugin tree (that is `plugin remove`), Steam, Workshop content, or `linux-wallpaperengine`.

`--purge` also deletes that config, state, and the generated `wallpaper-engine-auto-match` theme (ownership marker required). Irreversible. Never `--purge` to update.

```bash
~/.config/omarchy/plugins/io.github.14brussell.wallpaper-engine/scripts/uninstall.sh --purge
omarchy plugin remove io.github.14brussell.wallpaper-engine
```

## Usage

- **Style → Wallpaper Engine** — panel
- **Style → Revert to theme background** — stop engines, restore theme
- **Style → Wallpaper Engine (advanced TUI)** — gum TUI (`omarchy-we` with no args is the same; needs a TTY)
- **Bar widget:** left-click toggles the panel, middle-click TUI, right-click revert

`omarchy-we panel` · `omarchy-we menu` · `omarchy-we doctor`

### Panel

One tab per live Hyprland output. Pick a wallpaper, set scaling/FPS/clamp/audio/properties, **Save & apply**. Per-tab **Start** / **Stop**. **Clear & stop** drops that display’s saved config. Folder button adds extra Workshop libraries (Steam library, `steamapps`, or `workshop/content/431960`). Catalog and search stay cached across tabs.

**Auto-match theme** needs a live plugin-owned engine and a successfully applied source frame. Writes only `~/.config/omarchy/themes/wallpaper-engine-auto-match`. Button becomes **Undo theme match**. Last engine stop with auto-match on restores the previous theme. CLI: `omarchy-we auto-theme [monitor]` / `omarchy-we undo-auto-theme`.

Replacement waits for a complete rendered frame, then stops the old process. Failed start keeps the previous wallpaper. Scene crash before first frame: one retry with particles disabled.

### CLI

```bash
omarchy-we                  # menu (TUI; needs a TTY)
omarchy-we panel
omarchy-we doctor
omarchy-we apply [monitor…] # no names: live configured heads only
omarchy-we stop [monitor…]  # no names: all plugin engines
omarchy-we revert
omarchy-we auto-theme [monitor]
omarchy-we undo-auto-theme
omarchy-we set-wallpaper-dirs <path>…
```

`apply` / `stop` take one or more monitors. Disconnected or lid-disabled outputs are skipped. `omarchy-we properties <id>` and `omarchy-we set-property <monitor> <name> <value>` for wallpaper-specific keys.

### Hooks and files

`install.sh` already installs these wrappers (they exec current plugin sources):

- `~/.config/omarchy/hooks/post-boot.d/50-wallpaper-engine` — if `active=true`, restore saved wallpapers; `--ensure`s monitor-watch
- `~/.config/omarchy/hooks/theme-set.d/50-wallpaper-engine` — remember the real theme background for revert; does **not** tear down a live wallpaper

**monitor-watch is not a third Omarchy hook.** Post-boot starts it. It listens for Hyprland `monitoraddedv2` / `monitorremovedv2` and runs `omarchy-we sync-outputs`. It does **not** reconcile on `configreloaded` (that was tearing down live engines). Does not replace Omarchy’s clamshell watcher.

- Config: `~/.config/omarchy/wallpaper-engine/config.json`
- State / logs: `~/.local/state/omarchy/wallpaper-engine/`

Set `"nvidia_workaround": true` to run the engine with `__GL_THREADED_OPTIMIZATIONS=0`.

## Limitations

- No general mirror/flip (`linux-wallpaperengine`); wallpaper-specific flip properties still appear when present.
- Playback speed, audio-reactive, and mouse features depend on the wallpaper and the engine.
- Some Workshop items crash or fail to render in `linux-wallpaperengine` (Scene/particles/3D/scripts/Web). Those are [upstream](https://github.com/Almamu/linux-wallpaperengine/issues) compatibility issues; this plugin starts and manages the process only.
