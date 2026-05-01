project('ibus-myangler', 'c',
  version : '0.1.0',
  default_options : [
    'c_std=c11',
    'warning_level=2',
    'b_lundef=true',
  ],
)

cc = meson.get_compiler('c')

ibus_dep      = dependency('ibus-1.0',     version : '>=1.5')
glib_dep      = dependency('glib-2.0',     version : '>=2.66')
gio_dep       = dependency('gio-2.0',      version : '>=2.66')
json_glib_dep = dependency('json-glib-1.0', version : '>=1.4')

# The Swift shim path is resolved at link time; for system installs the
# .so lives at /usr/lib/ibus-myangler/. During development, set
# MYANGLER_SHIM_DIR to the .build/staging output of build-swift-shim.sh
# (used by scripts/dev-install.sh which sets LD_LIBRARY_PATH).
shim_dir = get_option('shim_dir')
shim_link_args = []
shim_rpath = ''
if shim_dir != ''
  shim_link_args += ['-L' + shim_dir]
  shim_rpath = shim_dir
endif

ibus_engine_myangler = executable(
  'ibus-engine-myangler',
  sources : [
    'src/main.c',
    'src/engine.c',
    'src/keymap.c',
    'src/settings.c',
  ],
  dependencies : [ibus_dep, glib_dep, gio_dep, json_glib_dep],
  link_args : shim_link_args + ['-lBurmeseIMEFFI'],
  build_rpath : shim_rpath,
  install_rpath : '/usr/lib/ibus-myangler',
  install : true,
  # Debian convention is /usr/lib/<package>/ for engine helpers, and
  # the IBus component XML's <exec> already points there. Hardcode
  # `lib/ibus-myangler` under prefix instead of using libdir (which
  # is multiarch-suffixed on Debian) or libexecdir (which Debian
  # discourages for plain helpers).
  install_dir : get_option('prefix') / 'lib' / 'ibus-myangler',
)

# --- Tests ---------------------------------------------------------- #

# keymap_tests is a self-contained unit test for the IBus-keysym → action
# mapping. It links against ibus only (no Swift shim), so it runs in CI
# without the .so present.
keymap_test = executable(
  'keymap_tests',
  sources : ['src/keymap.c', 'tests/keymap_tests.c'],
  dependencies : [ibus_dep, glib_dep],
  build_by_default : false,
)
test('keymap', keymap_test)
