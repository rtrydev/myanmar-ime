#include "text_service.h"

#include <Windows.h>
#include <ShlObj.h>
#include <ctfutb.h>

#include <cstdio>
#include <string>

#include "edit_session.h"
#include "guids.h"

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
    wchar_t buf[1024];
    va_list args;
    va_start(args, fmt);
    _vsnwprintf_s(buf, _TRUNCATE, fmt, args);
    va_end(args);
    OutputDebugStringW(L"[BurmeseIMETIP] ");
    OutputDebugStringW(buf);
    OutputDebugStringW(L"\n");
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
        }
    }

    if (!installSinks()) {
        dbg(L"installSinks failed");
        // Best-effort: keep going. TSF can re-enter Activate after a
        // failed sink install in some flows; cleaning up half-state
        // here can cause hard-to-diagnose follow-on errors.
    }

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
    candidateWindow_.destroy();
    removeSinks();
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
    if (self && msg == EngineWorker::kMessageResult) {
        self->onEngineResult();
        return 0;
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
    candidateWindow_.setCandidates(lastSnapshot_);
    if (candidateWindow_.isVisible()) {
        updateCandidatePosition();
    }
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
                // Some hosts (rich web editors, some Office views)
                // return TF_E_NOLAYOUT during a layout pass. Skip
                // silently — the next engine result will retry.
                return S_OK;
            }
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

HRESULT STDMETHODCALLTYPE TextService::OnInitDocumentMgr(ITfDocumentMgr*) noexcept {
    return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnUninitDocumentMgr(ITfDocumentMgr*) noexcept {
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
    candidateWindow_.hide();

    currentContext_.reset();
    if (docMgr) {
        ComPtr<ITfContext> ctx;
        if (SUCCEEDED(docMgr->GetTop(ctx.put())) && ctx) {
            currentContext_ = std::move(ctx);
        }
    }
    return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnPushContext(ITfContext*) noexcept { return S_OK; }
HRESULT STDMETHODCALLTYPE TextService::OnPopContext(ITfContext*) noexcept  { return S_OK; }

} // namespace burmese
