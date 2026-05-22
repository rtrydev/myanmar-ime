// COM registration entry points — DllRegisterServer / DllUnregisterServer.
//
// Writes the two registry shapes a TSF text service requires:
//
//   1. HKLM\Software\Classes\CLSID\{TIP-CLSID}\InprocServer32 (default
//      = DLL path, ThreadingModel = Apartment) — so CoCreateInstance
//      can find and load us.
//   2. The language profile is registered separately via
//      ITfInputProcessorProfileMgr::RegisterProfile. The MSI custom
//      action does that at install time; running regsvr32 alone is
//      enough to make CoCreateInstance work, but the IME won't appear
//      in the language list until RegisterProfile is called.
//
// regsvr32 runs us elevated, which is correct for per-machine HKLM
// writes. For per-user dev installs the helper exe (planned, not yet
// landed) will write to HKCU instead.

#include <Windows.h>
#include <olectl.h>     // SELFREG_E_CLASS
#include <string>

#include "guids.h"

namespace burmese {

extern HMODULE g_module;

namespace {

std::wstring module_path() {
    wchar_t buf[MAX_PATH] = {0};
    DWORD n = GetModuleFileNameW(g_module, buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return {};
    return std::wstring(buf, n);
}

std::wstring clsid_string() {
    LPOLESTR raw = nullptr;
    if (FAILED(StringFromCLSID(CLSID_TextService, &raw)) || !raw) return {};
    std::wstring out(raw);
    CoTaskMemFree(raw);
    return out;
}

LSTATUS set_string(HKEY parent, const wchar_t* sub, const wchar_t* name, const std::wstring& value) {
    HKEY key = nullptr;
    LSTATUS s = RegCreateKeyExW(parent, sub, 0, nullptr,
                                REG_OPTION_NON_VOLATILE,
                                KEY_WRITE, nullptr, &key, nullptr);
    if (s != ERROR_SUCCESS) return s;
    s = RegSetValueExW(key, name, 0, REG_SZ,
                       reinterpret_cast<const BYTE*>(value.c_str()),
                       static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
    return s;
}

} // namespace

HRESULT register_inproc_server() noexcept {
    const std::wstring path  = module_path();
    const std::wstring clsid = clsid_string();
    if (path.empty() || clsid.empty()) return E_FAIL;

    const std::wstring base = L"Software\\Classes\\CLSID\\" + clsid;
    if (set_string(HKEY_LOCAL_MACHINE, base.c_str(),
                   nullptr, kTextServiceDescription) != ERROR_SUCCESS)
        return SELFREG_E_CLASS;

    const std::wstring inproc = base + L"\\InprocServer32";
    if (set_string(HKEY_LOCAL_MACHINE, inproc.c_str(),
                   nullptr, path) != ERROR_SUCCESS)
        return SELFREG_E_CLASS;
    if (set_string(HKEY_LOCAL_MACHINE, inproc.c_str(),
                   L"ThreadingModel", L"Apartment") != ERROR_SUCCESS)
        return SELFREG_E_CLASS;
    return S_OK;
}

HRESULT unregister_inproc_server() noexcept {
    const std::wstring clsid = clsid_string();
    if (clsid.empty()) return E_FAIL;
    const std::wstring base = L"Software\\Classes\\CLSID\\" + clsid;
    // RegDeleteTreeW removes the whole subtree; not finding it is fine.
    LSTATUS s = RegDeleteTreeW(HKEY_LOCAL_MACHINE, base.c_str());
    if (s != ERROR_SUCCESS && s != ERROR_FILE_NOT_FOUND) {
        return SELFREG_E_CLASS;
    }
    return S_OK;
}

} // namespace burmese
