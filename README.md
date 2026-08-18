# Wallpaper Rotator — a Singularity plugin

Changes the desktop wallpaper on a schedule.

## Why this exists

Singularity can set a wallpaper and remembers recent ones, but it cannot change
one on a schedule. `WallpaperManager` in the shell loads, scales and previews an
image and emits `wallpaper_changed`; there is no timer, interval or shuffle
anywhere in it, and `dev.sinty.desktop` has no rotation keys. This plugin adds
that one capability and nothing else.

## How it works

The wallpaper is owned by the `background-picture-uri` key in
`dev.sinty.desktop`, and the shell already watches that key. Writing the key is
therefore the entire mechanism:

- the shell repaints through its normal path,
- the lockscreen and greeter pick the value up exactly as they always do,
- and the plugin can be unloaded at any moment without leaving anything
  half-applied.

Nothing in `WallpaperManager` is touched, and no shared library is modified.

## Settings

`dev.sinty.plugin.wallpaper-rotator`:

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Rotate at all |
| `interval-minutes` | `10` | Minutes each wallpaper is shown (1–1440) |
| `directory` | *(empty)* | Folder to draw from; empty means the folder of the current wallpaper |
| `shuffle` | `true` | Random order, avoiding an immediate repeat |

A settings widget is provided through `get_settings_widget()`, so the options
appear under the plugin's entry in Singularity Settings.

Two deliberate details: symlinks in the folder are skipped, because a rotation
folder often contains a `default` or `current` link pointing at one of the real
images and following it makes that image appear twice as often as the others;
and the first change happens after one full interval rather than immediately,
because changing the wallpaper the instant the shell starts reads as a glitch.

## Building

```bash
meson setup build
ninja -C build
sudo ninja -C build install
```

For development without installing:

```bash
SINGULARITY_PLUGIN_PATH=$PWD/build singularity-desktop
```

Enable it by adding `wallpaper-rotator` to the `enabled-plugins` key in
`dev.sinty.desktop`, or from the Plugins page in Singularity Settings.

## Licence

GPL-3.0-or-later.
