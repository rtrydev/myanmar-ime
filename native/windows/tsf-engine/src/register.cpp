// Registration entry points — DllRegisterServer / DllUnregisterServer.
//
// Three things must be in place for Windows to load + activate the
// TIP, all done here so both regsvr32 and the register_profile.exe
// helper produce identical state:
//
//   1. COM in-proc server registration.
//      HKLM\Software\Classes\CLSID\{TIP-CLSID}\InprocServer32 default
//      points at the DLL file and ThreadingModel = Apartment.
//      CoCreateInstance(CLSID_TextService) won't work without it.
//
//   2. TSF profile registration.
//      ITfInputProcessorProfileMgr::RegisterProfile binds the TIP
//      CLSID to a LANGID + profile GUID. Without this the TIP is
//      addressable via CoCreateInstance but does NOT appear in
//      Settings -> Time & language -> Language -> Options ->
//      Keyboards, so users can't activate it.
//
//   3. TSF category registration.
//      ITfCategoryMgr::RegisterCategory under GUID_TFCAT_TIP_KEYBOARD
//      tells TSF that this CLSID is a keyboard-type TIP. Without
//      it the profile registration succeeds but the OS doesn't
//      surface us as a keyboard input method.
//
// All three need HKLM write access. The caller (regsvr32 or our
// helper exe) must be elevated. COM must be initialised on the
// calling thread for steps 2-3.

#include <Windows.h>
#include <olectl.h>     // SELFREG_E_CLASS
#include <msctf.h>
#include <string>

#include "com_helpers.h"
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

HRESULT register_profile_and_category() noexcept {
    const std::wstring dllPath = module_path();
    if (dllPath.empty()) return E_FAIL;

    HRESULT hr;

    ComPtr<ITfInputProcessorProfileMgr> profileMgr;
    hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
                          CLSCTX_INPROC_SERVER,
                          IID_PPV_ARGS(profileMgr.put()));
    if (FAILED(hr)) return hr;

    // Use the TIP DLL itself as the icon source — it has no resources
    // today, so the icon will be a generic one until we ship an
    // .ico resource. Index 0 = first icon in the file (none = OS
    // fallback). Description: visible name in the language bar.
    hr = profileMgr->RegisterProfile(
        CLSID_TextService,
        kLangIdBurmese,
        GUID_Profile,
        kTextServiceDescription,
        static_cast<ULONG>(std::wcslen(kTextServiceDescription)),
        dllPath.c_str(),
        static_cast<ULONG>(dllPath.size()),
        /*uIconIndex=*/0,
        /*hklSubstitute=*/nullptr,
        /*dwPreferredLayout=*/0,
        /*bEnabledByDefault=*/TRUE,
        /*dwFlags=*/0);
    if (FAILED(hr)) return hr;

    ComPtr<ITfCategoryMgr> categoryMgr;
    hr = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr,
                          CLSCTX_INPROC_SERVER,
                          IID_PPV_ARGS(categoryMgr.put()));
    if (FAILED(hr)) return hr;

    // Every category the TIP belongs to. Order doesn't matter; any
    // failure aborts (we'd rather show the user a clean error than
    // a half-registered TIP).
    //
    // Why each one:
    //   TIP_KEYBOARD                  base "this CLSID is a TIP"
    //   DISPLAYATTRIBUTEPROVIDER      so TSF asks us for the preedit
    //                                 underline attribute
    //   TIPCAP_IMMERSIVESUPPORT       *required* for modern Windows:
    //                                 without this declaration TSF
    //                                 activates the TIP briefly then
    //                                 auto-deactivates it in favour
    //                                 of an immersive-capable one,
    //                                 because Win10+ assumes a TIP
    //                                 that hasn't opted in cannot
    //                                 host inside UWP / immersive
    //                                 contexts safely.
    //   TIPCAP_SYSTRAYSUPPORT         we have a langbar item
    //                                 (Compose/Roman toggle) that
    //                                 surfaces in the system tray
    //                                 IME indicator menu.
    //   TIPCAP_UIELEMENTENABLED       we own a custom UI element
    //                                 (the candidate window) the OS
    //                                 should be aware of for
    //                                 windowing / accessibility.
    const GUID* const categories[] = {
        &GUID_TFCAT_TIP_KEYBOARD,
        &GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
        &GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
        &GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
        &GUID_TFCAT_TIPCAP_UIELEMENTENABLED,
    };
    for (const GUID* cat : categories) {
        hr = categoryMgr->RegisterCategory(
            CLSID_TextService, *cat, CLSID_TextService);
        if (FAILED(hr)) return hr;
    }
    return S_OK;
}

HRESULT unregister_profile_and_category() noexcept {
    // Best-effort: missing entries are fine. Any failure we report
    // from DllUnregisterServer would block the helper from cleaning
    // up the COM in-proc registration too, which is worse.
    ComPtr<ITfInputProcessorProfileMgr> profileMgr;
    if (SUCCEEDED(CoCreateInstance(
            CLSID_TF_InputProcessorProfiles, nullptr,
            CLSCTX_INPROC_SERVER, IID_PPV_ARGS(profileMgr.put())))) {
        profileMgr->UnregisterProfile(
            CLSID_TextService, kLangIdBurmese, GUID_Profile, 0);
    }

    ComPtr<ITfCategoryMgr> categoryMgr;
    if (SUCCEEDED(CoCreateInstance(
            CLSID_TF_CategoryMgr, nullptr,
            CLSCTX_INPROC_SERVER, IID_PPV_ARGS(categoryMgr.put())))) {
        const GUID* const categories[] = {
            &GUID_TFCAT_TIP_KEYBOARD,
            &GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
            &GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
            &GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
            &GUID_TFCAT_TIPCAP_UIELEMENTENABLED,
        };
        for (const GUID* cat : categories) {
            categoryMgr->UnregisterCategory(
                CLSID_TextService, *cat, CLSID_TextService);
        }
    }
    return S_OK;
}

} // namespace burmese
