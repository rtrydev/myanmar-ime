// Display-attribute provider for the BurmeseIME TIP.
//
// TSF lets a TIP visually distinguish its preedit text from already-
// committed text by attaching a "display attribute" to the
// composition range. The standard preedit decoration is a dotted
// underline, which is what we ship.
//
// The mechanics:
//   1. TextService implements ITfDisplayAttributeProvider and
//      enumerates one ITfDisplayAttributeInfo identified by
//      GUID_DisplayAttributeInput (from guids.h).
//   2. At registration time, the TIP is added to category
//      GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER so TSF knows to ask us
//      for attribute info.
//   3. After every ITfRange::SetText in composition.cpp, the
//      composition range is tagged with the attribute via
//      ITfProperty(GUID_PROP_ATTRIBUTE)::SetValue(VT_I4 = atom),
//      where the atom is what ITfCategoryMgr::RegisterGUID hands
//      back for our display-attribute GUID.
//
// This file just declares the two helper COM objects
// (DisplayAttributeInfo and its enumerator). The TextService
// methods that bridge ITfDisplayAttributeProvider live in
// display_attribute.cpp.

#pragma once

#include <Unknwn.h>
#include <msctf.h>

#include "com_helpers.h"
#include "guids.h"

namespace burmese {

// Concrete implementation of TSF's ITfDisplayAttributeInfo for the
// single attribute we publish (the preedit underline). Stateless;
// shared across calls — TextService creates one, hands AddRef'd
// references out from EnumDisplayAttributeInfo /
// GetDisplayAttributeInfo.
class DisplayAttributeInfo final : public UnknownBase, public ITfDisplayAttributeInfo {
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) noexcept override;
    ULONG   STDMETHODCALLTYPE AddRef()  noexcept override { return UnknownBase::AddRef(); }
    ULONG   STDMETHODCALLTYPE Release() noexcept override { return UnknownBase::Release(); }

    HRESULT STDMETHODCALLTYPE GetGUID(GUID* pguid) noexcept override;
    HRESULT STDMETHODCALLTYPE GetDescription(BSTR* pbstrDesc) noexcept override;
    HRESULT STDMETHODCALLTYPE GetAttributeInfo(TF_DISPLAYATTRIBUTE* pda) noexcept override;
    HRESULT STDMETHODCALLTYPE SetAttributeInfo(const TF_DISPLAYATTRIBUTE* pda) noexcept override;
    HRESULT STDMETHODCALLTYPE Reset() noexcept override;
};

// Enumerator for the single-attribute set above. TSF asks for an
// IEnumTfDisplayAttributeInfo via
// ITfDisplayAttributeProvider::EnumDisplayAttributeInfo and walks
// it; we hand back exactly one info object.
class DisplayAttributeInfoEnum final : public UnknownBase, public IEnumTfDisplayAttributeInfo {
public:
    DisplayAttributeInfoEnum() noexcept = default;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) noexcept override;
    ULONG   STDMETHODCALLTYPE AddRef()  noexcept override { return UnknownBase::AddRef(); }
    ULONG   STDMETHODCALLTYPE Release() noexcept override { return UnknownBase::Release(); }

    HRESULT STDMETHODCALLTYPE Clone(IEnumTfDisplayAttributeInfo** out) noexcept override;
    HRESULT STDMETHODCALLTYPE Next(ULONG count, ITfDisplayAttributeInfo** out, ULONG* fetched) noexcept override;
    HRESULT STDMETHODCALLTYPE Reset() noexcept override;
    HRESULT STDMETHODCALLTYPE Skip(ULONG count) noexcept override;

private:
    bool consumed_ = false;
};

} // namespace burmese
