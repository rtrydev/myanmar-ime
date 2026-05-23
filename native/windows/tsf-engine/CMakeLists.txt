# BurmeseIMETIP — TSF text service for the Myangler Burmese IME.
#
# Builds an in-process COM DLL implementing ITfTextInputProcessorEx +
# ITfThreadMgrEventSink + ITfKeyEventSink. Loads BurmeseIMEFFI.dll
# (built by ../swift-shim) at TIP activation to obtain a burmese engine
# handle, runs each per-keystroke burmese_engine_update on a dedicated
# worker thread (mirrors the IBus engine's worker-thread dispatch), and
# marshals the JSON snapshot back to the TIP thread via a hidden
# message-only window.
#
# Build (from this directory, in a VS Developer PowerShell):
#   cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
#   cmake --build build
#
# Output:
#   build/BurmeseIMETIP.dll  — the TSF text service DLL
#
# This first deliverable wires the engine plumbing end-to-end: keystroke
# -> keymap -> async worker -> burmese_engine_update -> OutputDebugString.
# Composition (preedit), the candidate window, and settings layer in
# subsequent commits. The architecture and invariants the rest must
# preserve are documented in CLAUDE.md "Native Shells -> Windows".

cmake_minimum_required(VERSION 3.20)
project(BurmeseIMETIP LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT MSVC)
    message(FATAL_ERROR
        "BurmeseIMETIP must be built with MSVC (cl.exe). "
        "Run from a Visual Studio Developer PowerShell.")
endif()

# Default to dynamic CRT (/MD) so the TIP shares the C runtime with
# the host process. Static CRT (/MT) would make the DLL self-contained
# but every host process would load its own CRT copy, which COM hosts
# dislike. Match the BurmeseIMEFFI.dll convention.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")

add_compile_definitions(
    UNICODE
    _UNICODE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    # Target Windows 10+ so we get the modern TSF surface.
    _WIN32_WINNT=0x0A00
    WINVER=0x0A00
    # Silence the "min/max as a macro" warning in <Windows.h>.
    NOMINMAX
)

add_compile_options(
    /W4
    /permissive-
    /Zc:__cplusplus    # report the real __cplusplus value, not 199711L
    /utf-8
    /DNDEBUG
)

set(BurmeseIMETIP_SOURCES
    src/log_file.cpp
    src/guids.cpp
    src/ffi_loader.cpp
    src/keymap.cpp
    src/engine_worker.cpp
    src/key_event_sink.cpp
    src/composition.cpp
    src/snapshot.cpp
    src/candidate_window.cpp
    src/candidate_ui_element.cpp
    src/display_attribute.cpp
    src/settings.cpp
    src/compose_button.cpp
    src/text_service.cpp
    src/class_factory.cpp
    src/register.cpp
    src/dllmain.cpp
)

add_library(BurmeseIMETIP SHARED
    ${BurmeseIMETIP_SOURCES}
    BurmeseIMETIP.def
)

# Include path to the shared ffi.h. Both Linux and Windows shells use
# the same header so the C ABI cannot drift between platforms.
target_include_directories(BurmeseIMETIP PRIVATE
    src
    ${CMAKE_SOURCE_DIR}/../../linux/ibus-engine/src
)

target_link_libraries(BurmeseIMETIP PRIVATE
    # TSF interfaces are header-only at link time (msctf.h declares the
    # IIDs; we define their storage exactly once in guids.cpp via
    # InitGuid.h). The dll msctf.dll is loaded by the COM host, not us.
    # ole32 / oleaut32: COM core. advapi32: registry. user32: windows
    # + message loop. shell32: SHGetKnownFolderPath for the history
    # path under %LOCALAPPDATA%. d2d1 / dwrite: candidate window
    # rendering (Direct2D HwndRenderTarget + DirectWrite text layout
    # using the Myanmar Text font shipped with Windows 8+).
    ole32
    oleaut32
    advapi32
    user32
    shell32
    d2d1
    dwrite
    # DwmSetWindowAttribute for round corners + immersive dark mode
    # hints on the candidate popup. Linked indirectly via the
    # `#pragma comment(lib, "dwmapi.lib")` too, but listing here keeps
    # the dependency visible at CMake configure time.
    dwmapi
)

set_target_properties(BurmeseIMETIP PROPERTIES
    OUTPUT_NAME "BurmeseIMETIP"
    PREFIX ""
    SUFFIX ".dll"
)

# Helper exe: install / uninstall the TIP via the DLL's own
# DllRegisterServer / DllUnregisterServer. Friendlier than regsvr32,
# same code path. Built next to BurmeseIMETIP.dll so the exe can
# resolve the DLL by sibling path. Must be run elevated.
add_executable(register_profile
    tools/register_profile/main.cpp
)
set_target_properties(register_profile PROPERTIES
    OUTPUT_NAME "register_profile"
)
target_link_libraries(register_profile PRIVATE
    ole32       # CoInitializeEx / CoUninitialize
)
