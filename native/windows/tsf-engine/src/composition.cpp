// Composition lifecycle for the BurmeseIME TIP.
//
// Three operations:
//
//   * renderPreedit       — start or update the inline composition
//                           with the current raw Latin buffer_. Runs
//                           after every keystroke; the user sees their
//                           typing land immediately, regardless of
//                           engine latency. Idempotent: starts a new
//                           composition only if none exists.
//
//   * commitComposition   — replace the composition's text with the
//                           final string (engine surface on Commit,
//                           raw buffer on Cancel), move the selection
//                           past it, end the composition.
//
//   * endCompositionQuietly — close the composition without touching
//                             text. Used on Deactivate when we don't
//                             have permission to alter the document
//                             and just need to stop owning the range.
//
// All three open a TF_ES_SYNC | TF_ES_READWRITE edit session via the
// EditSession helper, which falls back to TF_ES_ASYNC if the host
// refuses sync access. ITfCompositionSink::OnCompositionTerminated
// catches the case where TSF tears down our composition for us (focus
// loss inside the same docMgr, app dismissing IME, etc).
//
// Display-attribute decoration (the underline that distinguishes
// preedit from committed text) lands in a follow-up commit alongside
// ITfDisplayAttributeProvider; without it the preedit renders as
// regular text — visually less obvious but functionally correct.

#include "text_service.h"

#include <Windows.h>
#include <msctf.h>

#include "edit_session.h"

namespace burmese {

namespace {

void dbg_composition(const wchar_t* what) noexcept {
    OutputDebugStringW(L"[BurmeseIMETIP composition] ");
    OutputDebugStringW(what);
    OutputDebugStringW(L"\n");
}

std::wstring widen_utf8(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    if (n <= 0) return {};
    std::wstring w(static_cast<size_t>(n - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
    return w;
}

// Set the composition's text to `text` and advance the selection so
// the caret sits at the end of the inserted run. Caller is inside an
// edit session and `composition` is non-null.
HRESULT setCompositionTextAndCaret(TfEditCookie ec,
                                   ITfContext*      ctx,
                                   ITfComposition*  composition,
                                   const std::wstring& text) {
    ComPtr<ITfRange> range;
    HRESULT hr = composition->GetRange(range.put());
    if (FAILED(hr) || !range) return hr;

    hr = range->SetText(
        ec,
        TF_ST_CORRECTION,                       // do not fire on-change for IME's own update
        text.empty() ? L"" : text.c_str(),
        static_cast<LONG>(text.size()));
    if (FAILED(hr)) return hr;

    // Move the caret to the end of the composition so what the user
    // typed appears with the insertion point just past it.
    ComPtr<ITfRange> tail;
    hr = range->Clone(tail.put());
    if (FAILED(hr) || !tail) return hr;
    tail->Collapse(ec, TF_ANCHOR_END);

    TF_SELECTION sel{};
    sel.range = tail.get();
    sel.style.ase = TF_AE_END;
    sel.style.fInterimChar = FALSE;
    return ctx->SetSelection(ec, 1, &sel);
}

} // namespace

// ---- Composition operations ----------------------------------------

void TextService::renderPreedit(ITfContext* ctx) noexcept {
    if (!ctx) return;
    const std::wstring preedit = widen_utf8(buffer_);

    runEditSession(ctx, clientId_, TF_ES_SYNC | TF_ES_READWRITE,
        [this, ctx, preedit](TfEditCookie ec) -> HRESULT {
            // Start composition lazily on the first keystroke after
            // an empty buffer. We do NOT start composition for empty
            // preedit text — empty composition is a UX irritant in
            // some hosts (extra cursor flicker) and we end up tearing
            // it down on the very next backspace anyway.
            if (!composition_ && preedit.empty()) return S_OK;

            if (!composition_) {
                ComPtr<ITfInsertAtSelection> ias;
                if (FAILED(ctx->QueryInterface(IID_PPV_ARGS(ias.put())))
                    || !ias) {
                    return E_FAIL;
                }
                ComPtr<ITfRange> insertRange;
                if (FAILED(ias->InsertTextAtSelection(
                        ec, TF_IAS_QUERYONLY, L"", 0, insertRange.put()))
                    || !insertRange) {
                    return E_FAIL;
                }

                ComPtr<ITfContextComposition> compMgr;
                if (FAILED(ctx->QueryInterface(IID_PPV_ARGS(compMgr.put())))
                    || !compMgr) {
                    return E_FAIL;
                }

                ITfComposition* raw = nullptr;
                HRESULT hr = compMgr->StartComposition(
                    ec, insertRange.get(),
                    static_cast<ITfCompositionSink*>(this),
                    &raw);
                if (FAILED(hr) || !raw) return hr;
                composition_.attach(raw);
            }

            return setCompositionTextAndCaret(ec, ctx, composition_.get(), preedit);
        });
}

void TextService::commitComposition(ITfContext* ctx, const std::string& final_utf8) noexcept {
    if (!ctx) return;
    const std::wstring final_text = widen_utf8(final_utf8);

    runEditSession(ctx, clientId_, TF_ES_SYNC | TF_ES_READWRITE,
        [this, ctx, final_text](TfEditCookie ec) -> HRESULT {
            if (!composition_) {
                // No active composition — fall through and insert at
                // the current selection directly so the surface still
                // reaches the document. Mirrors the IBus engine's
                // commit_selected when there was no preedit yet.
                ComPtr<ITfInsertAtSelection> ias;
                if (FAILED(ctx->QueryInterface(IID_PPV_ARGS(ias.put())))
                    || !ias) {
                    return E_FAIL;
                }
                ComPtr<ITfRange> dummy;
                return ias->InsertTextAtSelection(
                    ec, 0,
                    final_text.empty() ? L"" : final_text.c_str(),
                    static_cast<LONG>(final_text.size()),
                    dummy.put());
            }

            HRESULT hr = setCompositionTextAndCaret(
                ec, ctx, composition_.get(), final_text);
            // End composition even if SetText failed — keeping a
            // dangling composition open is worse than dropping a
            // failed replacement.
            composition_->EndComposition(ec);
            composition_.reset();
            return hr;
        });
}

void TextService::endCompositionQuietly() noexcept {
    if (!composition_ || !currentContext_) {
        composition_.reset();
        return;
    }
    ITfContext* ctx = currentContext_.get();
    runEditSession(ctx, clientId_, TF_ES_SYNC | TF_ES_READWRITE,
        [this](TfEditCookie ec) -> HRESULT {
            if (composition_) {
                composition_->EndComposition(ec);
                composition_.reset();
            }
            return S_OK;
        });
}

HRESULT STDMETHODCALLTYPE TextService::OnCompositionTerminated(
    TfEditCookie /*ec*/, ITfComposition* /*composition*/) noexcept {
    dbg_composition(L"OnCompositionTerminated");
    composition_.reset();
    // Buffer cleared too — if the host tore the composition out from
    // under us, anything we still have in buffer_ no longer
    // corresponds to text the user can see, and continuing to feed
    // the engine for it would just produce ghost updates.
    buffer_.clear();
    return S_OK;
}

} // namespace burmese
