#include "candidate_ui_element.h"

#include <OleAuto.h>   // SysAllocStringLen
#include <algorithm>

#include "guids.h"
#include "log_file.h"

namespace burmese {

namespace {

std::wstring widen_utf8(const std::string& s) noexcept {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    if (n <= 0) return {};
    std::wstring w(static_cast<size_t>(n - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
    return w;
}

BSTR make_bstr(const std::wstring& s) noexcept {
    return SysAllocStringLen(s.c_str(), static_cast<UINT>(s.size()));
}

} // namespace

CandidateUIElement::CandidateUIElement() noexcept {
    InitializeCriticalSection(&lock_);
}

CandidateUIElement::~CandidateUIElement() noexcept {
    // docMgr_ is a weak observe; never AddRef'd by us, so no Release.
    DeleteCriticalSection(&lock_);
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::QueryInterface(REFIID riid, void** ppv) noexcept {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (riid == IID_IUnknown
        || QueryOne<ITfUIElement>(riid, ppv, this)
        || QueryOne<ITfCandidateListUIElement>(riid, ppv, this)
        || QueryOne<ITfCandidateListUIElementBehavior>(riid, ppv, this)) {
        if (!*ppv) {
            // QueryOne handles AddRef on a hit. The IID_IUnknown branch
            // falls through with ppv still null; fix it up.
            *ppv = static_cast<ITfCandidateListUIElementBehavior*>(this);
            AddRef();
        }
        return S_OK;
    }
    return E_NOINTERFACE;
}

// ---- ITfUIElement --------------------------------------------------

HRESULT STDMETHODCALLTYPE CandidateUIElement::GetDescription(BSTR* pbstr) noexcept {
    if (!pbstr) return E_POINTER;
    // Short human-readable label. Surfaces in accessibility tools and
    // some shell debug views.
    *pbstr = SysAllocString(L"Myangler Burmese candidates");
    return *pbstr ? S_OK : E_OUTOFMEMORY;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::GetGUID(GUID* pguid) noexcept {
    if (!pguid) return E_POINTER;
    // Reuse the TIP CLSID — uniquely identifies *which* TIP the UI
    // element belongs to. Any GUID stable per-TIP works; the TSF
    // sample uses the TIP's own CLSID.
    *pguid = CLSID_TextService;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::Show(BOOL bShow) noexcept {
    // The host informs us whether it wants the UI visible. We don't
    // own a window to toggle here (the host either draws its own
    // panel for bShow=FALSE or asked us to keep showing ours for
    // bShow=TRUE); just record the state for IsShown() to return.
    shown_.store(bShow ? true : false, std::memory_order_release);
    log_line(L"CandidateUIElement::Show bShow=%d", bShow ? 1 : 0);
    return S_OK;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::IsShown(BOOL* pbShow) noexcept {
    if (!pbShow) return E_POINTER;
    *pbShow = shown_.load(std::memory_order_acquire) ? TRUE : FALSE;
    return S_OK;
}

// ---- ITfCandidateListUIElement ------------------------------------

HRESULT STDMETHODCALLTYPE CandidateUIElement::GetUpdatedFlags(DWORD* pdwFlags) noexcept {
    if (!pdwFlags) return E_POINTER;
    EnterCriticalSection(&lock_);
    *pdwFlags = updatedFlags_;
    updatedFlags_ = 0;  // host has consumed; clear for next cycle
    LeaveCriticalSection(&lock_);
    return S_OK;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::GetDocumentMgr(ITfDocumentMgr** ppdim) noexcept {
    if (!ppdim) return E_POINTER;
    *ppdim = nullptr;
    EnterCriticalSection(&lock_);
    ITfDocumentMgr* d = docMgr_;
    if (d) d->AddRef();
    LeaveCriticalSection(&lock_);
    *ppdim = d;
    return d ? S_OK : E_FAIL;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::GetCount(UINT* puCount) noexcept {
    if (!puCount) return E_POINTER;
    EnterCriticalSection(&lock_);
    *puCount = static_cast<UINT>(wideSurfaces_.size());
    LeaveCriticalSection(&lock_);
    return S_OK;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::GetSelection(UINT* puIndex) noexcept {
    if (!puIndex) return E_POINTER;
    EnterCriticalSection(&lock_);
    *puIndex = selectedIndex_;
    LeaveCriticalSection(&lock_);
    return S_OK;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::GetString(UINT uIndex, BSTR* pstr) noexcept {
    if (!pstr) return E_POINTER;
    *pstr = nullptr;
    EnterCriticalSection(&lock_);
    if (uIndex >= wideSurfaces_.size()) {
        LeaveCriticalSection(&lock_);
        return E_INVALIDARG;
    }
    *pstr = make_bstr(wideSurfaces_[uIndex]);
    LeaveCriticalSection(&lock_);
    return *pstr ? S_OK : E_OUTOFMEMORY;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::GetPageIndex(UINT* pIndex, UINT uSize, UINT* puPageCnt) noexcept {
    if (!puPageCnt) return E_POINTER;
    EnterCriticalSection(&lock_);
    const UINT total = static_cast<UINT>(wideSurfaces_.size());
    const UINT page  = pageSize_ > 0 ? pageSize_ : 9;
    const UINT count = (total + page - 1) / page;
    *puPageCnt = count;
    if (pIndex && uSize > 0) {
        // pIndex receives the per-page first-candidate indices. We
        // page uniformly: page p starts at p * pageSize.
        const UINT toFill = (uSize < count) ? uSize : count;
        for (UINT i = 0; i < toFill; ++i) {
            pIndex[i] = i * page;
        }
    }
    LeaveCriticalSection(&lock_);
    return S_OK;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::SetPageIndex(UINT* pIndex, UINT uPageCnt) noexcept {
    // The host can propose a page layout but we already paginate
    // uniformly off pageSize_; honour the count only if it implies a
    // new page size we can derive.
    if (!pIndex || uPageCnt == 0) return E_INVALIDARG;
    EnterCriticalSection(&lock_);
    // If the host says page-0 starts at index 0 and page-1 starts at
    // X, infer pageSize_ = X. Anything more elaborate would need us
    // to track per-page offsets — overkill for a fixed-page-size IME.
    if (uPageCnt >= 2 && pIndex[0] == 0 && pIndex[1] > 0) {
        pageSize_ = pIndex[1];
    }
    LeaveCriticalSection(&lock_);
    return S_OK;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::GetCurrentPage(UINT* puPage) noexcept {
    if (!puPage) return E_POINTER;
    EnterCriticalSection(&lock_);
    const UINT page = pageSize_ > 0 ? pageSize_ : 9;
    *puPage = selectedIndex_ / page;
    LeaveCriticalSection(&lock_);
    return S_OK;
}

// ---- TIP-thread API -----------------------------------------------

void CandidateUIElement::setSnapshot(const ParsedSnapshot& snapshot,
                                     DWORD changedFlags) noexcept {
    EnterCriticalSection(&lock_);
    wideSurfaces_.clear();
    wideSurfaces_.reserve(snapshot.candidates.size());
    for (const auto& c : snapshot.candidates) {
        wideSurfaces_.push_back(widen_utf8(c.surface));
    }
    const int sel = std::clamp(snapshot.selected, 0,
                               std::max<int>(0, static_cast<int>(wideSurfaces_.size()) - 1));
    selectedIndex_ = static_cast<UINT>(sel);
    // OR in the new dirty bits — accumulate until GetUpdatedFlags
    // is read (which clears).
    updatedFlags_ |= changedFlags;
    LeaveCriticalSection(&lock_);
}

void CandidateUIElement::setDocumentMgr(ITfDocumentMgr* dim) noexcept {
    EnterCriticalSection(&lock_);
    docMgr_ = dim;
    LeaveCriticalSection(&lock_);
}

void CandidateUIElement::setDelivery(HWND hwnd, WPARAM userParam) noexcept {
    deliveryHwnd_.store(hwnd, std::memory_order_release);
    deliveryUser_ = userParam;
}

// ---- ITfCandidateListUIElementBehavior ---------------------------
//
// Shell calls these on the TIP thread when the user interacts with
// the shell-rendered candidate panel (clicking a row, arrow keys
// inside the panel, Enter to commit, Esc to abort). We post the
// intent to TextService's message-only window so the actual
// commit/cancel work happens at a clean re-entrancy point and
// doesn't run inside a TSF callback that might already hold locks.

HRESULT STDMETHODCALLTYPE CandidateUIElement::SetSelection(UINT nIndex) noexcept {
    log_line(L"CandidateUIElement::SetSelection nIndex=%u", nIndex);
    EnterCriticalSection(&lock_);
    if (nIndex < wideSurfaces_.size()) {
        selectedIndex_ = nIndex;
    }
    LeaveCriticalSection(&lock_);
    HWND h = deliveryHwnd_.load(std::memory_order_acquire);
    if (h) PostMessageW(h, kMessageUiSelect, deliveryUser_,
                        static_cast<LPARAM>(nIndex));
    return S_OK;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::Finalize() noexcept {
    log_line(L"CandidateUIElement::Finalize");
    HWND h = deliveryHwnd_.load(std::memory_order_acquire);
    if (h) PostMessageW(h, kMessageUiFinalize, deliveryUser_, 0);
    return S_OK;
}

HRESULT STDMETHODCALLTYPE CandidateUIElement::Abort() noexcept {
    log_line(L"CandidateUIElement::Abort");
    HWND h = deliveryHwnd_.load(std::memory_order_acquire);
    if (h) PostMessageW(h, kMessageUiAbort, deliveryUser_, 0);
    return S_OK;
}

} // namespace burmese
