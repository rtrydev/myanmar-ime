#include "class_factory.h"

#include "text_service.h"

namespace burmese {

// Process-wide reference count for DllCanUnloadNow. Bumped by
// LockServer(TRUE) and by every TextService construction; decremented
// on the matching release. When zero, COM may unload the DLL.
extern long g_dll_ref_count;

HRESULT STDMETHODCALLTYPE TextServiceFactory::QueryInterface(REFIID riid, void** ppv) noexcept {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (riid == IID_IUnknown
        || QueryOne<IClassFactory>(riid, ppv, this)) {
        if (!*ppv) {
            *ppv = static_cast<IClassFactory*>(this);
            AddRef();
        }
        return S_OK;
    }
    return E_NOINTERFACE;
}

HRESULT STDMETHODCALLTYPE TextServiceFactory::CreateInstance(IUnknown* outer, REFIID riid, void** ppv) noexcept {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (outer) return CLASS_E_NOAGGREGATION;

    auto* svc = new (std::nothrow) TextService();
    if (!svc) return E_OUTOFMEMORY;
    InterlockedIncrement(&g_dll_ref_count);

    const HRESULT hr = svc->QueryInterface(riid, ppv);
    svc->Release();        // QueryInterface AddRef'd; balance the new
    if (FAILED(hr)) {
        // QueryInterface failure means *ppv stays null; the matching
        // dll-ref decrement happens here since no caller owns one.
        InterlockedDecrement(&g_dll_ref_count);
    }
    return hr;
}

HRESULT STDMETHODCALLTYPE TextServiceFactory::LockServer(BOOL lock) noexcept {
    if (lock) {
        InterlockedIncrement(&g_dll_ref_count);
    } else {
        InterlockedDecrement(&g_dll_ref_count);
    }
    return S_OK;
}

} // namespace burmese
