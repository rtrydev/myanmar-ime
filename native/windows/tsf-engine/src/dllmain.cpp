// DLL entry points for BurmeseIMETIP.
//
// Exposes the four functions COM needs from an in-proc server DLL —
// DllGetClassObject, DllCanUnloadNow, DllRegisterServer,
// DllUnregisterServer — plus DllMain to stash the HMODULE so the
// loader and registration helpers can resolve sibling paths.

#include <Windows.h>

#include "class_factory.h"
#include "guids.h"
#include "log_file.h"

namespace burmese {

HMODULE g_module = nullptr;

// Bumped by every live TextService instance and every IClassFactory
// LockServer(TRUE). When it returns to zero, COM may unload us.
long g_dll_ref_count = 0;

HRESULT register_inproc_server() noexcept;
HRESULT unregister_inproc_server() noexcept;
HRESULT register_profile_and_category() noexcept;
HRESULT unregister_profile_and_category() noexcept;
HRESULT set_user_default_profile() noexcept;

} // namespace burmese

extern "C" BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    switch (reason) {
    case DLL_PROCESS_ATTACH:
        burmese::g_module = module;
        DisableThreadLibraryCalls(module);  // we don't care about per-thread notifications

        // Augment the per-process DLL search path so subsequent
        // LoadLibraryEx calls find this DLL's siblings — without
        // this, BurmeseIMEFFI.dll (which has static imports on
        // Foundation.dll, swiftCore.dll, ...) cannot resolve its
        // own deps when we load it dynamically, because the
        // standard search path doesn't include the TIP's
        // %ProgramFiles%\Myangler\ directory.
        //
        // SetDefaultDllDirectories restricts implicit searches to
        // the safer set (System32 + user-added dirs). AddDllDirectory
        // adds our install directory to that set, so any
        // LoadLibraryExW that passes LOAD_LIBRARY_SEARCH_USER_DIRS
        // (or LOAD_LIBRARY_SEARCH_DEFAULT_DIRS, which includes
        // USER_DIRS) finds DLLs in our dir.
        {
            wchar_t buf[MAX_PATH] = {0};
            DWORD n = GetModuleFileNameW(module, buf, MAX_PATH);
            if (n > 0 && n < MAX_PATH) {
                burmese::log_line(L"DLL_PROCESS_ATTACH module=%s pid=%u", buf, GetCurrentProcessId());
                wchar_t* slash = wcsrchr(buf, L'\\');
                if (slash) {
                    *slash = L'\0';
                    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
                    if (!AddDllDirectory(buf)) {
                        burmese::log_line(L"  AddDllDirectory(%s) failed gle=%u",
                                          buf, GetLastError());
                    }
                }
            } else {
                burmese::log_line(L"DLL_PROCESS_ATTACH GetModuleFileNameW failed gle=%u",
                                  GetLastError());
            }
        }
        break;
    case DLL_PROCESS_DETACH:
        // Don't try to clean up here. By the time DLL_PROCESS_DETACH
        // fires, the host is tearing down and many subsystems
        // (notably COM) are gone. Any live TextService should have
        // been Deactivate()'d by TSF earlier in the shutdown flow.
        break;
    default: break;
    }
    return TRUE;
}

extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID clsid, REFIID iid, void** ppv) {
    burmese::log_line(L"DllGetClassObject pid=%u", GetCurrentProcessId());
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (clsid != burmese::CLSID_TextService) {
        burmese::log_line(L"  CLSID mismatch");
        return CLASS_E_CLASSNOTAVAILABLE;
    }

    auto* factory = new (std::nothrow) burmese::TextServiceFactory();
    if (!factory) return E_OUTOFMEMORY;

    const HRESULT hr = factory->QueryInterface(iid, ppv);
    factory->Release();
    burmese::log_line(L"  QueryInterface hr=0x%08X", static_cast<unsigned>(hr));
    return hr;
}

extern "C" HRESULT __stdcall DllCanUnloadNow() {
    return (burmese::g_dll_ref_count == 0) ? S_OK : S_FALSE;
}

extern "C" HRESULT __stdcall DllRegisterServer() {
    burmese::log_line(L"DllRegisterServer pid=%u", GetCurrentProcessId());
    HRESULT hr = burmese::register_inproc_server();
    if (FAILED(hr)) {
        burmese::log_line(L"  register_inproc_server failed 0x%08X", static_cast<unsigned>(hr));
        return hr;
    }
    hr = burmese::register_profile_and_category();
    if (FAILED(hr)) {
        burmese::log_line(L"  register_profile_and_category failed 0x%08X — rolling back inproc",
                          static_cast<unsigned>(hr));
        burmese::unregister_inproc_server();
        return hr;
    }
    burmese::log_line(L"  ok");
    return S_OK;
}

extern "C" HRESULT __stdcall DllUnregisterServer() {
    burmese::log_line(L"DllUnregisterServer pid=%u", GetCurrentProcessId());
    burmese::unregister_profile_and_category();
    return burmese::unregister_inproc_server();
}

// Set the current user's preferred IM for the Burmese language to
// Myangler. Writes to HKCU only — must be invoked in the user's
// context, not from a deferred MSI custom action running as SYSTEM
// (which has its own useless HKCU profile). The MSI achieves this
// by scheduling a second `register_profile.exe set-default` action
// with Impersonate="yes".
extern "C" HRESULT __stdcall DllSetUserDefaultProfile() {
    burmese::log_line(L"DllSetUserDefaultProfile pid=%u", GetCurrentProcessId());
    return burmese::set_user_default_profile();
}
