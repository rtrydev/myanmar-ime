// TextService — the BurmeseIME TSF text input processor.
//
// One instance per text-input context. Hosted in the COM apartment of
// the focused application. Implements the minimum surface needed for
// TSF to route keystrokes our way:
//
//   ITfTextInputProcessorEx   activation lifecycle
//   ITfThreadMgrEventSink     focus / document changes
//   ITfKeyEventSink           key down / key up
//
// On Activate it loads BurmeseIMEFFI.dll, creates a burmese engine
// handle, spins up the EngineWorker, and registers the sinks. On
// each Typeable / Backspace key it schedules an async engine update
// and returns immediately (eaten = TRUE). When the worker posts its
// result back via the message-only delivery window, we currently
// just log the JSON snapshot to OutputDebugString — composition
// rendering and the candidate window land in subsequent commits.
//
// All UI-touching state is owned by the thread that called Activate
// (the host's UI thread); the engine worker only touches its own
// coordination primitives and the FFI handle. See engine_worker.h
// for the synchronisation contract.

#pragma once

#include <Windows.h>
#include <msctf.h>

#include <memory>
#include <string>

#include "candidate_window.h"
#include "com_helpers.h"
#include "engine_worker.h"
#include "ffi_loader.h"
#include "snapshot.h"

namespace burmese {

class TextService final
    : public UnknownBase
    , public ITfTextInputProcessorEx
    , public ITfThreadMgrEventSink
    , public ITfKeyEventSink
    , public ITfCompositionSink
    , public ITfDisplayAttributeProvider {
public:
    TextService() noexcept;
    ~TextService() noexcept override;

    // IUnknown
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) noexcept override;
    ULONG   STDMETHODCALLTYPE AddRef()  noexcept override { return UnknownBase::AddRef(); }
    ULONG   STDMETHODCALLTYPE Release() noexcept override { return UnknownBase::Release(); }

    // ITfTextInputProcessor
    HRESULT STDMETHODCALLTYPE Activate(ITfThreadMgr* mgr, TfClientId cid) noexcept override;
    HRESULT STDMETHODCALLTYPE Deactivate() noexcept override;

    // ITfTextInputProcessorEx
    HRESULT STDMETHODCALLTYPE ActivateEx(ITfThreadMgr* mgr, TfClientId cid, DWORD flags) noexcept override;

    // ITfThreadMgrEventSink
    HRESULT STDMETHODCALLTYPE OnInitDocumentMgr(ITfDocumentMgr* docMgr) noexcept override;
    HRESULT STDMETHODCALLTYPE OnUninitDocumentMgr(ITfDocumentMgr* docMgr) noexcept override;
    HRESULT STDMETHODCALLTYPE OnSetFocus(ITfDocumentMgr* docMgr, ITfDocumentMgr* prev) noexcept override;
    HRESULT STDMETHODCALLTYPE OnPushContext(ITfContext* ctx) noexcept override;
    HRESULT STDMETHODCALLTYPE OnPopContext(ITfContext* ctx) noexcept override;

    // ITfKeyEventSink
    HRESULT STDMETHODCALLTYPE OnSetFocus(BOOL gained) noexcept override;
    HRESULT STDMETHODCALLTYPE OnTestKeyDown(ITfContext* ctx, WPARAM wParam, LPARAM lParam, BOOL* eaten) noexcept override;
    HRESULT STDMETHODCALLTYPE OnKeyDown(ITfContext* ctx, WPARAM wParam, LPARAM lParam, BOOL* eaten) noexcept override;
    HRESULT STDMETHODCALLTYPE OnTestKeyUp(ITfContext* ctx, WPARAM wParam, LPARAM lParam, BOOL* eaten) noexcept override;
    HRESULT STDMETHODCALLTYPE OnKeyUp(ITfContext* ctx, WPARAM wParam, LPARAM lParam, BOOL* eaten) noexcept override;
    HRESULT STDMETHODCALLTYPE OnPreservedKey(ITfContext* ctx, REFGUID guid, BOOL* eaten) noexcept override;

    // ITfCompositionSink — TSF calls this when our composition is
    // terminated by something other than us (focus loss, app
    // dismissing it). When this fires, our `composition_` pointer is
    // still valid but the composition itself is dead; clear it.
    HRESULT STDMETHODCALLTYPE OnCompositionTerminated(TfEditCookie ec, ITfComposition* composition) noexcept override;

