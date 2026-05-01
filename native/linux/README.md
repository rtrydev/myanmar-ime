# ibus-myangler — the Linux native shell

IBus engine binary + Preferences app + Debian packaging for the
Myangler Burmese IME. Implements the design from
[`tasks/linux-ibus-port.md`](../../tasks/linux-ibus-port.md).

## Layout

```
native/linux/
├── ibus-engine/      meson + C: ibus-engine-myangler binary
├── swift-shim/       libBurmeseIMEFFI.so (Swift wrapper around BurmeseIMECore)
├── preferences/      myangler_preferences/ — PyGObject + libadwaita GUI
├── data/             gschema XML, IBus component XML, .desktop, SVG icon
├── debian/           dpkg-buildpackage rules → ibus-myangler.deb
└── scripts/          build-swift-shim.sh, dev-install.sh, build-deb.sh
```

## Quick start (dev)

```bash
sudo apt install \
    libibus-1.0-dev libglib2.0-dev libsqlite3-dev \
    meson ninja-build pkg-config libjson-glib-dev \
    libgtk-4-dev libadwaita-1-dev gir1.2-adw-1 \
    python3-gi gir1.2-gtk-4.0
# plus Swift via swiftly: https://swift.org/install
./scripts/dev-install.sh
ibus restart
# Add "Myangler (Burmese, Romanized)" in
# Settings → Region & Language → Manage Installed Languages.
```

The dev-install drops everything into `~/.local`, sets the component
XML's `<exec>` to point at the staged binary, and compiles the schema
into `~/.local/share/glib-2.0/schemas/`. Re-run after every change.

## Build the .deb

```bash
sudo apt install debhelper devscripts dpkg-dev fakeroot \
                 libibus-1.0-dev libglib2.0-dev libsqlite3-dev \
                 libjson-glib-dev meson ninja-build pkg-config
# plus Swift via swiftly
./scripts/build-deb.sh
sudo apt install build/ibus-myangler_*.deb
ibus restart
```

The Swift shim is built with `-static-stdlib` so the resulting `.so`
carries its own runtime. End-user systems do **not** need
`swiftlang` / `swiftly` installed.

`data/staging/BurmeseLexicon.sqlite` and `data/staging/BurmeseLM.bin`
must be present on the build host for the .deb to ship the bundled
lexicon — generate them once with `corpus_builder` and symlink:

```bash
mkdir -p data/staging
ln -sf ../../macos/Data/BurmeseLexicon.sqlite data/staging/
ln -sf ../../macos/Data/BurmeseLM.bin           data/staging/
```

If they're missing the .deb still builds, but the engine falls back
to the parser-only path (correct, but no lexicon-ranked candidates).

## Engine binary modes

```bash
ibus-engine-myangler --xml                # IBus component descriptor
ibus-engine-myangler --diagnostics        # JSON: paths, sizes, version
ibus-engine-myangler --reverse-romanize "ကျား"
ibus-engine-myangler --ibus               # long-running IBus mode
```

## Preferences app

Launch via the desktop file or:

```bash
myangler-preferences         # installed
python3 -m myangler_preferences   # in-tree
```

Tabs: Setup · Preferences · History · Convert · Diagnostics. All toggles
bind to GSettings (`com.myangler.inputmethod.burmese`); changes
propagate to the running engine within ~1 second via `g_settings_changed`.

## Cleanup

```bash
sudo apt purge ibus-myangler           # removes binaries, schemas, icons
rm -rf ~/.local/share/myangler         # also drops typing history (if you want)
rm -rf ~/.config/dconf/user            # only if you want to wipe GSettings
```
