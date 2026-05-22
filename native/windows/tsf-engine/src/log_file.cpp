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

const std::wstring& log_path() noexcept {
    AcquireSRWLockExclusive(&g_log_lock);
    if (!g_log_path_resolved) {
        PWSTR localAppData = nullptr;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &localAppData))
            && localAppData) {
            g_log_path = localAppData;
            g_log_path += L"\\Myangler";
            CreateDirectoryW(g_log_path.c_str(), nullptr);   // ignore errors
            g_log_path += L"\\tip.log";
            CoTaskMemFree(localAppData);
        }
        g_log_path_resolved = true;
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
}

} // namespace

void log_line(const wchar_t* fmt, ...) noexcept {
    va_list args;
    va_start(args, fmt);
    format_and_write(fmt, args);
    va_end(args);
}

void log_dbg(const wchar_t* fmt, ...) noexcept {
    // Format twice — once to the file, once to the debugger stream.
    // Acceptable cost; only called during interesting events.
    va_list args;
    va_start(args, fmt);
    format_and_write(fmt, args);
    va_end(args);

    wchar_t buf[4096];
    va_start(args, fmt);
    std::vswprintf(buf, std::size(buf), fmt, args);
    va_end(args);
    OutputDebugStringW(L"[BurmeseIMETIP] ");
    OutputDebugStringW(buf);
    OutputDebugStringW(L"\n");
}

} // namespace burmese
