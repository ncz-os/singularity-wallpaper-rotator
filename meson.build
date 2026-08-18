# Wallpaper Rotator — a Singularity plugin.
#
# Builds a libpeas-2 module. Singularity's PluginManager searches, among other
# places, <prefix>/<libdir>/singularity/plugins, so installing there is enough
# for the shell to find it; no registration step is needed. For development,
# point SINGULARITY_PLUGIN_PATH at the build directory instead of installing.
project('singularity-wallpaper-rotator', ['vala', 'c'],
  version: '1.0',
  license: 'GPL-3.0-or-later',
  meson_version: '>= 0.60',
  default_options: ['warning_level=2'],
)

gnome = import('gnome')

deps = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
  dependency('gio-2.0'),
  dependency('gtk4'),
  dependency('gee-0.8'),
  dependency('libpeas-2'),
  # Provides the Singularity.Plugin interface and PluginContext.
  dependency('singularity-1.0'),
]

plugin_dir = get_option('prefix') / get_option('libdir') / 'singularity' / 'plugins'

shared_module('wallpaper-rotator',
  'src/rotator.vala',
  dependencies: deps,
  install: true,
  install_dir: plugin_dir,
  # libpeas loads the module by name; no versioned soname wanted.
  name_prefix: 'lib',
)

# The .plugin metadata must sit beside the module for libpeas to find it.
install_data('src/wallpaper-rotator.plugin', install_dir: plugin_dir)

install_data('data/dev.sinty.plugin.wallpaper-rotator.gschema.xml',
  install_dir: get_option('prefix') / get_option('datadir') / 'glib-2.0' / 'schemas',
)

gnome.post_install(glib_compile_schemas: true)
