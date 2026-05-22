// File-based diagnostic log for the BurmeseIME TIP.
//
// Why a file logger when OutputDebugString already exists: OutputDebug
// only surfaces under a live attached debugger (DbgView, WinDbg). For
// silent-failure investigation on end-user machines, a persistent
// file is far more useful — the user can paste it without needing
// to install or configure anything. TSF in particular almost never
// logs TIP-load failures to the Windows Event Log, so without an
// in-TIP logger we are blind when something goes wrong before
// the candidate window can render.
//
// Output: %LOCALAPPDATA%\Myangler\tip.log
//
// Thread-safe. Log calls from any thread; entries serialize through
// an SRWLOCK. Each entry is one line ending in "\r\n" (the user is
// likely to open this in Notepad). Format:
//
//   [2026-05-23 01:42:11.123 P12345 T67890] message
//
// Logging never throws and never blocks for long — file write
// failures are silently swallowed (the worst case is "we tried to
// log and couldn't"; that should never crash the user's text input).

#pragma once

#include <Windows.h>

namespace burmese {

// Write a formatted line to %LOCALAPPDATA%\Myangler\tip.log. printf-
// style format using wchar_t. Safe to call from any thread.
void log_line(const wchar_t* fmt, ...) noexcept;

// Convenience: log + OutputDebugString for the same message so
// dev-time debugger users still see it inline.
void log_dbg(const wchar_t* fmt, ...) noexcept;

} // namespace burmese
