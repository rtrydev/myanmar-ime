// TSF UI-element bridge for the candidate panel.
//
// Background: a classic WS_POPUP candidate window (our CandidateWindow)
// works fine in Win32 hosts (Notepad, Office, browsers). It fails in
// Win11 immersive hosts — the Start Menu Search Bar, UWP apps,
// snap-layout flyouts — because those use XAML islands that the
// desktop compositor renders ABOVE every classic topmost HWND. Our
// ShowWindow/SetWindowPos(HWND_TOPMOST) succeeds and TSF's GetTextExt
// returns a valid caret rect, but the shell surface paints over us.
//
// The blessed Win10+ fix is to participate in TSF's UI-element model:
//
//   1. Implement ITfCandidateListUIElement (which extends
//      ITfUIElement). The interface exposes our candidate list as
//      data — list count, current selection, per-entry surface
//      string, pagination — without dictating how it's drawn.
//
//   2. When the candidate list becomes non-empty, call
//      ITfUIElementMgr::BeginUIElement(this, &bShow, &cookie).
//      The OUT pbShow tells us how the host wants to render:
//        * bShow == TRUE  — host is a classic surface; it expects
//                            us to keep drawing our own UI. We do
//                            both: BeginUIElement (so the host
//                            knows we have a list open, for
//                            accessibility / inspection / etc.)
//                            and our normal CandidateWindow path.
//        * bShow == FALSE — host is immersive (Search Bar,
//                            UWP, etc.). The shell will render
//                            its own native Win11-look candidate
//                            panel using our ITfCandidateListUI-
//                            Element data. We MUST suppress our
//                            own popup or the two will both
//                            appear (theirs above, ours behind,
//                            looking like a duplicate).
//
//   3. Every snapshot change calls UpdateUIElement(cookie). The
//      host re-queries via the getters. We record which fields
//      changed in updatedFlags_ so GetUpdatedFlags returns them
//      (the TSF spec — host trusts the flags as an optimisation
//      hint but is allowed to re-read everything).
//
//   4. On hide (commit, cancel, empty list), EndUIElement(cookie).
//
// Threading: the host can call our ITfCandidateListUIElement
// getters from any thread. We snapshot all data into a lockable
// payload so getters never reach into TextService's main-thread
// state directly. setSnapshot() runs on the TIP thread; the
// getters acquire a CRITICAL_SECTION and copy out under it.

#pragma once

#include <Windows.h>
#include <msctf.h>
#include <ctffunc.h>

#include <atomic>
#include <string>
#include <vector>

#include "com_helpers.h"
#include "snapshot.h"

namespace burmese {

class CandidateUIElement final
    : public UnknownBase
    , public ITfCandidateListUIElementBehavior {
public:
    CandidateUIElement() noexcept;
    ~CandidateUIElement() noexcept override;

    // IUnknown
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) noexcept override;
    ULONG   STDMETHODCALLTYPE AddRef()  noexcept override { return UnknownBase::AddRef();  }
    ULONG   STDMETHODCALLTYPE Release() noexcept override { return UnknownBase::Release(); }

    // ITfUIElement
    HRESULT STDMETHODCALLTYPE GetDescription(BSTR* pbstr) noexcept override;
    HRESULT STDMETHODCALLTYPE GetGUID(GUID* pguid) noexcept override;
    HRESULT STDMETHODCALLTYPE Show(BOOL bShow) noexcept override;
    HRESULT STDMETHODCALLTYPE IsShown(BOOL* pbShow) noexcept override;

    // ITfCandidateListUIElement
    HRESULT STDMETHODCALLTYPE GetUpdatedFlags(DWORD* pdwFlags) noexcept override;
    HRESULT STDMETHODCALLTYPE GetDocumentMgr(ITfDocumentMgr** ppdim) noexcept override;
    HRESULT STDMETHODCALLTYPE GetCount(UINT* puCount) noexcept override;
    HRESULT STDMETHODCALLTYPE GetSelection(UINT* puIndex) noexcept override;
    HRESULT STDMETHODCALLTYPE GetString(UINT uIndex, BSTR* pstr) noexcept override;
    HRESULT STDMETHODCALLTYPE GetPageIndex(UINT* pIndex, UINT uSize, UINT* puPageCnt) noexcept override;
    HRESULT STDMETHODCALLTYPE SetPageIndex(UINT* pIndex, UINT uPageCnt) noexcept override;
    HRESULT STDMETHODCALLTYPE GetCurrentPage(UINT* puPage) noexcept override;

    // ITfCandidateListUIElementBehavior — adds the back-channel the
    // shell needs to drive selection / commit from its own UI. The
    // shell renders the candidate panel ONLY when this interface is
    // present, because without it there's no way for shell-side
    // clicks / arrow keys / Enter to reach the TIP. With it,
    // BeginUIElement is allowed to return pbShow=FALSE and the
    // shell takes over rendering. These three methods are called on
    // the TIP thread by the shell; we just forward the intent to
    // TextService via PostMessage so the actual edit-session work
    // happens at a known re-entrancy point.
    HRESULT STDMETHODCALLTYPE SetSelection(UINT nIndex) noexcept override;
    HRESULT STDMETHODCALLTYPE Finalize()                noexcept override;
    HRESULT STDMETHODCALLTYPE Abort()                   noexcept override;

    // ---- TIP-thread API ----

    // Replace the snapshot the host will read via the getters. Caller
    // owns flagging *what* changed so we can return precise flags
    // from GetUpdatedFlags. Calling repeatedly accumulates flags
    // until GetUpdatedFlags is called (the host clears the flags
    // by reading them).
    void setSnapshot(const ParsedSnapshot& snapshot, DWORD changedFlags) noexcept;

    // Set the doc-manager pointer the host will receive from
    // GetDocumentMgr. We don't AddRef here — the caller passes a
    // ref it owns and we hold a weak observe. Caller must clear()
    // before releasing. Acceptable trade-off: the doc manager
    // outlives the candidate panel by construction.
    void setDocumentMgr(ITfDocumentMgr* dim) noexcept;

    // Where to PostMessage SetSelection / Finalize / Abort. Should
    // be the same message-only HWND the engine worker delivers
    // results to. Set once by TextService after construction.
    void setDelivery(HWND hwnd, WPARAM userParam) noexcept;

    // True after the host (or we ourselves) requested visibility.
    // Currently informational — we don't use it for any decision.
    bool isShown() const noexcept { return shown_.load(std::memory_order_acquire); }

    // Message ids posted to the delivery HWND. wParam is the
    // userParam passed to setDelivery; lParam carries:
    //   kMessageUiSelect   — lParam = selected index (0-based)
    //   kMessageUiFinalize — lParam unused
    //   kMessageUiAbort    — lParam unused
    static constexpr UINT kMessageUiSelect   = WM_USER + 0x110;
    static constexpr UINT kMessageUiFinalize = WM_USER + 0x111;
    static constexpr UINT kMessageUiAbort    = WM_USER + 0x112;

private:
    CRITICAL_SECTION       lock_{};
    std::vector<std::wstring> wideSurfaces_;   // candidates[i].surface decoded once
    UINT                   selectedIndex_ = 0;
    UINT                   pageSize_      = 9;
    DWORD                  updatedFlags_  = 0;

    ITfDocumentMgr*        docMgr_ = nullptr;
    std::atomic<bool>      shown_{false};

    std::atomic<HWND>      deliveryHwnd_{nullptr};
    WPARAM                 deliveryUser_ = 0;
};

} // namespace burmese
