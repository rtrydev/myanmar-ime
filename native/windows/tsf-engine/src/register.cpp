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
#include <Lmcons.h>     // UNLEN
#include <olectl.h>     // SELFREG_E_CLASS
#include <msctf.h>
#include <string>

#include "com_helpers.h"
#include "guids.h"
#include "log_file.h"

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

// Format a GUID as "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}" (uppercase,
// braces). Same format StringFromCLSID emits — used to assemble the
// langid + CLSID + profile-GUID composite key that input.dll wants
// for InstallLayoutOrTip / SetDefaultLayoutOrTip.
std::wstring guid_with_braces(REFGUID g) {
    LPOLESTR raw = nullptr;
    if (FAILED(StringFromCLSID(g, &raw)) || !raw) return {};
    std::wstring out(raw);
    CoTaskMemFree(raw);
    return out;
}

// input.dll is the modern (Win10+) shell-side path for managing the
// per-user input-method list and default. Settings -> Time & Language
// -> Typing calls these same exports under the hood. Calling them
// from our installer writes the registry locations the new input
// switcher actually reads, which is broader than what the legacy
// ITfInputProcessorProfiles::SetDefaultLanguageProfile updates.
//
// The exports are undocumented but stable on every Windows 10 + 11
// build. Signatures derived from leaked headers and matched against
// the Settings UI's own usage:
//
//   BOOL WINAPI InstallLayoutOrTip(LPCWSTR psz, DWORD dwFlags);
//   BOOL WINAPI SetDefaultLayoutOrTip(LPCWSTR psz, DWORD dwFlags);
//
// `psz` format for a TIP:
//   "<langid hex>:{CLSID-with-braces}{ProfileGUID-with-braces}"
// e.g.
//   "0455:{4A524193-23CC-4586-9703-1FBD3ABE394F}{4A524193-23CC-4586-9703-1FBD3ABE394F}"
//
// Multiple TIPs can be passed in one call by separating specs with
// ';'. We only have one; the format above is what the Settings UI
// emits per-TIP.
using InstallLayoutOrTipFn    = BOOL(WINAPI*)(LPCWSTR psz, DWORD dwFlags);
using SetDefaultLayoutOrTipFn = BOOL(WINAPI*)(LPCWSTR psz, DWORD dwFlags);

