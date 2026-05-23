#include "log_file.h"

#include <ShlObj.h>

#include <cstdarg>
#include <cstdio>
#include <cwchar>
#include <string>

namespace burmese {

namespace {

SRWLOCK g_log_lock = SRWLOCK_INIT;
std::wstring g_log_path;
bool g_log_path_resolved = false;

// Try a candidate directory: create the dir, build the full log path,
// attempt to open the file for append. On success, store the path in
// `outPath` and return true. The probe write is what tells us the
// process has permission — file existence alone isn't enough because
// CreateDirectoryW returns 0 with ERROR_ALREADY_EXISTS without ever
// touching ACLs.
bool try_candidate(REFKNOWNFOLDERID folderId,
                   const wchar_t* subFile,
                   std::wstring& outPath) noexcept {
    PWSTR raw = nullptr;
    if (FAILED(SHGetKnownFolderPath(folderId, 0, nullptr, &raw)) || !raw) {
        return false;
    }
    std::wstring dir(raw);
    CoTaskMemFree(raw);
    dir += L"\\Myangler";
    CreateDirectoryW(dir.c_str(), nullptr);

    std::wstring file = dir + L"\\" + subFile;
    HANDLE h = CreateFileW(
        file.c_str(),
        FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    CloseHandle(h);
    outPath = std::move(file);
    return true;
}

// Resolve once. Multiple host-process integrity levels need different
// homes for tip.log:
//
//   * Classic / medium-integrity host (Notepad, Office, browsers):
//     %LOCALAPPDATA%\Myangler\tip.log — the documented default.
//
//   * AppContainer / Low-Integrity host (Win11 Start Menu's
//     SearchHost.exe, UWP apps, sandboxed Office): the normal
//     LocalAppData is access-denied to file writes. LocalAppDataLow
//     (C:\Users\<u>\AppData\LocalLow\) is the documented escape hatch
//     for low-integrity write access.
//
//   * Hardened sandboxes that block both: GetTempPath returns a
//     directory the process can always write to (per-AppContainer
//     redirected on Win10+, but always writable).
//
// We try each in order and remember the first one that accepts a
// real CreateFileW probe. The discovered path is logged at the top
// of the first message written via OutputDebugString too, so a
// debugger user can find a sandbox-redirected log without spelunking.
const std::wstring& log_path() noexcept {
    AcquireSRWLockExclusive(&g_log_lock);
    if (!g_log_path_resolved) {
        std::wstring chosen;
        if (try_candidate(FOLDERID_LocalAppData,    L"tip.log", chosen)
         || try_candidate(FOLDERID_LocalAppDataLow, L"tip.log", chosen)) {
            g_log_path = std::move(chosen);
        } else {
            wchar_t tmp[MAX_PATH] = {0};
            DWORD n = GetTempPathW(MAX_PATH, tmp);
            if (n > 0 && n < MAX_PATH) {
                g_log_path = std::wstring(tmp) + L"myangler-tip.log";
            }
        }
        g_log_path_resolved = true;

        // Echo the chosen path to the debugger stream once so a DbgView
        // user can locate the actual on-disk log when sandboxing
        // redirected it to LocalAppDataLow or %TEMP%.
        if (!g_log_path.empty()) {
            OutputDebugStringW(L"[BurmeseIMETIP] log file: ");
            OutputDebugStringW(g_log_path.c_str());
            OutputDebugStringW(L"\n");
        } else {
            OutputDebugStringW(L"[BurmeseIMETIP] log path resolution failed — file logging disabled\n");
        }
    }
    ReleaseSRWLockExclusive(&g_log_lock);
    return g_log_path;
}

void write_line(const wchar_t* line, size_t len) noexcept {
    const auto& path = log_path();
    if (path.empty()) return;

    AcquireSRWLockExclusive(&g_log_lock);
    HANDLE h = CreateFileW(
        path.c_str(),
        FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        ReleaseSRWLockExclusive(&g_log_lock);
        return;
    }

    // Write UTF-16 LE BOM on first create so Notepad opens it
    // correctly. Cheap to retry on every call — GetFileSize is fast.
    LARGE_INTEGER size{};
    GetFileSizeEx(h, &size);
    if (size.QuadPart == 0) {
        const unsigned char bom[2] = { 0xFF, 0xFE };
        DWORD wrote = 0;
        WriteFile(h, bom, 2, &wrote, nullptr);
    }

    DWORD wrote = 0;
    WriteFile(h, line, static_cast<DWORD>(len * sizeof(wchar_t)), &wrote, nullptr);
    CloseHandle(h);
    ReleaseSRWLockExclusive(&g_log_lock);
}

// Format `fmt` + args into a stack buffer with the standard prefix
// (timestamp + PID + TID) and write to the log. Truncates at 4 KB
// per entry — diagnostic messages should never be longer.
void format_and_write(const wchar_t* fmt, va_list args) noexcept {
    wchar_t buf[4096];

    SYSTEMTIME st;
    GetLocalTime(&st);
    int prefix_len = std::swprintf(
        buf, std::size(buf),
        L"[%04u-%02u-%02u %02u:%02u:%02u.%03u P%u T%u] ",
        st.wYear, st.wMonth, st.wDay,
        st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
        static_cast<unsigned>(GetCurrentProcessId()),
        static_cast<unsigned>(GetCurrentThreadId()));
    if (prefix_len < 0) prefix_len = 0;

    int body_len = std::vswprintf(
        buf + prefix_len,
        std::size(buf) - static_cast<size_t>(prefix_len) - 2,   // leave room for CRLF
        fmt, args);
    if (body_len < 0) body_len = 0;

    size_t total = static_cast<size_t>(prefix_len + body_len);
    if (total + 2 >= std::size(buf)) total = std::size(buf) - 3;
    buf[total]     = L'\r';
    buf[total + 1] = L'\n';
    buf[total + 2] = L'\0';

    write_line(buf, total + 2);

    // Mirror every line to the debugger stream too. DbgView (and
    // any attached debugger) captures these regardless of file-
    // system sandboxing, so diagnostics keep flowing even from
    // Low-Integrity / AppContainer hosts where the file write may
    // be redirected or denied entirely.
    OutputDebugStringW(L"[BurmeseIMETIP] ");
    OutputDebugStringW(buf);
}

} // namespace

void log_line(const wchar_t* fmt, ...) noexcept {
    va_list args;
    va_start(args, fmt);
    format_and_write(fmt, args);
    va_end(args);
}

void log_dbg(const wchar_t* fmt, ...) noexcept {
    // Equivalent to log_line now that log_line always mirrors to
    // OutputDebugString. Kept as a separate entry point because the
    // call-site name still tells future readers "this event is
    // worth a live debugger noticing", and we may want to escalate
    // it later (e.g. add ETW emit) without touching every caller.
    va_list args;
    va_start(args, fmt);
    format_and_write(fmt, args);
    va_end(args);
}

} // namespace burmese
