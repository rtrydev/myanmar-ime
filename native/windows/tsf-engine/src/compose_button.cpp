#include "compose_button.h"

#include "guids.h"

#include <olectl.h>     // CONNECT_E_*
#include <cwchar>

namespace burmese {

namespace {

constexpr wchar_t kButtonText[]    = L"က";    // U+1000 (Myanmar ka) — short visual marker
constexpr wchar_t kTooltipOn []    = L"Burmese (Compose) — click to disable";
constexpr wchar_t kTooltipOff[]    = L"Burmese (Roman) — click to enable Compose";
constexpr wchar_t kButtonDescription[] = L"Compose / Roman";

} // namespace

ComposeButton::ComposeButton(ToggleCallback cb) noexcept
    : onToggle_(std::move(cb)) {}

void ComposeButton::setState(bool composeEnabled) noexcept {
    if (composeEnabled_ == composeEnabled) return;
    composeEnabled_ = composeEnabled;
    notifySink(TF_LBI_STATUS | TF_LBI_TEXT | TF_LBI_TOOLTIP | TF_LBI_ICON);
}

void ComposeButton::notifySink(DWORD updateFlags) noexcept {
    if (sink_) sink_->OnUpdate(updateFlags);
}

// ---- IUnknown ----------------------------------------------------

HRESULT STDMETHODCALLTYPE ComposeButton::QueryInterface(REFIID riid, void** ppv) noexcept {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (riid == IID_IUnknown
        || QueryOne<ITfLangBarItem>(riid, ppv, this)
        || QueryOne<ITfLangBarItemButton>(riid, ppv, this)
        || QueryOne<ITfSource>(riid, ppv, this)) {
        if (!*ppv) {
            *ppv = static_cast<ITfLangBarItemButton*>(this);
            AddRef();
        }
        return S_OK;
    }
    return E_NOINTERFACE;
}

// ---- ITfLangBarItem ----------------------------------------------

HRESULT STDMETHODCALLTYPE ComposeButton::GetInfo(TF_LANGBARITEMINFO* info) noexcept {
    if (!info) return E_POINTER;
    info->clsidService = CLSID_TextService;
    info->guidItem     = GUID_LangBarItemCompose;
    info->dwStyle      = TF_LBI_STYLE_BTN_BUTTON;
    info->ulSort       = 0;
    // szDescription is a fixed-size buffer in the struct (32 wchars).
    wcsncpy_s(info->szDescription, kButtonDescription,
              sizeof(info->szDescription) / sizeof(wchar_t));
    return S_OK;
}

HRESULT STDMETHODCALLTYPE ComposeButton::GetStatus(DWORD* status) noexcept {
    if (!status) return E_POINTER;
    // When Compose is off (Roman passthrough), the button renders
    // in the "toggled" / depressed state so the user can see at a
    // glance that the engine is bypassed.
    *status = composeEnabled_ ? 0 : TF_LBI_STATUS_BTN_TOGGLED;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE ComposeButton::Show(BOOL /*fShow*/) noexcept {
    // No-op: the langbar UI manages visibility itself; we don't
    // need to honour explicit show/hide requests for this button.
    return S_OK;
}

HRESULT STDMETHODCALLTYPE ComposeButton::GetTooltipString(BSTR* tip) noexcept {
    if (!tip) return E_POINTER;
    *tip = SysAllocString(composeEnabled_ ? kTooltipOn : kTooltipOff);
    return *tip ? S_OK : E_OUTOFMEMORY;
}

// ---- ITfLangBarItemButton ----------------------------------------

HRESULT STDMETHODCALLTYPE ComposeButton::OnClick(TfLBIClick /*click*/, POINT /*pt*/, const RECT* /*area*/) noexcept {
    composeEnabled_ = !composeEnabled_;
    if (onToggle_) onToggle_(composeEnabled_);
    notifySink(TF_LBI_STATUS | TF_LBI_TEXT | TF_LBI_TOOLTIP | TF_LBI_ICON);
    return S_OK;
}

HRESULT STDMETHODCALLTYPE ComposeButton::InitMenu(ITfMenu* /*menu*/) noexcept {
    // No drop-down menu — the button is click-toggle only.
    return S_OK;
}

HRESULT STDMETHODCALLTYPE ComposeButton::OnMenuSelect(UINT /*id*/) noexcept {
    return S_OK;
}

HRESULT STDMETHODCALLTYPE ComposeButton::GetIcon(HICON* icon) noexcept {
    if (!icon) return E_POINTER;
    // No custom icon yet — Windows will render the button text
    // (GetText) when there's no icon. A future commit can ship a
    // pair of small .ico resources for the on/off states.
    *icon = nullptr;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE ComposeButton::GetText(BSTR* text) noexcept {
    if (!text) return E_POINTER;
    *text = SysAllocString(kButtonText);
    return *text ? S_OK : E_OUTOFMEMORY;
}

// ---- ITfSource ----------------------------------------------------

HRESULT STDMETHODCALLTYPE ComposeButton::AdviseSink(REFIID riid, IUnknown* punk, DWORD* cookie) noexcept {
    if (!cookie || !punk) return E_POINTER;
    if (riid != IID_ITfLangBarItemSink) return CONNECT_E_CANNOTCONNECT;
    if (sink_) return CONNECT_E_ADVISELIMIT;
    ITfLangBarItemSink* raw = nullptr;
    if (FAILED(punk->QueryInterface(IID_ITfLangBarItemSink,
                                    reinterpret_cast<void**>(&raw))) || !raw) {
        return CONNECT_E_CANNOTCONNECT;
    }
    sink_.attach(raw);
    *cookie = kSinkCookie;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE ComposeButton::UnadviseSink(DWORD cookie) noexcept {
    if (cookie != kSinkCookie || !sink_) return CONNECT_E_NOCONNECTION;
    sink_.reset();
    return S_OK;
}

} // namespace burmese
