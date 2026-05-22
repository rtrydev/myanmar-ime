#include "display_attribute.h"
#include "text_service.h"

namespace burmese {

// ---- DisplayAttributeInfo ----------------------------------------

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::QueryInterface(REFIID riid, void** ppv) noexcept {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (riid == IID_IUnknown
        || QueryOne<ITfDisplayAttributeInfo>(riid, ppv, this)) {
        if (!*ppv) {
            *ppv = static_cast<ITfDisplayAttributeInfo*>(this);
            AddRef();
        }
        return S_OK;
    }
    return E_NOINTERFACE;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::GetGUID(GUID* pguid) noexcept {
    if (!pguid) return E_POINTER;
    *pguid = GUID_DisplayAttributeInput;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::GetDescription(BSTR* pbstrDesc) noexcept {
    if (!pbstrDesc) return E_POINTER;
    *pbstrDesc = SysAllocString(L"Myangler Burmese Input");
    return *pbstrDesc ? S_OK : E_OUTOFMEMORY;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::GetAttributeInfo(TF_DISPLAYATTRIBUTE* pda) noexcept {
    if (!pda) return E_POINTER;
    // Dotted underline only — keep the host's text colour and
    // background so the preedit reads as the user's text just with
    // a clear "this isn't committed yet" marker. fBoldLine = FALSE.
    pda->crText.type        = TF_CT_NONE;
    pda->crBk.type          = TF_CT_NONE;
    pda->lsStyle            = TF_LS_DOT;
    pda->fBoldLine          = FALSE;
    pda->crLine.type        = TF_CT_NONE;
    pda->bAttr              = TF_ATTR_INPUT;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::SetAttributeInfo(const TF_DISPLAYATTRIBUTE* /*pda*/) noexcept {
    // We don't currently persist user customisation. A no-op is
    // valid per the contract; TSF only requires that we accept the
    // call without error so the Settings UI can write attempts
    // without crashing.
    return S_OK;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfo::Reset() noexcept {
    return S_OK;
}

// ---- DisplayAttributeInfoEnum ------------------------------------

HRESULT STDMETHODCALLTYPE DisplayAttributeInfoEnum::QueryInterface(REFIID riid, void** ppv) noexcept {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (riid == IID_IUnknown
        || QueryOne<IEnumTfDisplayAttributeInfo>(riid, ppv, this)) {
        if (!*ppv) {
            *ppv = static_cast<IEnumTfDisplayAttributeInfo*>(this);
            AddRef();
        }
        return S_OK;
    }
    return E_NOINTERFACE;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfoEnum::Clone(IEnumTfDisplayAttributeInfo** out) noexcept {
    if (!out) return E_POINTER;
    auto* clone = new (std::nothrow) DisplayAttributeInfoEnum();
    if (!clone) return E_OUTOFMEMORY;
    clone->consumed_ = consumed_;
    *out = clone;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfoEnum::Next(ULONG count, ITfDisplayAttributeInfo** out, ULONG* fetched) noexcept {
    if (fetched) *fetched = 0;
    if (count == 0 || !out) return S_OK;
    if (consumed_) {
        out[0] = nullptr;
        return S_FALSE;
    }
    auto* info = new (std::nothrow) DisplayAttributeInfo();
    if (!info) return E_OUTOFMEMORY;
    out[0] = info;
    consumed_ = true;
    if (fetched) *fetched = 1;
    return (count > 1) ? S_FALSE : S_OK;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfoEnum::Reset() noexcept {
    consumed_ = false;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE DisplayAttributeInfoEnum::Skip(ULONG count) noexcept {
    if (count == 0) return S_OK;
    if (consumed_) return S_FALSE;
    consumed_ = true;
    return (count > 1) ? S_FALSE : S_OK;
}

// ---- TextService bridges -----------------------------------------

HRESULT STDMETHODCALLTYPE TextService::EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** out) noexcept {
    if (!out) return E_POINTER;
    auto* en = new (std::nothrow) DisplayAttributeInfoEnum();
    if (!en) return E_OUTOFMEMORY;
    *out = en;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE TextService::GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo** out) noexcept {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (guid != GUID_DisplayAttributeInput) return E_INVALIDARG;
    auto* info = new (std::nothrow) DisplayAttributeInfo();
    if (!info) return E_OUTOFMEMORY;
    *out = info;
    return S_OK;
}

} // namespace burmese
