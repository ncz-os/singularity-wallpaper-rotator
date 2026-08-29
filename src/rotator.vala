/*
 * Wallpaper Rotator — a Singularity plugin.
 *
 * Singularity can set a wallpaper and remembers recent ones, but it has no way
 * to change it on a schedule: WallpaperManager loads, scales and previews an
 * image and emits wallpaper_changed, and there is no timer, interval or
 * shuffle anywhere in the shell. This plugin adds that, and nothing else.
 *
 * It deliberately does not touch WallpaperManager. The wallpaper is owned by
 * the "background-picture-uri" key in dev.sinty.desktop, and the shell already
 * watches that key. Writing the key is therefore the whole mechanism: the
 * shell repaints through its normal path, the lockscreen and greeter pick the
 * value up the way they always do, and this plugin can be unloaded at any
 * moment without leaving anything half-applied.
 *
 * Copyright © 2026 Jason Perlow
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

using Gtk;

namespace WallpaperRotator {

    private const string DESKTOP_SCHEMA = "dev.sinty.desktop";
    private const string DESKTOP_KEY    = "background-picture-uri";
    private const string OWN_SCHEMA     = "dev.sinty.plugin.wallpaper-rotator";

    public class Plugin : Object, Singularity.Plugin {

        private GLib.Settings? settings = null;
        private GLib.Settings? desktop  = null;
        private uint timer_id = 0;
        private string? last_shown = null;

        /* ---------------------------------------------------------------- */
        /* Singularity.Plugin                                               */
        /* ---------------------------------------------------------------- */

        public void activate(Singularity.PluginContext context) {
            settings = new GLib.Settings(OWN_SCHEMA);
            desktop  = new GLib.Settings(DESKTOP_SCHEMA);

            /* Any change to enabled/interval restarts the timer. Changing the
             * folder or the shuffle mode does not, because those only matter
             * at the next tick. */
            settings.changed["enabled"].connect(reschedule);
            settings.changed["interval-minutes"].connect(reschedule);

            reschedule();
        }

        public void deactivate() {
            cancel_timer();
            settings = null;
            desktop = null;
            last_shown = null;
        }

        /* ---------------------------------------------------------------- */
        /* Scheduling                                                       */
        /* ---------------------------------------------------------------- */

        private void cancel_timer() {
            if (timer_id != 0) {
                Source.remove(timer_id);
                timer_id = 0;
            }
        }

        private void reschedule() {
            cancel_timer();
            if (settings == null || !settings.get_boolean("enabled")) return;

            uint minutes = settings.get_uint("interval-minutes");
            if (minutes < 1) minutes = 1;

            /* Seconds rather than minutes: timeout_add_seconds coalesces with
             * other timers, which matters on a battery-powered machine. The
             * first change happens after one full interval, not immediately —
             * changing the wallpaper the instant the shell starts looks like a
             * glitch rather than a feature. */
            timer_id = Timeout.add_seconds(minutes * 60, () => {
                advance();
                return Source.CONTINUE;
            });
        }

        /* ---------------------------------------------------------------- */
        /* Picking and applying                                             */
        /* ---------------------------------------------------------------- */

        /** Folder to draw from: the configured one, else the current wallpaper's. */
        private string? source_directory() {
            if (settings == null || desktop == null) return null;

            string configured = settings.get_string("directory");
            if (configured != "" && FileUtils.test(configured, FileTest.IS_DIR))
                return configured;

            string uri = desktop.get_string(DESKTOP_KEY);
            if (uri == "") return null;
            try {
                string path = Filename.from_uri(uri, null);
                return GLib.Path.get_dirname(path);
            } catch (ConvertError e) {
                /* Not a URI — some deployments store a bare path. */
                if (uri.has_prefix("/")) return GLib.Path.get_dirname(uri);
                return null;
            }
        }

        private static bool looks_like_image(string name) {
            string n = name.down();
            return n.has_suffix(".jpg")  || n.has_suffix(".jpeg")
                || n.has_suffix(".png")  || n.has_suffix(".webp")
                || n.has_suffix(".bmp");
        }

        /** Every usable image in the source folder, in filename order. */
        private Gee.ArrayList<string> candidates() {
            var found = new Gee.ArrayList<string>();
            string? dir = source_directory();
            if (dir == null) return found;

            try {
                Dir d = Dir.open(dir, 0);
                string? name;
                while ((name = d.read_name()) != null) {
                    if (!looks_like_image(name)) continue;
                    string full = GLib.Path.build_filename(dir, name);
                    /* Skip symlinks. A rotation folder commonly holds a
                     * "default" or "current" link pointing at one of the real
                     * images, and following it makes that image come up twice
                     * as often as the others. */
                    if (FileUtils.test(full, FileTest.IS_SYMLINK)) continue;
                    if (!FileUtils.test(full, FileTest.IS_REGULAR)) continue;
                    found.add(full);
                }
            } catch (FileError e) {
                return found;
            }
            found.sort((a, b) => strcmp(a, b));
            return found;
        }

        /** Change to the next wallpaper. Public so the settings widget can too. */
        public void advance() {
            if (desktop == null || settings == null) return;

            var pics = candidates();
            if (pics.size == 0) return;
            if (pics.size == 1) { apply(pics[0]); return; }

            string current = last_shown ?? current_path();
            /* Seeded rather than left unassigned: valac cannot prove the
             * do/while below assigns it on every path, and pics is known
             * non-empty here (the size 0 and size 1 cases returned above). */
            string chosen = pics[0];

            if (settings.get_boolean("shuffle")) {
                /* Avoid repeating the image already on screen. With n > 1 this
                 * terminates quickly; the loop is bounded regardless. */
                int attempts = 0;
                do {
                    chosen = pics[Random.int_range(0, pics.size)];
                } while (chosen == current && ++attempts < 8);
            } else {
                int idx = 0;
                for (int i = 0; i < pics.size; i++) {
                    if (pics[i] == current) { idx = (i + 1) % pics.size; break; }
                }
                chosen = pics[idx];
            }
            apply(chosen);
        }

        private string? current_path() {
            string uri = desktop.get_string(DESKTOP_KEY);
            if (uri == "") return null;
            try { return Filename.from_uri(uri, null); }
            catch (ConvertError e) { return uri.has_prefix("/") ? uri : null; }
        }

        private void apply(string path) {
            last_shown = path;
            desktop.set_string(DESKTOP_KEY, Filename.to_uri(path, null));
        }

        /* ---------------------------------------------------------------- */
        /* Settings UI                                                      */
        /* ---------------------------------------------------------------- */

        public Gtk.Widget? get_settings_widget() {
            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12) {
                margin_top = 12, margin_bottom = 12,
                margin_start = 12, margin_end = 12
            };

            var on = new Gtk.Switch() { valign = Gtk.Align.CENTER };
            settings.bind("enabled", on, "active", SettingsBindFlags.DEFAULT);
            box.append(row("Rotate wallpaper", on));

            var spin = new Gtk.SpinButton.with_range(1, 1440, 1) {
                valign = Gtk.Align.CENTER
            };
            settings.bind("interval-minutes", spin, "value", SettingsBindFlags.DEFAULT);
            box.append(row("Minutes between changes", spin));

            var shuffle = new Gtk.Switch() { valign = Gtk.Align.CENTER };
            settings.bind("shuffle", shuffle, "active", SettingsBindFlags.DEFAULT);
            box.append(row("Random order", shuffle));

            var folder = new Gtk.Entry() {
                hexpand = true,
                placeholder_text = "Folder of the current wallpaper"
            };
            settings.bind("directory", folder, "text", SettingsBindFlags.DEFAULT);
            box.append(row("Wallpaper folder", folder));

            var next = new Gtk.Button.with_label("Change now");
            next.clicked.connect(() => advance());
            next.halign = Gtk.Align.START;
            box.append(next);

            return box;
        }

        private static Gtk.Widget row(string label, Gtk.Widget control) {
            var h = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
            var l = new Gtk.Label(label) { xalign = 0, hexpand = true };
            h.append(l);
            h.append(control);
            return h;
        }
    }
}

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var obj = module as Peas.ObjectModule;
    obj.register_extension_type(typeof(Singularity.Plugin),
                                typeof(WallpaperRotator.Plugin));
}
