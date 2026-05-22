// Compose/Roman toggle button — appears in the Windows input
// indicator menu (the IME chevron in the system tray). Clicking it
// flips between Compose mode (every keystroke routes through the
// engine) and Roman mode (every typeable key commits raw ASCII to
// the host immediately).
//
// Mirrors the macOS menubar "Compose / Roman" toggle and the IBus
// `myangler.compose` IBusProperty toggle. The shared rule: when
// Compose is OFF, the engine is fully bypassed — composing buffer
// stays empty, no composition is opened, no candidates appear.
//
// The button publishes itself to TSF via the ITfLangBarItem family:
//   * ITfLangBarItem      — the basic item descriptor (GetInfo,
//                           GetStatus, Show, GetTooltipString).
//   * ITfLangBarItemButton — adds button-specific OnClick / icon /
//                           text methods.
//   * ITfSource            — exposes AdviseSink/UnadviseSink so TSF
//                           can register an ITfLangBarItemSink that
//                           we notify on state change.

#pragma once

#include <Windows.h>
#include <msctf.h>

#include <functional>

#include "com_helpers.h"

namespace burmese {

class ComposeButton final
    : public UnknownBase
    , public ITfLangBarItemButton
    , public ITfSource {
public:
    using ToggleCallback = std::function<void(bool /*composeEnabled*/)>;

    explicit ComposeButton(ToggleCallback cb) noexcept;

    // Externally driven state setter — used when the TIP needs to
    // sync the button to whatever state composeEnabled_ becomes
    // (e.g. on Activate, restoring a persisted value). Fires the
    // registered sink so the langbar repaints.
    void setState(bool composeEnabled) noexcept;
    bool composeEnabled() const noexcept { return composeEnabled_; }

    // IUnknown
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) noexcept override;
    ULONG   STDMETHODCALLTYPE AddRef()  noexcept override { return UnknownBase::AddRef(); }
    ULONG   STDMETHODCALLTYPE Release() noexcept override { return UnknownBase::Release(); }

    // ITfLangBarItem
    HRESULT STDMETHODCALLTYPE GetInfo(TF_LANGBARITEMINFO* info) noexcept override;
    HRESULT STDMETHODCALLTYPE GetStatus(DWORD* status) noexcept override;
    HRESULT STDMETHODCALLTYPE Show(BOOL fShow) noexcept override;
    HRESULT STDMETHODCALLTYPE GetTooltipString(BSTR* tip) noexcept override;

    // ITfLangBarItemButton
    HRESULT STDMETHODCALLTYPE OnClick(TfLBIClick click, POINT pt, const RECT* area) noexcept override;
    HRESULT STDMETHODCALLTYPE InitMenu(ITfMenu* menu) noexcept override;
    HRESULT STDMETHODCALLTYPE OnMenuSelect(UINT id) noexcept override;
    HRESULT STDMETHODCALLTYPE GetIcon(HICON* icon) noexcept override;
    HRESULT STDMETHODCALLTYPE GetText(BSTR* text) noexcept override;

    // ITfSource
    HRESULT STDMETHODCALLTYPE AdviseSink(REFIID riid, IUnknown* punk, DWORD* cookie) noexcept override;
    HRESULT STDMETHODCALLTYPE UnadviseSink(DWORD cookie) noexcept override;

private:
    void notifySink(DWORD updateFlags) noexcept;

    bool composeEnabled_ = true;
    ToggleCallback onToggle_;

    // TSF only registers one ITfLangBarItemSink at a time. Cookie
    // is the magic constant TSF samples use — any unique non-zero
    // value works since we only have one slot.
    ComPtr<ITfLangBarItemSink> sink_;
    static constexpr DWORD kSinkCookie = 0x42UL;
};

} // namespace burmese
