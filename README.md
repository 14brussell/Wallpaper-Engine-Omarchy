# Wallpaper Engine for Omarchy

<p align="center">
  <img src="preview.png?v=699ba2f" alt="Wallpaper Engine for Omarchy interface" width="100%">
</p>

Omarchy shell plugin that plays [Steam Wallpaper Engine](https://store.steampowered.com/app/431960/) scenes on Hyprland through [Almamu/linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine).

It ships a **Quickshell GUI** (`FloatingWindow`, one tab per Hyprland output), an optional bar widget, Omarchy **Style** menu entries, a gum TUI fallback, and hooks. Browse Workshop wallpapers, set per-display scaling/FPS/clamp/audio/properties, start or stop `linux-wallpaperengine`, and **revert to the current Omarchy theme background**.

## Demo

https://github.com/user-attachments/assets/8a745361-9db8-40a0-b371-2725e26a6d5e

Display names and resolutions are detected from each user’s Hyprland setup.

## Highlights

- Quickshell panel with one tab per display
- Workshop browser with thumbnails, search, and wallpaper properties
- Additional Steam libraries on other disks, managed from the GUI or CLI
- Per-display wallpapers, scaling, FPS, audio, and other engine settings
- Safe replacement: a new wallpaper must render before the old one stops
- Reversible Omarchy color themes generated from the active wallpaper
- Theme restore, bar widget, CLI, hooks, and an optional gum TUI

## Requirements

- Omarchy with Hyprland and Quickshell
- [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) (`linux-wallpaperengine-git` from the AUR)
- Wallpaper Engine on Steam, including downloaded Workshop content
- `jq` and `hyprctl` (included with a normal Omarchy install)
- `python-pillow` for the wallpaper-to-theme auto-match action
- `gum` only if you want the advanced TUI

## Install

Add the plugin, then run the installer. Omarchy does not run plugin installers automatically.

```bash
omarchy plugin add https://github.com/14brussell/Wallpaper-Engine-Omarchy.git --enable
~/.config/omarchy/plugins/io.github.14brussell.wallpaper-engine/scripts/install.sh
```

For local development:

```bash
/path/to/Wallpaper-Engine-Omarchy/scripts/install.sh
omarchy plugin enable io.github.14brussell.wallpaper-engine
```

The installer copies the plugin into its canonical directory and links `omarchy-we` and `we-omarchy` into `~/.local/bin`. Do not symlink the repository into `~/.config/omarchy/plugins/`; QML may reject the path because of filename case differences. Re-run the installer after changing the source tree.

If the installer finds the legacy `wallpaper-engine-omarchy` plugin ID, it stops
before making changes and prints the exact migration commands. Remove the legacy
plugin first, then re-run the installer; the shared wallpaper configuration is
preserved across the ID migration.

If the panel does not appear, rescan plugins:

```bash
omarchy-shell shell rescanPlugins
```

Plugin validation:

```bash
omarchy plugin validate ./Wallpaper-Engine-Omarchy
```

## Remove

```bash
~/.config/omarchy/plugins/io.github.14brussell.wallpaper-engine/scripts/uninstall.sh
omarchy plugin remove io.github.14brussell.wallpaper-engine
```

Run the helper first, while the plugin files still exist. It restores the theme background and removes plugin-owned integrations. Configuration and runtime state are kept.

For a factory-clean removal, explicitly purge the plugin configuration and
runtime state before asking Omarchy to remove the checkout:

```bash
~/.config/omarchy/plugins/io.github.14brussell.wallpaper-engine/scripts/uninstall.sh --purge
omarchy plugin remove io.github.14brussell.wallpaper-engine
```

`--purge` is irreversible. It also removes the generated
`wallpaper-engine-auto-match` theme when its ownership marker is present, but
does not uninstall Omarchy, Wallpaper Engine, `linux-wallpaperengine`, or any
other dependency.

## Usage

- **Style → Wallpaper Engine:** open the panel
- **Style → Revert to theme background:** stop Wallpaper Engine and restore the theme
- **Style → Wallpaper Engine (advanced TUI):** open the gum interface
- **Bar widget:** left-click opens the panel, middle-click opens the TUI, and right-click restores the theme

### GUI (tab per display)

Open it from the Style menu, bar widget, or `omarchy-we panel`. Each live
Hyprland display gets its own tab, with **Start** and **Stop** directly below it
for that display's process. Choose a wallpaper, adjust its settings, and click
**Save & apply**. **Clear** removes only that display's configuration.

Use the folder button beside **Workshop Wallpapers** to add libraries from
other disks. You can paste a Steam library directory, its `steamapps`
directory, or the exact `workshop/content/431960` directory. Added folders are
shared by every display and automatic Steam locations remain enabled.

The lifecycle controls below the selected tab are display-specific:

- **Start:** start the selected display's saved wallpaper process
- **Stop:** stop only the selected display's process. If it is the final process and auto-match is active, restore the previously selected Omarchy theme.

The theme controls above the tabs remain global:

- **Revert to theme:** stop them and restore the Omarchy theme background
- **Auto-match theme:** build and apply an accessible Omarchy palette from the most recently successfully applied wallpaper, regardless of which display tab is selected. The control stays disabled until a wallpaper has been successfully applied. The button becomes **Undo theme match** and restores the previously selected theme.

Auto-match writes only to the plugin-owned custom theme at
`~/.config/omarchy/themes/wallpaper-engine-auto-match`. It refuses to overwrite
that path if it contains a theme not created by this plugin. Choosing another
Omarchy theme manually also clears the pending auto-match undo state.

### Advanced TUI

Run `omarchy-we menu` for the keyboard-driven fallback.

![Wallpaper Engine advanced TUI](assets/screenshots/advanced-tui.png)

## How it works with Omarchy themes

```
Omarchy: omarchy.background  →  WlrLayer.Background  (static image symlink)
WE:      linux-wallpaperengine --layer bottom         (covers the static layer)
```

- Keep Wallpaper Engine on the `bottom` layer; `background` conflicts with `omarchy.background`.
- Leave the Omarchy background service enabled.
- Apply, stop, revert, and theme changes are locked to prevent overlapping operations.

### Reliable per-display runtime

Each configured display has its own `linux-wallpaperengine` process. Applying a wallpaper starts a replacement, waits for its first rendered frame, then stops the old process. If startup fails, the previous wallpaper stays visible. Other displays are unaffected.

`we apply` starts every configured display independently. `we apply <monitor>` updates only one. If a Scene exits before rendering, the plugin retries once with particles disabled and saves that setting if the retry succeeds.

Optional readiness tuning: `WE_LWE_READY_MS`, `WE_LWE_READBACK_GRACE_MS`, and
`WE_LWE_PAINT_EPS`. `WE_LWE_SCREENSHOT_DELAY` is limited to 0–5 frames by the
current linux-wallpaperengine release and defaults to that upstream maximum.

### Hooks

- `post-boot.d/50-wallpaper-engine` restarts saved wallpapers when `active=true`.
- `theme-set.d/50-wallpaper-engine` records the new theme background for the next revert.

Install them with `we install-hooks`.

## Config

Configuration is stored in `~/.config/omarchy/wallpaper-engine/config.json`. The installer creates the defaults; this is the basic shape:

```json
{
  "version": 1,
  "engine": "linux-wallpaperengine",
  "assets_dir": "",
  "nvidia_workaround": false,
  "defaults": {
    "scaling": "fill",
    "fps": 30,
    "silent": true
  },
  "displays": {
    "<display-name>": {
      "wallpaper": "823274093",
      "scaling": "fill",
      "fps": 30,
      "properties": { "rate": "1.0" }
    }
  },
  "active": false
}
```

Set `"nvidia_workaround": true` to run the engine with `__GL_THREADED_OPTIMIZATIONS=0`.

- Runtime state and logs: `~/.local/state/omarchy/wallpaper-engine/`
- Workshop projects: Steam `workshop/content/431960/<id>/project.json`
- Extra Workshop locations: manage them from the folder button in the GUI, or
  run `omarchy-we set-wallpaper-dirs <path>...`

## CLI

```bash
omarchy-we panel
omarchy-we apply [monitor]
omarchy-we stop
omarchy-we revert
omarchy-we auto-theme [monitor]
omarchy-we undo-auto-theme
omarchy-we menu
omarchy-we monitors
omarchy-we status --json
```

Wallpaper-specific properties use `omarchy-we properties <id>` and `omarchy-we set-property <monitor> <name> <value>`. Not every wallpaper exposes a playback-speed property.

## Layout

```
Panel.qml / DisplayTab.qml   Quickshell UI
BarWidget.qml                Bar launcher
bin/we                       CLI
lib/common.sh                Engine and theme integration
lib/generate_theme.py        Wallpaper palette generator
scripts/                     Installer, TUI, and menu helpers
hooks/                       Boot and theme hooks
```

## Limitations

- Mirroring is unavailable because `linux-wallpaperengine` has no general flip option. Wallpaper-specific flip properties still appear when supported.
- Playback-speed, audio-reactive, and mouse-interactive behavior depends on the wallpaper and `linux-wallpaperengine` support.
- Some Workshop wallpapers can crash the underlying `linux-wallpaperengine` process. Wallpaper Engine projects may contain Scene data, older particle effects, 3D features, scripts, or Web content that the Linux reimplementation does not fully support. Unexpected project data can also expose bugs in the engine. These are upstream compatibility failures, not crashes caused by this plugin; the plugin starts and manages `linux-wallpaperengine`, but does not render the wallpaper.
- If the engine exits before its first frame, the plugin leaves the previous wallpaper running. Scene wallpapers are retried once with particles disabled, and each display remains isolated in its own process. Engine output is saved under `~/.local/state/omarchy/wallpaper-engine/` for troubleshooting. See the [linux-wallpaperengine issue tracker](https://github.com/Almamu/linux-wallpaperengine/issues) for upstream compatibility reports.
