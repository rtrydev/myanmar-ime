// register_profile.exe — install / uninstall the BurmeseIME TIP.
//
// Tiny convenience wrapper around regsvr32: locates
// BurmeseIMETIP.dll alongside this exe, LoadLibraryW's it,
// initialises COM as STA, then calls the DLL's DllRegisterServer
// (or DllUnregisterServer). Same code path, same result — but
// "register_profile install" is friendlier than asking devs to
// remember regsvr32 syntax and which directory to cd into.
//
// Must be run from an elevated shell — both passes touch HKLM and
// will silently fail under standard user rights. The exe deliberately
// does not bundle an elevation manifest; that's the call of the MSI
// installer (which is the production deployment path).
//
// Usage:
//   register_profile install     -> DllRegisterServer
//   register_profile uninstall   -> DllUnregisterServer
//
// Exit codes:
//   0  success
//   1  argument error / dll load / no entry point
//   2  DllRegisterServer / DllUnregisterServer returned a failure HRESULT

#include <Windows.h>
#include <Objbase.h>

#include <cstdio>
#include <cwchar>
#include <string>

namespace {

using DllEntry = HRESULT (__stdcall *)();

std::wstring exe_directory() {
    wchar_t buf[MAX_PATH] = {0};
    DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return {};
    std::wstring s(buf, n);
    auto slash = s.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return {};
    return s.substr(0, slash + 1);
}

void usage() {
    std::fwprintf(stderr,
        L"usage: register_profile install|uninstall\n"
        L"\n"
        L"Loads BurmeseIMETIP.dll from the same directory as this exe\n"
        L"and calls its DllRegisterServer or DllUnregisterServer entry\n"
        L"point. Requires an elevated shell (writes HKLM).\n");
}

} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) { usage(); return 1; }

    const wchar_t* verb = argv[1];
    const bool install   = (std::wcscmp(verb, L"install")   == 0);
    const bool uninstall = (std::wcscmp(verb, L"uninstall") == 0);
    if (!install && !uninstall) { usage(); return 1; }

    const std::wstring dir = exe_directory();
    if (dir.empty()) {
        std::fwprintf(stderr, L"error: cannot resolve exe directory\n");
        return 1;
    }
    const std::wstring dllPath = dir + L"BurmeseIMETIP.dll";

    HMODULE dll = LoadLibraryW(dllPath.c_str());
    if (!dll) {
        const DWORD gle = GetLastError();
        std::fwprintf(stderr,
            L"error: LoadLibraryW(%s) failed (GetLastError=%u)\n",
            dllPath.c_str(), gle);
        return 1;
    }

    const char* fnName = install ? "DllRegisterServer" : "DllUnregisterServer";
    auto fn = reinterpret_cast<DllEntry>(GetProcAddress(dll, fnName));
    if (!fn) {
        std::fwprintf(stderr,
            L"error: GetProcAddress(%hs) returned null\n", fnName);
        FreeLibrary(dll);
        return 1;
    }

    // COM must be live before DllRegisterServer runs — its profile /
    // category register path CoCreates ITfInputProcessorProfileMgr
    // and ITfCategoryMgr, both of which need an apartment. STA is
    // what TSF expects (same as regsvr32 uses).
    const HRESULT hrCom = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(hrCom)) {
        std::fwprintf(stderr,
            L"error: CoInitializeEx failed: 0x%08lX\n",
            static_cast<unsigned long>(hrCom));
        FreeLibrary(dll);
        return 1;
    }

    const HRESULT hr = fn();
    if (SUCCEEDED(hr)) {
        std::fwprintf(stdout,
            L"%hs ok (HRESULT=0x%08lX)\n",
            fnName, static_cast<unsigned long>(hr));
    } else {
        std::fwprintf(stderr,
            L"%hs failed (HRESULT=0x%08lX)\n",
            fnName, static_cast<unsigned long>(hr));
    }

    CoUninitialize();
    FreeLibrary(dll);
    return SUCCEEDED(hr) ? 0 : 2;
}
