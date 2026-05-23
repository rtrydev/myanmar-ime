#include "text_service.h"

#include <Windows.h>
#include <ShlObj.h>
#include <ctfutb.h>

#include <algorithm>
#include <cstdio>
#include <string>

#include "edit_session.h"
#include "guids.h"
#include "log_file.h"

namespace burmese {

// Module handle stashed by DllMain so we can resolve sibling DLL paths
// and create windows that say "we belong to the TIP DLL." Declared in
// dllmain.cpp; just referenced here.
extern HMODULE g_module;

namespace {

constexpr wchar_t kMessageWindowClass[] = L"BurmeseIMETIP.MsgWindow";

// One-time class registration. The message-only window class is
// trivial; registration is idempotent because RegisterClassExW
// returns 0 with last-error ERROR_CLASS_ALREADY_EXISTS on a duplicate
// which we ignore.
void ensureMessageWindowClass(HMODULE module) noexcept {
    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = &TextService::MessageWndProc;
    wc.hInstance     = static_cast<HINSTANCE>(module);
    wc.lpszClassName = kMessageWindowClass;
    RegisterClassExW(&wc);   // ignore failure on duplicate
}

void dbg(const wchar_t* fmt, ...) noexcept {
    // log_line itself now mirrors every line to OutputDebugString,
    // so this thunk just forwards. Kept for call-site brevity.
    wchar_t buf[1024];
    va_list args;
    va_start(args, fmt);
    _vsnwprintf_s(buf, _TRUNCATE, fmt, args);
    va_end(args);
    log_line(L"%s", buf);
}

std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    if (n <= 0) return {};
    std::wstring w(static_cast<size_t>(n - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
    return w;
}

std::string narrow_acp(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (n <= 0) return {};
    std::string s(static_cast<size_t>(n - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, s.data(), n, nullptr, nullptr);
    return s;
}

std::wstring module_directory(HMODULE m) {
    wchar_t buf[MAX_PATH] = {0};
    DWORD n = GetModuleFileNameW(m, buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return {};
    std::wstring s(buf, n);
    auto slash = s.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return {};
    return s.substr(0, slash + 1);
}

std::wstring known_folder(REFKNOWNFOLDERID id) {
    PWSTR raw = nullptr;
    if (FAILED(SHGetKnownFolderPath(id, 0, nullptr, &raw)) || !raw) return {};
    std::wstring out(raw);
    CoTaskMemFree(raw);
    return out;
}

} // namespace

// ---- TextService ----------------------------------------------------

TextService::TextService() noexcept = default;

TextService::~TextService() noexcept {
    // Defensive: Deactivate should have been called by TSF before
    // the last Release(), but if not, tear down cleanly here so we
    // never leave a worker thread dangling.
    Deactivate();
}

HRESULT STDMETHODCALLTYPE TextService::QueryInterface(REFIID riid, void** ppv) noexcept {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (riid == IID_IUnknown
        || QueryOne<ITfTextInputProcessor>(riid, ppv, this)
        || QueryOne<ITfTextInputProcessorEx>(riid, ppv, this)
        || QueryOne<ITfThreadMgrEventSink>(riid, ppv, this)
        || QueryOne<ITfKeyEventSink>(riid, ppv, this)
        || QueryOne<ITfCompositionSink>(riid, ppv, this)
        || QueryOne<ITfDisplayAttributeProvider>(riid, ppv, this)) {
        if (!*ppv) {
            *ppv = static_cast<ITfTextInputProcessorEx*>(this);
            AddRef();
        }
        return S_OK;
    }
    // Log the IIDs TSF asks for but we don't support — useful for
    // diagnosing "TSF won't keep the TIP active" symptoms, which
    // sometimes mean TSF wanted an interface we're missing.
    log_line(L"TextService::QI E_NOINTERFACE iid={%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
             riid.Data1, riid.Data2, riid.Data3,
             riid.Data4[0], riid.Data4[1], riid.Data4[2], riid.Data4[3],
             riid.Data4[4], riid.Data4[5], riid.Data4[6], riid.Data4[7]);
    return E_NOINTERFACE;
}

// ---- Activation -----------------------------------------------------

HRESULT STDMETHODCALLTYPE TextService::Activate(ITfThreadMgr* mgr, TfClientId cid) noexcept {
    return ActivateEx(mgr, cid, 0);
}

HRESULT STDMETHODCALLTYPE TextService::ActivateEx(ITfThreadMgr* mgr, TfClientId cid, DWORD /*flags*/) noexcept {
    if (!mgr) return E_INVALIDARG;
    threadMgr_.reset();
    mgr->AddRef();
    threadMgr_.attach(mgr);
    clientId_ = cid;

    dbg(L"Activate clientId=%u", static_cast<unsigned>(cid));

    // Log thread-mgr flags so we know if we're in TSF immersive mode.
    // TF_TMF_IMMERSIVEMODE (0x40000000) being set is the signal that
    // the host is a UWP / immersive shell — that's the scenario where
    // a classic topmost popup gets composited behind the shell
    // overlay and the user can't see our candidate window.
    {
        ComPtr<ITfThreadMgrEx> mgrEx;
        if (SUCCEEDED(mgr->QueryInterface(IID_PPV_ARGS(mgrEx.put()))) && mgrEx) {
            DWORD flags = 0;
            HRESULT hr = mgrEx->GetActiveFlags(&flags);
            const bool immersive = SUCCEEDED(hr) && (flags & TF_TMF_IMMERSIVEMODE);
            immersiveMode_ = immersive;
            log_line(L"  ITfThreadMgrEx::GetActiveFlags hr=0x%08X flags=0x%08X (IMMERSIVEMODE=%d)",
                     static_cast<unsigned>(hr), flags, immersive ? 1 : 0);
        } else {
            immersiveMode_ = false;
            log_line(L"  ITfThreadMgrEx unavailable");
        }
    }

    if (!ffi_.load(g_module)) {
        dbg(L"FFI load failed: %s", ffi_.errorDetail());
        // Continue: the TIP will be inert (no engine), but staying
        // activated keeps focus tracking alive so the user can
        // diagnose via OutputDebugString without restarting.
    }

    if (!createMessageWindow()) {
        dbg(L"createMessageWindow failed (GetLastError=%u)", GetLastError());
    }

    if (!candidateWindow_.create(g_module)) {
        dbg(L"candidateWindow.create failed (GetLastError=%u)", GetLastError());
    }

    // UI-element bridge for immersive shell hosts. Optional — if the
    // host doesn't expose ITfUIElementMgr we just fall back to our
    // own HWND popup (which is fine for classic hosts; the only
    // hosts that need the UI-element protocol are the ones where
    // BeginUIElement returns bShow=FALSE).
    if (threadMgr_ && SUCCEEDED(threadMgr_->QueryInterface(
            IID_PPV_ARGS(uiElementMgr_.put())))) {
        auto* el = new (std::nothrow) CandidateUIElement();
        if (el) {
            uiElement_.attach(el);   // CandidateUIElement starts refcount=1
            // Route shell-side selection / commit / cancel through the
            // same message-only window the engine worker delivers to.
            if (messageWindow_) {
                uiElement_->setDelivery(messageWindow_, /*userParam=*/0);
            }
        }
    } else {
        log_line(L"ITfUIElementMgr unavailable — immersive hosts will not see a candidate panel");
    }

    // Resolve the GUID atom for our display attribute once. Used by
    // composition.cpp on every SetText to decorate the preedit run
    // with the dotted underline registered by display_attribute.cpp.
    {
        ComPtr<ITfCategoryMgr> catMgr;
        if (SUCCEEDED(CoCreateInstance(
                CLSID_TF_CategoryMgr, nullptr,
                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(catMgr.put())))) {
            TfGuidAtom atom = TF_INVALID_GUIDATOM;
            if (SUCCEEDED(catMgr->RegisterGUID(GUID_DisplayAttributeInput, &atom))) {
                inputAttributeAtom_ = atom;
            }
        }
        if (inputAttributeAtom_ == TF_INVALID_GUIDATOM) {
            dbg(L"display-attribute atom resolution failed; preedit will render undecorated");
        }
    }

    if (ffi_.ready() && messageWindow_) {
        std::string lex, lm, hist;
        resolveResourcePaths(lex, lm, hist);
        dbg(L"engine paths: lex='%s' lm='%s' hist='%s'",
            widen(lex).c_str(), widen(lm).c_str(), widen(hist).c_str());

        if (!worker_.start(&ffi_.table(), lex, lm, hist,
                           messageWindow_, /*delivery_user=*/0)) {
            dbg(L"engine_worker.start failed");
        } else if (!settings_.start(&worker_)) {
            dbg(L"settings.start failed; running with defaults");
        }
    }

    if (!installSinks()) {
        dbg(L"installSinks failed");
    } else {
        log_line(L"  installSinks ok (threadMgrCookie=%u keyEvent=%d)",
                 threadMgrCookie_, keyEventInstalled_ ? 1 : 0);
    }

    if (!addLangBarItem()) {
        dbg(L"addLangBarItem failed");
    } else {
        log_line(L"  addLangBarItem ok");
    }

    log_line(L"Activate returning S_OK");
    return S_OK;
}

HRESULT STDMETHODCALLTYPE TextService::Deactivate() noexcept {
    dbg(L"Deactivate");
    // End any live composition before tearing down the sinks — once
    // currentContext_ is released TSF can't deliver an
    // OnCompositionTerminated to us, but the host's view would still
    // think there's a composition open. EndComposition needs a live
    // edit session, so do it while currentContext_ is still valid.
    endCompositionQuietly();
    endCandidateUIElement();
    uiElement_.reset();
    uiElementMgr_.reset();
    candidateWindow_.destroy();
    removeLangBarItem();
    removeSinks();
    // Stop settings BEFORE the engine worker so the watcher thread
    // cannot push setting changes through a half-torn-down handle.
    settings_.stop();
    worker_.stop();
    destroyMessageWindow();
    currentContext_.reset();
    threadMgr_.reset();
    clientId_ = TF_CLIENTID_NULL;
    inputAttributeAtom_ = TF_INVALID_GUIDATOM;
    buffer_.clear();
    return S_OK;
}

// ---- Sink wiring ----------------------------------------------------

bool TextService::installSinks() noexcept {
    if (!threadMgr_) return false;

    ComPtr<ITfSource> src;
    if (FAILED(threadMgr_->QueryInterface(IID_PPV_ARGS(src.put())))) return false;

    if (threadMgrCookie_ == TF_INVALID_COOKIE) {
        if (FAILED(src->AdviseSink(IID_ITfThreadMgrEventSink,
                                   static_cast<ITfThreadMgrEventSink*>(this),
                                   &threadMgrCookie_))) {
            threadMgrCookie_ = TF_INVALID_COOKIE;
            return false;
        }
    }

    if (!keyEventInstalled_) {
        ComPtr<ITfKeystrokeMgr> ksm;
        if (FAILED(threadMgr_->QueryInterface(IID_PPV_ARGS(ksm.put())))) return false;
        if (FAILED(ksm->AdviseKeyEventSink(clientId_,
                                           static_cast<ITfKeyEventSink*>(this),
                                           TRUE))) {
            return false;
        }
        keyEventInstalled_ = true;
    }
    return true;
}

void TextService::removeSinks() noexcept {
    if (threadMgr_) {
        if (keyEventInstalled_) {
            ComPtr<ITfKeystrokeMgr> ksm;
            if (SUCCEEDED(threadMgr_->QueryInterface(IID_PPV_ARGS(ksm.put())))) {
                ksm->UnadviseKeyEventSink(clientId_);
            }
            keyEventInstalled_ = false;
        }
        if (threadMgrCookie_ != TF_INVALID_COOKIE) {
            ComPtr<ITfSource> src;
            if (SUCCEEDED(threadMgr_->QueryInterface(IID_PPV_ARGS(src.put())))) {
                src->UnadviseSink(threadMgrCookie_);
            }
            threadMgrCookie_ = TF_INVALID_COOKIE;
        }
    }
}

// ---- Message-only window for engine-result delivery ----------------

bool TextService::createMessageWindow() noexcept {
    ensureMessageWindowClass(g_module);
    messageWindow_ = CreateWindowExW(
        0, kMessageWindowClass, L"",
        0, 0, 0, 0, 0,
        HWND_MESSAGE, nullptr,
        static_cast<HINSTANCE>(g_module),
        /*lpParam=*/this);
    return messageWindow_ != nullptr;
}

void TextService::destroyMessageWindow() noexcept {
    if (messageWindow_) {
        DestroyWindow(messageWindow_);
        messageWindow_ = nullptr;
    }
}

LRESULT CALLBACK TextService::MessageWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) noexcept {
    if (msg == WM_NCCREATE) {
        auto* cs = reinterpret_cast<CREATESTRUCT*>(lParam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA,
            reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
        return TRUE;
    }
    auto* self = reinterpret_cast<TextService*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self) {
        if (msg == EngineWorker::kMessageResult) {
            self->onEngineResult();
            return 0;
        }
        if (msg == CandidateUIElement::kMessageUiSelect) {
            self->onUiSelect(static_cast<int>(lParam));
            return 0;
        }
        if (msg == CandidateUIElement::kMessageUiFinalize) {
            self->onUiFinalize();
            return 0;
        }
        if (msg == CandidateUIElement::kMessageUiAbort) {
            self->onUiAbort();
            return 0;
        }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

void TextService::onEngineResult() {
    auto snap = worker_.take_pending_result();
    if (!snap) return;
    // Stale-buffer guard: drop if the user has typed past the buffer
    // the engine ran against. Same shape as deliver_engine_result()
    // in the Linux engine.c.
    if (snap->buffer != buffer_) {
        return;
    }

    ParsedSnapshot parsed;
    if (!parseSnapshot(snap->json, parsed)) {
        dbg(L"snapshot parse failed (%zu bytes JSON)", snap->json.size());
        return;
    }
    lastSnapshot_ = std::move(parsed);
    publishCandidateSnapshot(lastSnapshot_);
}

void TextService::publishCandidateSnapshot(const ParsedSnapshot& snap) noexcept {
    const bool nonEmpty = !snap.candidates.empty();

    // ---- UI-element side (immersive shell hosts) ----
    //
    // Drive BeginUIElement / UpdateUIElement / EndUIElement off the
    // candidate-list non-empty transitions so the shell knows when
    // it has a panel open. The bShow OUT param tells us whether
    // *we* should also draw our own HWND popup on top of (or
    // instead of) the host's: TRUE means classic surface that
    // expects our popup; FALSE means immersive surface that will
    // draw its own native Win11-style panel from our data and
    // doesn't want our popup duplicating it.
    if (uiElement_ && uiElementMgr_) {
        if (nonEmpty) {
            // Always refresh the snapshot data the host will read
            // via the ITfCandidateListUIElement getters. Use ALL
            // flags as the dirty mask; setting too many is harmless
            // (the host re-queries cheap getters), setting too few
            // would leave the host showing stale candidate text.
            constexpr DWORD ALL = TF_CLUIE_DOCUMENTMGR
                                | TF_CLUIE_COUNT
                                | TF_CLUIE_SELECTION
                                | TF_CLUIE_STRING
                                | TF_CLUIE_PAGEINDEX
                                | TF_CLUIE_CURRENTPAGE;
            uiElement_->setSnapshot(snap, ALL);

            // Plumb the current doc-mgr through so the host knows
            // which document the candidate list is attached to.
            // Weak observation — see CandidateUIElement::setDocumentMgr.
            ITfDocumentMgr* dim = nullptr;
            if (currentContext_) {
                ComPtr<ITfDocumentMgr> tmp;
                if (SUCCEEDED(currentContext_->GetDocumentMgr(tmp.put())) && tmp) {
                    dim = tmp.get();
                }
            }
            uiElement_->setDocumentMgr(dim);

            if (uiElementId_ == TF_INVALID_UIELEMENTID) {
                BOOL show = TRUE;
                DWORD cookie = TF_INVALID_UIELEMENTID;
                HRESULT hr = uiElementMgr_->BeginUIElement(
                    static_cast<ITfUIElement*>(uiElement_.get()),
                    &show, &cookie);
                if (SUCCEEDED(hr)) {
                    uiElementId_       = cookie;
                    uiElementShowsOwn_ = show ? true : false;
                    log_line(L"BeginUIElement hr=0x%08X cookie=%u showOwn=%d",
                             static_cast<unsigned>(hr),
                             uiElementId_, uiElementShowsOwn_ ? 1 : 0);
                } else {
                    log_line(L"BeginUIElement failed hr=0x%08X — falling back to own HWND",
                             static_cast<unsigned>(hr));
                    uiElementShowsOwn_ = true;
                }
            } else {
                HRESULT hr = uiElementMgr_->UpdateUIElement(uiElementId_);
                if (FAILED(hr)) {
                    log_line(L"UpdateUIElement hr=0x%08X", static_cast<unsigned>(hr));
                }
            }
        } else {
            endCandidateUIElement();
        }
    }

    // ---- Our own HWND popup (classic hosts and fallback) ----
    if (!nonEmpty || uiElementShowsOwn_) {
        candidateWindow_.setCandidates(snap);
        if (candidateWindow_.isVisible()) {
            updateCandidatePosition();
        }
    } else {
        // Immersive host wants to draw its own; suppress ours so
        // we don't ship a duplicate panel behind theirs.
        candidateWindow_.hide();
    }

    // ---- Immersive-mode inline preedit override ----
    //
    // In immersive hosts (Win11 Search Bar / UWP) our HWND popup is
    // composited behind the shell's XAML surface and invisible —
    // confirmed by exhaustive category bisection 0.1.21–0.1.24, the
    // shell-renders path is gated on a Microsoft-internal mechanism
    // (likely a LANGID whitelist for East-Asian IMEs). Fallback
    // model: latin preedit is the default view (matches what
    // classic hosts show when the candidate panel is visible);
    // Space commits the top candidate. Nav keys cycle and switch
    // the preedit to the selected candidate's Burmese surface so
    // the user can see what they'll commit. immersiveShowingSelection_
    // is the toggle — set by refreshImmersivePreedit() in the Nav
    // path, cleared by any buffer mutation / commit / cancel.
    if (immersiveMode_ && immersiveShowingSelection_ && nonEmpty && currentContext_) {
        const int sel = std::clamp(snap.selected, 0,
                                   static_cast<int>(snap.candidates.size()) - 1);
        std::wstring surface = widen(snap.candidates[static_cast<size_t>(sel)].surface);
        if (!surface.empty()) {
            renderPreedit(currentContext_.get(), &surface);
        }
    }
}

void TextService::endCandidateUIElement() noexcept {
    if (uiElementId_ != TF_INVALID_UIELEMENTID && uiElementMgr_) {
        HRESULT hr = uiElementMgr_->EndUIElement(uiElementId_);
        log_line(L"EndUIElement cookie=%u hr=0x%08X",
                 uiElementId_, static_cast<unsigned>(hr));
    }
    uiElementId_       = TF_INVALID_UIELEMENTID;
    uiElementShowsOwn_ = true;
    if (uiElement_) uiElement_->setDocumentMgr(nullptr);
}

void TextService::hideCandidatePanel() noexcept {
    endCandidateUIElement();
    candidateWindow_.hide();
    immersiveShowingSelection_ = false;
}

void TextService::refreshImmersivePreedit() noexcept {
    if (!immersiveMode_ || !currentContext_) return;
    if (lastSnapshot_.candidates.empty()) return;
    const int total = static_cast<int>(lastSnapshot_.candidates.size());
    const int sel = std::clamp(candidateWindow_.selectedIndex(), 0, total - 1);
    std::wstring surface = widen(lastSnapshot_.candidates[static_cast<size_t>(sel)].surface);
    if (surface.empty()) return;
    // Flip the toggle so a follow-up engine result (e.g. the user
    // keeps cycling and another snapshot arrives) keeps showing the
    // selected candidate's surface instead of reverting to latin.
    immersiveShowingSelection_ = true;
    renderPreedit(currentContext_.get(), &surface);
}

// Shell selected a different candidate (clicked a row, used arrow
// keys inside its own panel). Mirror it into our local selection
// state so a subsequent commit picks up the right surface, and
// push it to the engine immediately so any commit-on-space the
// shell drives lands on the right entry.
void TextService::onUiSelect(int index) noexcept {
    log_line(L"onUiSelect index=%d", index);
    if (index < 0) return;
    if (lastSnapshot_.candidates.empty()) return;
    const int clamped = (std::min)(index,
                                   static_cast<int>(lastSnapshot_.candidates.size()) - 1);
    lastSnapshot_.selected = clamped;
    candidateWindow_.setCandidates(lastSnapshot_);   // updates internal selectedIndex_
    worker_.drain_and_wait_idle();
    worker_.sync_update_buffer(buffer_);
    worker_.set_selected_sync(clamped);
}

// Shell finalized the selection — equivalent to user pressing Space
// in our keymap. Same shape as KeymapAction::Commit in
// key_event_sink.cpp's handleKeyDown.
void TextService::onUiFinalize() noexcept {
    log_line(L"onUiFinalize buffer='%hs'", buffer_.c_str());
    if (buffer_.empty() || !currentContext_) return;
    worker_.drain_and_wait_idle();
    worker_.sync_update_buffer(buffer_);
    if (candidateWindow_.candidateCount() > 0) {
        worker_.set_selected_sync(candidateWindow_.selectedIndex());
    }
    std::string surface = worker_.commit_sync();
    if (!surface.empty()) {
        worker_.record_selection_sync();
        worker_.push_committed_context_sync(surface);
        commitComposition(currentContext_.get(), surface);
    } else {
        endCompositionQuietly();
    }
    hideCandidatePanel();
    buffer_.clear();
}

// Shell aborted the conversion (Esc inside its panel, focus loss,
// etc.). Mirrors KeymapAction::Cancel — commit the raw Latin
// buffer verbatim so the user's keystrokes don't vanish.
void TextService::onUiAbort() noexcept {
    log_line(L"onUiAbort buffer='%hs'", buffer_.c_str());
    if (buffer_.empty() || !currentContext_) return;
    worker_.drain_and_wait_idle();
    (void)worker_.cancel_sync();
    std::string raw = buffer_;
    commitComposition(currentContext_.get(), raw);
    hideCandidatePanel();
    buffer_.clear();
}

void TextService::updateCandidatePosition() noexcept {
    if (!candidateWindow_.isVisible()) return;
    if (!currentContext_ || !composition_) return;

    ITfContext* ctxRaw = currentContext_.get();
    runEditSession(ctxRaw, clientId_, TF_ES_SYNC | TF_ES_READ,
        [this, ctxRaw](TfEditCookie ec) -> HRESULT {
            ComPtr<ITfContextView> view;
            HRESULT hr = ctxRaw->GetActiveView(view.put());
            if (FAILED(hr) || !view) return hr;

            ComPtr<ITfRange> range;
            if (FAILED(composition_->GetRange(range.put())) || !range) {
                return E_FAIL;
            }
            RECT rc{};
            BOOL clipped = FALSE;
            hr = view->GetTextExt(ec, range.get(), &rc, &clipped);
            if (FAILED(hr)) {
                // Some hosts (rich web editors, some Office views,
                // and notably the Win11 Start Menu / Search Bar)
                // return TF_E_NOLAYOUT during or before a layout
                // pass. The candidate window stays where it last
                // anchored — setCandidates re-asserts HWND_TOPMOST
                // unconditionally so the panel is still on-screen,
                // just not next to the caret. The next engine
                // result will retry.
                log_line(L"updateCandidatePosition GetTextExt failed hr=0x%08X",
                         static_cast<unsigned>(hr));
                return S_OK;
            }
            log_line(L"updateCandidatePosition GetTextExt ok rect=(%d,%d %dx%d)",
                     rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top);
            candidateWindow_.setPositionBelow(rc);
            return S_OK;
        });
}

// ---- Engine resource paths -----------------------------------------

void TextService::resolveResourcePaths(std::string& lexicon,
                                       std::string& lm,
                                       std::string& history) const {
    lexicon.clear();
    lm.clear();
    history.clear();

    // Production install: %ProgramFiles%\Myangler\Data\ next to the
    // TIP DLL. Dev override: env var MYANGLER_DATA_DIR (mirrors the
    // IBus engine convention).
    std::wstring dataDir;
    wchar_t envBuf[1024]{};
    DWORD n = GetEnvironmentVariableW(L"MYANGLER_DATA_DIR", envBuf, 1024);
    if (n > 0 && n < 1024) {
        dataDir = envBuf;
        if (!dataDir.empty() && dataDir.back() != L'\\' && dataDir.back() != L'/') {
            dataDir.push_back(L'\\');
        }
    } else {
        std::wstring modDir = module_directory(g_module);
        if (!modDir.empty()) dataDir = modDir + L"Data\\";
    }
    if (!dataDir.empty()) {
        std::wstring lexW  = dataDir + L"BurmeseLexicon.sqlite";
        std::wstring lmW   = dataDir + L"BurmeseLM.bin";
        if (GetFileAttributesW(lexW.c_str()) != INVALID_FILE_ATTRIBUTES) {
            lexicon = narrow_acp(lexW);
        }
        if (GetFileAttributesW(lmW.c_str()) != INVALID_FILE_ATTRIBUTES) {
            lm = narrow_acp(lmW);
        }
    }

    // History: %LOCALAPPDATA%\Myangler\UserHistory.sqlite. The FFI
    // creates the parent directory if needed.
    std::wstring local = known_folder(FOLDERID_LocalAppData);
    if (!local.empty()) {
        std::wstring historyW = local + L"\\Myangler\\UserHistory.sqlite";
        history = narrow_acp(historyW);
    }
}

// ---- ITfThreadMgrEventSink -----------------------------------------

HRESULT STDMETHODCALLTYPE TextService::OnInitDocumentMgr(ITfDocumentMgr* docMgr) noexcept {
    log_line(L"OnInitDocumentMgr docMgr=%p", static_cast<void*>(docMgr));
    return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnUninitDocumentMgr(ITfDocumentMgr* docMgr) noexcept {
    log_line(L"OnUninitDocumentMgr docMgr=%p", static_cast<void*>(docMgr));
    return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnSetFocus(ITfDocumentMgr* docMgr, ITfDocumentMgr*) noexcept {
    dbg(L"thread_mgr OnSetFocus docMgr=%p", static_cast<void*>(docMgr));

    // Focus is leaving the previous context. Commit whatever the user
    // had typed, mirroring the macOS controller's
    // commitComposition(_:) and the IBus engine's focus_out handler —
    // a half-typed buffer must not vanish silently.
    if (!buffer_.empty() && currentContext_) {
        worker_.drain_and_wait_idle();
        worker_.sync_update_buffer(buffer_);
        if (candidateWindow_.isVisible()
            && candidateWindow_.candidateCount() > 0) {
            worker_.set_selected_sync(candidateWindow_.selectedIndex());
        }
        std::string surface = worker_.commit_sync();
        if (!surface.empty()) {
            worker_.record_selection_sync();
            worker_.push_committed_context_sync(surface);
            commitComposition(currentContext_.get(), surface);
        } else {
            // Engine gave us nothing — drop composition without
            // forcing text into the host.
            endCompositionQuietly();
        }
        buffer_.clear();
    } else if (composition_) {
        endCompositionQuietly();
    }
    hideCandidatePanel();

    currentContext_.reset();
    if (docMgr) {
        ComPtr<ITfContext> ctx;
        if (SUCCEEDED(docMgr->GetTop(ctx.put())) && ctx) {
            currentContext_ = std::move(ctx);
        }
    }
    return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnPushContext(ITfContext* ctx) noexcept {
    log_line(L"OnPushContext ctx=%p", static_cast<void*>(ctx));
    return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnPopContext(ITfContext* ctx) noexcept {
    log_line(L"OnPopContext ctx=%p", static_cast<void*>(ctx));
    return S_OK;
}

// ---- Compose/Roman langbar item ----------------------------------

bool TextService::addLangBarItem() noexcept {
    if (!threadMgr_ || langBarAdded_) return langBarAdded_;

    ComPtr<ITfLangBarItemMgr> mgr;
    if (FAILED(threadMgr_->QueryInterface(IID_PPV_ARGS(mgr.put()))) || !mgr) {
        return false;
    }

    auto* btn = new (std::nothrow) ComposeButton(
        [this](bool composeEnabled) { onComposeToggled(composeEnabled); });
    if (!btn) return false;
    composeButton_.attach(btn);

    HRESULT hr = mgr->AddItem(composeButton_.get());
    if (FAILED(hr)) {
        composeButton_.reset();
        return false;
    }
    langBarAdded_ = true;
    return true;
}

void TextService::removeLangBarItem() noexcept {
    if (!langBarAdded_ || !threadMgr_) {
        composeButton_.reset();
        langBarAdded_ = false;
        return;
    }
    ComPtr<ITfLangBarItemMgr> mgr;
    if (SUCCEEDED(threadMgr_->QueryInterface(IID_PPV_ARGS(mgr.put()))) && mgr
        && composeButton_) {
        mgr->RemoveItem(composeButton_.get());
    }
    composeButton_.reset();
    langBarAdded_ = false;
}

void TextService::onComposeToggled(bool composeEnabled) noexcept {
    composeEnabled_ = composeEnabled;
    if (!composeEnabled_) {
        // Switching to Roman mode while composing — commit whatever
        // the user has typed so the half-typed buffer doesn't sit
        // around invisibly waiting for a Space press that the user
        // won't make (Space is now a passthrough).
        if (!buffer_.empty() && currentContext_) {
            worker_.drain_and_wait_idle();
            worker_.sync_update_buffer(buffer_);
            if (candidateWindow_.isVisible()
                && candidateWindow_.candidateCount() > 0) {
                worker_.set_selected_sync(candidateWindow_.selectedIndex());
            }
            std::string surface = worker_.commit_sync();
            if (!surface.empty()) {
                worker_.record_selection_sync();
                worker_.push_committed_context_sync(surface);
                commitComposition(currentContext_.get(), surface);
            } else {
                endCompositionQuietly();
            }
            buffer_.clear();
        }
        hideCandidatePanel();
    }
}

} // namespace burmese
