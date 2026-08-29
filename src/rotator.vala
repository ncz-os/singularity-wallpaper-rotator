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
using Adw;

namespace WallpaperRotator {

    private const string DESKTOP_SCHEMA = "dev.sinty.desktop";
    private const string DESKTOP_KEY    = "background-picture-uri";
    private const string OWN_SCHEMA     = "dev.sinty.plugin.wallpaper-rotator";
    private const string EMPTY_HINT     = "Folder of the current wallpaper";

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
            var group = new Adw.PreferencesGroup() {
                margin_top    = 12,
                margin_bottom = 12,
                margin_start  = 12,
                margin_end    = 12
            };

            /* ---- Rotate on/off ---- */
            var on_row = new Adw.SwitchRow() {
                title = "Rotate wallpaper"
            };
            settings.bind("enabled", on_row, "active",
                          GLib.SettingsBindFlags.DEFAULT);
            group.add(on_row);

            /* ---- Interval ---- */
            var interval_row = new Adw.SpinRow.with_range(1, 1440, 1) {
                title = "Minutes between changes"
            };
            settings.bind("interval-minutes", interval_row, "value",
                          GLib.SettingsBindFlags.DEFAULT);
            group.add(interval_row);

            /* ---- Shuffle ---- */
            var shuffle_row = new Adw.SwitchRow() {
                title = "Random order"
            };
            settings.bind("shuffle", shuffle_row, "active",
                          GLib.SettingsBindFlags.DEFAULT);
            group.add(shuffle_row);

            /* ---- Folder chooser ---- */
            var folder_row = new Adw.ActionRow() {
                title = "Wallpaper folder"
            };
            string current_dir = settings.get_string("directory");
            folder_row.subtitle = (current_dir != "") ? current_dir : EMPTY_HINT;

            var choose_btn = new Gtk.Button.with_label("Choose…") {
                valign = Gtk.Align.CENTER
            };
            choose_btn.clicked.connect(() => {
                var dialog = new Gtk.FileDialog() {
                    title = "Select wallpaper folder"
                };
                /* Seed the chooser at the current selection when we have one
                 * so a follow-up "Choose…" lands in the same place. */
                string seed = settings.get_string("directory");
                if (seed == "") {
                    string? here = source_directory();
                    if (here != null) seed = here;
                }
                if (seed != "") {
                    try {
                        dialog.set_initial_folder(GLib.File.new_for_path(seed));
                    } catch (GLib.Error e) { /* non-fatal */ }
                }
                dialog.select_folder.begin(
                    (Gtk.Window?) folder_row.get_root(),
                    null,
                    (obj, res) => {
                        GLib.File? folder = null;
                        try {
                            folder = dialog.select_folder.end(res);
                        } catch (GLib.Error e) {
                            /* User cancelled or GIO errored — leave as is. */
                            return;
                        }
                        if (folder == null) return;
                        string? path = folder.get_path();
                        if (path == null) return;
                        /* Direct write rather than a one-way bind: the row's
                         * subtitle is driven from the key, so updating the
                         * key is what makes the new path visible. */
                        settings.set_string("directory", path);
                    }
                );
            });
            folder_row.add_suffix(choose_btn);
            folder_row.activatable_widget = choose_btn;
            group.add(folder_row);

            /* ---- Live status ---- */
            var status = new Gtk.Label(null) {
                xalign       = 0,
                margin_top   = 6,
                margin_start = 12,
                margin_end   = 12,
                wrap         = true,
                /* Dim secondary text so it doesn't compete with the rows. */
                css_classes  = { "dim-label", "caption" }
            };
            refresh_status(status);

            /* Mirror the old Gtk.Entry's two-way refresh: any change to the
             * "directory" key — chooser or external — updates both the
             * subtitle and the status line. */
            settings.changed["directory"].connect(() => {
                string d = settings.get_string("directory");
                folder_row.subtitle = (d != "") ? d : EMPTY_HINT;
                refresh_status(status);
            });

            /* Wrap the group + status in a single box so the shell sees one
             * drop-in Gtk.Widget. */
            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            outer.append(group);
            outer.append(status);

            /* ---- Change now ---- */
            var next = new Gtk.Button.with_label("Change now") {
                halign       = Gtk.Align.START,
                margin_start = 12,
                margin_end   = 12,
                margin_top   = 6,
                margin_bottom = 12
            };
            next.clicked.connect(() => {
                advance();
                refresh_status(status);
            });
            outer.append(next);

            return outer;
        }

        /** Refresh the "N images · current: foo.jpg" status line. Reuses
         * the real scan path so the count and the filename can never
         * disagree with what rotation would actually pick. */
        private void refresh_status(Gtk.Label label) {
            var pics = candidates();
            int n = pics.size;

            string now = current_path() ?? last_shown ?? "";
            /* English-only copy; this plugin is loaded by the shell which
             * does not set a text domain for extension widgets. */
            string count_text = (n == 1)
                ? "1 image in folder"
                : "%d images in folder".printf(n);
            if (now == "") {
                label.label = "%s · no wallpaper set".printf(count_text);
                return;
            }

            /* current_path() returns a local path. Show just the basename
             * so the line stays readable when the path is long. */
            string basename = now;
            int slash = now.last_index_of("/");
            if (slash >= 0 && slash + 1 < now.length)
                basename = now.substring(slash + 1);

            label.label = "%s · current: %s".printf(count_text, basename);
        }
    }
}

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var obj = module as Peas.ObjectModule;
    obj.register_extension_type(typeof(Singularity.Plugin),
                                typeof(WallpaperRotator.Plugin));
}
