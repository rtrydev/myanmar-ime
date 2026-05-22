// IClassFactory for the BurmeseIME text service CLSID. DllGetClassObject
// returns one of these; TSF then asks it to CreateInstance our
// TextService class. The factory itself is stateless and lives as a
// process-wide singleton — there's no per-call state to track.

#pragma once

#include <Unknwn.h>

#include "com_helpers.h"

namespace burmese {

class TextServiceFactory final : public UnknownBase, public IClassFactory {
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) noexcept override;
    ULONG   STDMETHODCALLTYPE AddRef()  noexcept override { return UnknownBase::AddRef(); }
    ULONG   STDMETHODCALLTYPE Release() noexcept override { return UnknownBase::Release(); }

    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID riid, void** ppv) noexcept override;
    HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) noexcept override;
};

} // namespace burmese
