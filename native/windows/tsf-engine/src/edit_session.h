// Lambda-driven ITfEditSession.
//
// TSF only lets a TIP mutate document state from inside an "edit
// session" — the TIP asks the context for one via RequestEditSession,
// and TSF eventually invokes the session's DoEditSession callback
// with a TfEditCookie that authorises read or read/write access for
// its duration. The typical pattern is one .cpp class per operation
// (start composition, update text, end composition), which is loud.
//
// EditSession<Fn> wraps an arbitrary callable so each call site
// becomes a one-liner:
//
//   runEditSession(ctx, clientId, TF_ES_SYNC | TF_ES_READWRITE,
//       [&](TfEditCookie ec) -> HRESULT { ... });
//
// Synchronous + read/write is what every composition update wants.
// Some hosts (notably web views and a handful of UWP edit controls)
// reject TF_ES_SYNC; runEditSession falls back to TF_ES_ASYNC in that
// case so the operation still happens — just on TSF's schedule.

#pragma once

#include <Windows.h>
#include <msctf.h>

#include <utility>

#include "com_helpers.h"

namespace burmese {

template <typename Fn>
class EditSession final : public UnknownBase, public ITfEditSession {
public:
    explicit EditSession(Fn fn) noexcept(noexcept(Fn(std::move(fn))))
        : fn_(std::move(fn)) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) noexcept override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (riid == IID_IUnknown || riid == IID_ITfEditSession) {
            *ppv = static_cast<ITfEditSession*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef()  noexcept override { return UnknownBase::AddRef(); }
    ULONG STDMETHODCALLTYPE Release() noexcept override { return UnknownBase::Release(); }

    HRESULT STDMETHODCALLTYPE DoEditSession(TfEditCookie ec) noexcept override {
        return fn_(ec);
    }

private:
    Fn fn_;
};

// Run `fn` inside an edit session on `ctx`. Tries `flags` first
// (typically TF_ES_SYNC | TF_ES_READWRITE); on TF_E_SYNCHRONOUS — the
// host refusing synchronous access — falls back to TF_ES_ASYNC with
// the same access mask so the operation still completes (eventually).
template <typename Fn>
HRESULT runEditSession(ITfContext* ctx, TfClientId clientId, DWORD flags, Fn fn) {
    if (!ctx) return E_INVALIDARG;
    auto* session = new (std::nothrow) EditSession<Fn>(std::move(fn));
    if (!session) return E_OUTOFMEMORY;

    HRESULT hrSession = S_OK;
    HRESULT hr = ctx->RequestEditSession(clientId, session, flags, &hrSession);

    if (hr == TF_E_SYNCHRONOUS && (flags & TF_ES_SYNC)) {
        const DWORD asyncFlags = (flags & ~TF_ES_SYNC) | TF_ES_ASYNC;
        hr = ctx->RequestEditSession(clientId, session, asyncFlags, &hrSession);
    }

    session->Release();
    return SUCCEEDED(hr) ? hrSession : hr;
}

} // namespace burmese
