// DLL entry points for BurmeseIMETIP.
//
// Exposes the four functions COM needs from an in-proc server DLL —
// DllGetClassObject, DllCanUnloadNow, DllRegisterServer,
// DllUnregisterServer — plus DllMain to stash the HMODULE so the
// loader and registration helpers can resolve sibling paths.

#include <Windows.h>

#include "class_factory.h"
#include "guids.h"

namespace burmese {

HMODULE g_module = nullptr;

// Bumped by every live TextService instance and every IClassFactory
// LockServer(TRUE). When it returns to zero, COM may unload us.
long g_dll_ref_count = 0;

HRESULT register_inproc_server() noexcept;
HRESULT unregister_inproc_server() noexcept;
HRESULT register_profile_and_category() noexcept;
HRESULT unregister_profile_and_category() noexcept;

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
                wchar_t* slash = wcsrchr(buf, L'\\');
                if (slash) {
                    *slash = L'\0';
                    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
                    AddDllDirectory(buf);
                }
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
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (clsid != burmese::CLSID_TextService) return CLASS_E_CLASSNOTAVAILABLE;

    auto* factory = new (std::nothrow) burmese::TextServiceFactory();
    if (!factory) return E_OUTOFMEMORY;

    const HRESULT hr = factory->QueryInterface(iid, ppv);
    factory->Release();
    return hr;
}

extern "C" HRESULT __stdcall DllCanUnloadNow() {
    return (burmese::g_dll_ref_count == 0) ? S_OK : S_FALSE;
}

extern "C" HRESULT __stdcall DllRegisterServer() {
    // Order matters: COM in-proc must succeed before the TSF profile
    // calls below — RegisterProfile / RegisterCategory CoCreate the
    // profile-mgr and category-mgr COM objects, which expect a
    // resolvable CLSID for any class they're about to register.
    HRESULT hr = burmese::register_inproc_server();
    if (FAILED(hr)) return hr;
    hr = burmese::register_profile_and_category();
    if (FAILED(hr)) {
        // Roll back the in-proc reg so we don't leave a half-
        // registered CLSID that COM can resolve to our DLL but TSF
        // doesn't know about. Best-effort; the user can re-run.
        burmese::unregister_inproc_server();
        return hr;
    }
    return S_OK;
}

extern "C" HRESULT __stdcall DllUnregisterServer() {
    // Unregister in reverse order. Both calls are best-effort; we
    // return the first hard failure but always attempt both passes
    // so a partial state from a failed registration can still be
    // cleaned up by re-running with the uninstall verb.
    burmese::unregister_profile_and_category();
    return burmese::unregister_inproc_server();
}
