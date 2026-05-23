# myangler-windows — the Windows native shell

TSF text service DLL, Swift FFI shim, WPF Preferences app, and WiX
MSI installer for the Myangler Burmese IME. Mirrors the macOS IMK
and Linux IBus shells; everything routes through the same
`BurmeseIMECore` Swift package and the C ABI declared in
[`native/linux/ibus-engine/src/ffi.h`](../linux/ibus-engine/src/ffi.h).

## Layout

```
native/windows/
├── swift-shim/      BurmeseIMEFFI.dll — Swift @_cdecl wrapper around BurmeseIMECore
├── tsf-engine/      BurmeseIMETIP.dll — TSF text service (CMake + MSVC C++)
│                    + register_profile.exe helper
├── preferences/     BurmeseIMEPreferences.exe — WPF + .NET 9 settings GUI
└── installer/       Myangler-Burmese-IME.msi — WiX build, packages everything above
```

Architecture, invariants, settings schema, frozen CLSIDs: see
[`CLAUDE.md`](../../CLAUDE.md)'s "Native Shells → Windows" section.

## Quick start (dev)

Run from a **Visual Studio Developer PowerShell** so `cl.exe`,
`link.exe`, and the Windows SDK are on `PATH` / `INCLUDE` / `LIB`.

One-time prerequisites:

```powershell
# 1. SQLite via vcpkg (manifest install reads ..\..\vcpkg.json).
#    Use either the VS-bundled vcpkg or your own clone.
cd ..\..   # repo root
& "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\vcpkg\vcpkg.exe" `
    install --triplet x64-windows
# Writes ..\..\vcpkg_installed\x64-windows\ (gitignored).

# 2. WiX 7 as a .NET global tool, EULA accepted.
dotnet tool install --global wix
wix eula accept wix7

# 3. Swift 6.3+ from https://www.swift.org/install/windows/
#    (puts the runtime DLLs at %LOCALAPPDATA%\Programs\Swift\Runtimes\).
```

Build the whole MSI:

```powershell
cd native\windows\installer
.\build.ps1
# -> build\Myangler-Burmese-IME.msi  (~91 MB)
```

Install on this machine (elevated):

```powershell
msiexec /i .\build\Myangler-Burmese-IME.msi
# Then in Windows Settings:
#   Time & language -> Language -> Burmese -> Options -> Keyboards ->
#   "Myangler Burmese" should be in the list. Switch to it via
#   Win+Space and type "minga" in Notepad.
# The Preferences app lands at:
#   Start Menu -> Myangler -> Myangler Burmese Preferences
```

Uninstall via Settings → Apps → "Myangler Burmese IME" (or
`msiexec /x` on the MSI path). User history at
`%LOCALAPPDATA%\Myangler\UserHistory.sqlite` (or
`%LOCALAPPDATA%\Packages\<AppContainer>\AC\Myangler\
UserHistory.sqlite` for sandboxed hosts like `SearchHost.exe`,
where the system redirects the write) survives uninstall by
design — matches the Linux `apt purge` contract.

## Dev iteration without rebuilding the MSI

Per-piece dev loops, faster than the full installer:

```powershell
# Just the core engine + tests
cd Packages\BurmeseIMECore
swift build
swift run TestRunner

# Just the Swift shim
cd native\windows\swift-shim
swift build -c release --product BurmeseIMEFFI

# Just the TSF DLL + register helper
cd native\windows\tsf-engine
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build

# Register the freshly-built TIP DLL into HKLM (elevated):
cd build
.\register_profile.exe install
# ...test in Notepad...
.\register_profile.exe uninstall
```

The TIP DLL discovers `BurmeseIMEFFI.dll` via the env var
`MYANGLER_FFI_DLL` first (absolute path), then a sibling file. So
you can point the installed TIP at a freshly-built shim without
re-running the MSI:

```powershell
$env:MYANGLER_FFI_DLL = "C:\Users\rtry\repos\myanmar-ime\native\windows\swift-shim\.build\x86_64-unknown-windows-msvc\release\BurmeseIMEFFI.dll"
# Restart any application currently using the TIP (e.g. close + reopen Notepad).
```

## Where to look when something breaks

| Symptom | First place to check |
|---|---|
| TIP doesn't appear in Settings → Language → Keyboards | `register_profile.exe install` was not elevated, or `DllRegisterServer` returned a failure (see `src/register.cpp`) |
| Win+Space picks "Burmese (Phonetic)" not Myangler on first try | The per-user default-IM call failed — check `tip.log` for `SetDefaultLayoutOrTip ok=1`. If `ok=0`, the `input.dll` modern-default path failed; the legacy `SetDefaultLanguageProfile` returns `E_FAIL` on Win11 by design |
| TIP loads but typing doesn't produce candidates | `BurmeseIMEFFI.dll` resolution failed — DbgView for `[BurmeseIMETIP] FFI load failed:` |
| Composition shows but commit doesn't insert text | `commitComposition runEditSession hr=` in `tip.log`; host may have refused the synchronous edit session, see `edit_session.h` for the async fallback |
| Notepad / Firefox process pinned at 100% CPU after window close | Should not recur — `FfiLibrary::unload()` no longer `FreeLibrary`s the Swift FFI shim. If it does, check the `unload()` comment in `src/ffi_loader.cpp` |
| Host install left bad state from a prior version | `DllRegisterServer` self-heals via scrub-first. If categories look wrong, run `register_profile.exe uninstall` then `install` from an elevated shell |
| Candidate panel doesn't appear in Win11 Start Menu / Search Bar | Expected — Win11 hardcodes shell-rendered candidate UI to East-Asian LANGIDs and Burmese isn't whitelisted; full bisection in 0.1.19–0.1.24 ruled out category-based workarounds. The fallback is the inline-preedit override: latin by default, Nav keys (Up/Down/PageUp/PageDown/Tab) cycle and reveal the Burmese surface inline |
| Tip.log empty for SearchHost / UWP host | AppContainer redirect — look under `%LOCALAPPDATA%\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\AC\Myangler\tip.log` (or attach DbgView to capture `[BurmeseIMETIP] *` lines) |
| Candidate window appears but text doesn't | Composition path / display-attribute provider mismatch — DbgView for `[BurmeseIMETIP composition]` |
| Engine seems to lag user typing | EngineWorker coalescing / stale-buffer guard — read `src/engine_worker.cpp` |
| Settings don't take effect | RegNotifyChangeKeyValue watcher silently dropped — restart the TIP host (close + reopen Notepad) |