void install_and_default_via_input_dll() noexcept {
    HMODULE dll = LoadLibraryW(L"input.dll");
    if (!dll) {
        log_line(L"  input.dll LoadLibraryW failed gle=%u", GetLastError());
        return;
    }

    auto installFn = reinterpret_cast<InstallLayoutOrTipFn>(
        GetProcAddress(dll, "InstallLayoutOrTip"));
    auto setDefaultFn = reinterpret_cast<SetDefaultLayoutOrTipFn>(
        GetProcAddress(dll, "SetDefaultLayoutOrTip"));
    if (!installFn || !setDefaultFn) {
        log_line(L"  input.dll exports missing install=%p setDefault=%p",
                 reinterpret_cast<void*>(installFn),
                 reinterpret_cast<void*>(setDefaultFn));
        FreeLibrary(dll);
        return;
    }

    const std::wstring clsidStr   = guid_with_braces(CLSID_TextService);
    const std::wstring profileStr = guid_with_braces(GUID_Profile);
    if (clsidStr.empty() || profileStr.empty()) {
        log_line(L"  guid_with_braces returned empty");
        FreeLibrary(dll);
        return;
    }

    wchar_t spec[256];
    int n = std::swprintf(spec, std::size(spec), L"%04X:%s%s",
                          static_cast<unsigned>(kLangIdBurmese),
                          clsidStr.c_str(), profileStr.c_str());
    if (n <= 0) {
        log_line(L"  swprintf failed building input.dll spec");
        FreeLibrary(dll);
        return;
    }
    log_line(L"  input.dll spec='%s'", spec);

    SetLastError(0);
    const BOOL okInstall = installFn(spec, 0);
    log_line(L"  InstallLayoutOrTip ok=%d gle=%u",
             okInstall ? 1 : 0, GetLastError());

    SetLastError(0);
    const BOOL okDefault = setDefaultFn(spec, 0);
    log_line(L"  SetDefaultLayoutOrTip ok=%d gle=%u",
             okDefault ? 1 : 0, GetLastError());

    FreeLibrary(dll);
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

// Undocumented TSF categories every shipping Microsoft IME registers
// — Pinyin, Bopomofo, Wubi, Changjie, Japanese, Hangul — but none are
// in msctf.h. Identified by reading HKLM\Software\Microsoft\CTF\TIP\
// {pinyin-clsid}\Category\Category and diffing against ours. Without
// the full set the Win11 immersive shell falls back to "TIP draws its
// own popup" (pbShow=TRUE from BeginUIElement), which is invisible
// behind the shell's compositor surface. Best-guess names from
// fragments scattered across older Windows SDK versions, leaked TSF
// internals, and win32k symbol dumps. Registration is just a marker
// — no COM implementation is required on our side.
const GUID kTipcapComLess = {
    0x364215D9, 0x75BC, 0x11D7,
    { 0xA6, 0xEF, 0x00, 0x06, 0x5B, 0x84, 0x43, 0x5C } };
const GUID kPropStyleStatic = {
    0x3AF314A2, 0xD79F, 0x4B1B,
    { 0x99, 0x92, 0x15, 0x08, 0x6D, 0x33, 0x9B, 0x05 } };
const GUID kTipcapSecureMode = {
    0x49D2F9CE, 0x1F5E, 0x11D7,
    { 0xA6, 0xD3, 0x00, 0x06, 0x5B, 0x84, 0x43, 0x5C } };
const GUID kTipcapInputModeCompartment = {
    0x74769EE9, 0x4A66, 0x4F9D,
    { 0x90, 0xD6, 0xBF, 0x8B, 0x7C, 0x3E, 0xB4, 0x61 } };
const GUID kDisplayAttributeProperty = {
    0xCCF05DD7, 0x4A87, 0x11D7,
    { 0xA6, 0xE2, 0x00, 0x06, 0x5B, 0x84, 0x43, 0x5C } };

// Categories register_profile_and_category WRITES. Kept to the
// documented 5 because adding the undocumented Pinyin-style ones
// (kTipcapComLess et al.) in 0.1.16 broke key handling in every
// host — the system started treating the TIP as COMLESS / static-
// data and bypassed our engine entirely. The undocumented set
// gates Win11-immersive shell-rendered candidate UI, which is a
// real feature, but the cost is breaking classic-host input
// processing — not a tradeoff worth shipping until we identify
// the exact subset that's safe.
const GUID* const kRegisterCategories[] = {
    &GUID_TFCAT_TIP_KEYBOARD,
    &GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
    &GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
    &GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
    &GUID_TFCAT_TIPCAP_UIELEMENTENABLED,
};

// Categories unregister_profile_and_category SCRUBS. Superset that
// includes the undocumented ones we briefly registered in 0.1.16,
// so a fresh install of 0.1.17+ over 0.1.16 (or a manual
// uninstall) clears every category we have ever written.
// UnregisterCategory on a category that isn't registered is a
// silent no-op, so the extras here are safe.
const GUID* const kUnregisterCategories[] = {
    &GUID_TFCAT_TIP_KEYBOARD,
    &GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
    &GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
    &GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
    &GUID_TFCAT_TIPCAP_UIELEMENTENABLED,
    &kTipcapComLess,
    &kPropStyleStatic,
    &kTipcapSecureMode,
    &kTipcapInputModeCompartment,
    &kDisplayAttributeProperty,
};

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

    // Pass no icon. We tried passing the TIP DLL path with index 0,
    // but the DLL has no icon resources — Windows then can't load a
    // valid icon for the profile and some shell paths behave oddly
    // (suspected contributor to the "Activate then auto-deactivate"
    // bounce-back). Null icon -> OS default. A future commit can
    // ship a real .ico resource and reference it here.
    hr = profileMgr->RegisterProfile(
        CLSID_TextService,
        kLangIdBurmese,
        GUID_Profile,
        kTextServiceDescription,
        static_cast<ULONG>(std::wcslen(kTextServiceDescription)),
        /*pchIconFile=*/nullptr,
        /*cchFile=*/0,
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
    // Documented categories — present in msctf.h:
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
    //
    // Source of truth for the writable category list is
    // kRegisterCategories at file scope. The kUnregister set is a
    // superset that includes categories we used to write — see the
    // comment above the arrays.
    for (const GUID* cat : kRegisterCategories) {
        hr = categoryMgr->RegisterCategory(
            CLSID_TextService, *cat, CLSID_TextService);
        if (FAILED(hr)) return hr;
    }
    return S_OK;
}

// Per-user HKCU: set Myangler as the user's preferred IM for
// Burmese. Without this Windows treats our profile as merely
// *available* — selecting Myangler in Win+Space switches the input
// language to Burmese but uses the language's preferred IM (the OS
// built-in Burmese IM), not ours. Symptoms: first Win+Space pick of
// Myangler doesn't load our TIP DLL at all — the user has to pick
// twice to switch IM *within* Burmese to Myangler. Same root cause
// behind "focus change reverts to English": Windows resets to the
// preferred IM on every focus transition, and Myangler isn't
// preferred yet.
//
// Must run in the user's context. From a deferred MSI custom
// action this means Impersonate="yes"; from regsvr32 /
// register_profile.exe run interactively it's the calling user.
// SYSTEM-context invocation is a no-op (writes go to SYSTEM's
// HKCU profile).
//
// Two-step process. SetDefaultLanguageProfile alone silently no-ops
// if the profile isn't *enabled* for the user first — the
// bEnabledByDefault=TRUE flag we pass to RegisterProfile only
// auto-enables for users who add Burmese to their language list
// *after* our install. Users who already had Burmese before
// installing Myangler need an explicit EnableLanguageProfile(TRUE)
// to populate HKCU\...\CTF\TIP\{CLSID}\LanguageProfile\0x00000455\
// {ProfileGUID}\Enable=1 — only then will SetDefaultLanguageProfile
// write the HKCU\...\CTF\Assemblies\0x00000455\... preferred-IM
// pointer that drives Win+Space and focus-transition behaviour.
//
// HRESULTs are logged explicitly because both calls are
// silent-failure-prone in this codepath, and the impersonated
// user name is logged because MSI deferred custom actions can
// occasionally drop the impersonation token under UAC quirks and
// end up running as SYSTEM (writing to SYSTEM's HKCU, which the
// real user never sees).
HRESULT set_user_default_profile() noexcept {
    {
        wchar_t userName[UNLEN + 1] = {0};
        DWORD userNameLen = UNLEN + 1;
        if (GetUserNameW(userName, &userNameLen)) {
            log_line(L"  set_user_default_profile user=%s", userName);
        } else {
            log_line(L"  set_user_default_profile GetUserNameW failed gle=%u",
                     GetLastError());
        }
    }

    ComPtr<ITfInputProcessorProfiles> profiles;
    HRESULT hr = CoCreateInstance(
        CLSID_TF_InputProcessorProfiles, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(profiles.put()));
    if (FAILED(hr)) {
        log_line(L"  CoCreateInstance(ITfInputProcessorProfiles) failed 0x%08X",
                 static_cast<unsigned>(hr));
        return hr;
    }

    const HRESULT hrEnable = profiles->EnableLanguageProfile(
        CLSID_TextService, kLangIdBurmese, GUID_Profile, TRUE);
    log_line(L"  EnableLanguageProfile hr=0x%08X", static_cast<unsigned>(hrEnable));
    // Don't abort on failure here — SetDefaultLanguageProfile might
    // still succeed if the profile was already enabled from a
    // previous install. We logged the HRESULT so a post-mortem can
    // tell which call did the real work.

    SetLastError(0);
    const HRESULT hrDefault = profiles->SetDefaultLanguageProfile(
        kLangIdBurmese, CLSID_TextService, GUID_Profile);
    log_line(L"  SetDefaultLanguageProfile hr=0x%08X gle=%u",
             static_cast<unsigned>(hrDefault), GetLastError());

    // Modern (Win10+) fallback. ITfInputProcessorProfiles::
    // SetDefaultLanguageProfile is the legacy TSF default-setter and
    // only writes the old HKCU\...\CTF\Assemblies\<langid>\ key — the
    // new shell input switcher (Win+Space, focus-transition default)
    // reads additional locations that input.dll's InstallLayoutOrTip
    // + SetDefaultLayoutOrTip populate. We run input.dll unconditionally
    // (regardless of whether the legacy call succeeded) because:
    //   * The legacy call has been observed to return E_FAIL on
    //     Windows 11 even with EnableLanguageProfile=TRUE already
    //     applied — a side effect of the shell having moved the
    //     authoritative state out of the legacy keys.
    //   * input.dll is idempotent: calling it after a successful
    //     legacy write is harmless (it just rewrites the same
    //     state, plus the newer keys).
    install_and_default_via_input_dll();

    // Don't surface SetDefaultLanguageProfile failure to the caller
    // if input.dll might have succeeded — the user's preferred-IM
    // state is now set via the modern path and that's what matters.
    // Only EnableLanguageProfile failure is a hard error (without
    // it, neither default-setter has any state to point at).
    return FAILED(hrEnable) ? hrEnable : S_OK;
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
        for (const GUID* cat : kUnregisterCategories) {
            categoryMgr->UnregisterCategory(
                CLSID_TextService, *cat, CLSID_TextService);
        }
    }
    return S_OK;
}

} // namespace burmese