    // ITfDisplayAttributeProvider — see display_attribute.cpp.
    HRESULT STDMETHODCALLTYPE EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** out) noexcept override;
    HRESULT STDMETHODCALLTYPE GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo** out) noexcept override;

    // The TfGuidAtom that ITfCategoryMgr::RegisterGUID hands back for
    // GUID_DisplayAttributeInput. Resolved once during Activate, then
    // referenced by composition.cpp on every SetText so the preedit
    // run gets the dotted-underline decoration.
    TfGuidAtom inputAttributeAtom() const noexcept { return inputAttributeAtom_; }

    // ---- Composition lifecycle (defined in composition.cpp) ----

    // Idempotent: starts a fresh composition if none exists, then
    // sets its text to the current `buffer_` (the raw Latin preedit).
    // Called from the keystroke path after every buffer mutation so
    // the user sees their typing land immediately, independent of
    // engine latency.
    void renderPreedit(ITfContext* ctx) noexcept;

    // Drop into an edit session, set the composition text to
    // `final_text` (UTF-8), end the composition, advance the
    // selection past the inserted text. Used by Commit (with the
    // engine's surface) and Cancel (with the raw Latin buffer as a
    // verbatim insert).
    void commitComposition(ITfContext* ctx, const std::string& final_text_utf8) noexcept;

    // End composition without touching the underlying text. Used on
    // focus loss / Deactivate when we want to leave the host alone.
    void endCompositionQuietly() noexcept;

    // Reposition the candidate window next to the active
    // composition. Opens a read-only edit session to call
    // ITfContextView::GetTextExt for the screen rectangle of the
    // composition range, then asks the window to anchor below it.
    // Safe to call when there's no composition (no-op).
    void updateCandidatePosition() noexcept;

    // Public so the message-only window class registration helper
    // (defined in an anonymous namespace in text_service.cpp) can
    // take the address. The function itself doesn't touch private
    // state — it routes to onEngineResult via GWLP_USERDATA.
    static LRESULT CALLBACK MessageWndProc(HWND, UINT, WPARAM, LPARAM) noexcept;

private:
    bool installSinks() noexcept;
    void removeSinks() noexcept;

    bool createMessageWindow() noexcept;
    void destroyMessageWindow() noexcept;

    // Determine the engine resource paths (lexicon / LM / history)
    // for the current install. Empty string for any path means "use
    // the FFI's null/empty fallback" (see ffi.h).
    void resolveResourcePaths(std::string& lexicon,
                              std::string& lm,
                              std::string& history) const;

    // Handle a single delivered engine snapshot on the TIP thread.
    // Called from the message-only window's WndProc.
    void onEngineResult();

    // Shared key-handling helper used by OnTestKeyDown and OnKeyDown.
    // Returns true when we want to eat the key; on the real-down
    // pass (test=false) also mutates the composing buffer and
    // schedules an engine update.
    bool handleKeyDown(WPARAM wParam, LPARAM lParam, bool test) noexcept;

    // Convert a (VK, shift) pair into the layout-produced ASCII
    // character via ToUnicodeEx. Returns 0 when the layout has no
    // printable mapping (function keys, etc.).
    char shiftedAscii(WPARAM vk) const noexcept;

    ComPtr<ITfThreadMgr>    threadMgr_;
    TfClientId              clientId_ = TF_CLIENTID_NULL;

    DWORD                   threadMgrCookie_  = TF_INVALID_COOKIE;
    bool                    keyEventInstalled_ = false;

    FfiLibrary              ffi_;
    EngineWorker            worker_;

    // Composing buffer: lowercased ASCII the user has typed but not
    // yet committed. Owned by the TIP thread. Drives the preedit
    // text on every keystroke.
    std::string             buffer_;

    HWND                    messageWindow_ = nullptr;

    // The context whose composition we currently own. Captured from
    // OnSetFocus(ThreadMgr); cleared when focus moves away. All
    // composition operations target this context.
    ComPtr<ITfContext>      currentContext_;
    ComPtr<ITfComposition>  composition_;

    CandidateWindow         candidateWindow_;
    // Most recent parsed snapshot. selectedIndex_ on the candidate
    // window is the source of truth for what gets committed; this
    // field exists mostly for diagnostic / future-history use.
    ParsedSnapshot          lastSnapshot_;

    // Atom for GUID_DisplayAttributeInput, registered with the TSF
    // category manager during Activate. TF_INVALID_GUIDATOM means
    // resolution failed or hasn't run — composition.cpp checks and
    // skips the SetValue call rather than painting an undecorated
    // preedit-without-fall-through.
    TfGuidAtom              inputAttributeAtom_ = TF_INVALID_GUIDATOM;
};

} // namespace burmese
