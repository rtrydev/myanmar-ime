// ITfKeyEventSink members of TextService. Kept in a separate file from
// text_service.cpp so the COM scaffolding stays focused on lifecycle
// and this file stays focused on the keystroke -> engine dispatch.
//
// Architectural rules (the same ones engine.c and the macOS controller
// follow):
//
//   * Synchronous "consumed" answer to OnKeyDown so the host UI thread
//     never blocks on the engine.
//   * Typeable / Backspace mutate the composing buffer and schedule an
//     async engine update; the result lands later via the message-
//     only delivery window.
//   * Commit / Cancel drain the worker then synchronously commit or
//     cancel against the engine.
//   * Modifier-held shortcuts (Ctrl/Alt) are passed through to the
//     host unchanged.
//
// Composition rendering and the candidate window are deferred. For
// this milestone the engine output is logged via OutputDebugString
// inside TextService::onEngineResult; the buffer mutation logic here
// is the production-final shape ready to drive the preedit once
// composition lands.

#include "text_service.h"

#include <Windows.h>
#include "keymap.h"

namespace burmese {

namespace {

uint32_t current_modifiers() noexcept {
    uint32_t m = 0;
    if (GetKeyState(VK_SHIFT)   & 0x8000) m |= kModShift;
    if (GetKeyState(VK_CONTROL) & 0x8000) m |= kModCtrl;
    // Alt under TSF: VK_MENU corresponds to either Alt key. The
    // distinction between Alt and AltGr (right-Alt as Ctrl+Alt on
    // some layouts) is left to GetKeyboardState below if we need it.
    if (GetKeyState(VK_MENU)    & 0x8000) m |= kModAlt;
    return m;
}

} // namespace

char TextService::shiftedAscii(WPARAM vk) const noexcept {
    BYTE state[256]{};
    GetKeyboardState(state);
    wchar_t out[4]{};
    HKL layout = GetKeyboardLayout(0);
    // ToUnicodeEx with a dead-key-safe flag set so a previous dead
    // key isn't consumed by our peek. We rely on the layout state we
    // just read; that's the application's view at the moment of
    // OnKeyDown.
    int n = ToUnicodeEx(
        static_cast<UINT>(vk),
        /*scanCode=*/0,
        state,
        out,
        static_cast<int>(std::size(out)),
        /*flags=*/2,        // dead-key non-consuming
        layout);
    if (n != 1) return 0;
    auto c = static_cast<unsigned int>(out[0]);
    if (c >= 0x20 && c < 0x7F) return static_cast<char>(c);
    return 0;
}

bool TextService::handleKeyDown(WPARAM vk, LPARAM /*lParam*/, bool test) noexcept {
    if (!worker_.running()) return false;

    const uint32_t mods = current_modifiers();
    const char shifted  = shiftedAscii(vk);

    const KeymapResult km = keymap_map(
        static_cast<uint32_t>(vk), mods, shifted);

    switch (km.action) {
        case KeymapAction::Ignore:
        case KeymapAction::Modifier:
            return false;

        case KeymapAction::Typeable: {
            if (test) return true;
            buffer_.push_back(km.typed_char);
            // Render preedit BEFORE scheduling the async engine
            // update so the user always sees their typing land
            // immediately, even if the engine is busy. This is the
            // synchronous-preedit invariant from CLAUDE.md.
            renderPreedit(currentContext_.get());
            worker_.schedule_update(buffer_);
            return true;
        }
        case KeymapAction::Backspace: {
            if (buffer_.empty()) return false;
            if (test) return true;
            buffer_.pop_back();
            renderPreedit(currentContext_.get());
            if (buffer_.empty()) {
                // Whole composition gone. Drop pending work and
                // reset the engine state immediately so the next
                // keystroke starts clean. Same shape as engine.c's
                // empty-buffer backspace branch.
                worker_.drain_and_wait_idle();
                worker_.schedule_update(buffer_);
                candidateWindow_.hide();
            } else {
                worker_.schedule_update(buffer_);
            }
            return true;
        }
        case KeymapAction::Commit: {
            if (buffer_.empty()) return false;
            if (test) return true;
            // Bring the engine current (drain only cancels pending
            // work; the engine may still be one keystroke behind the
            // latest buffer_). Push the user's panel selection into
            // the engine before reading the commit surface so the
            // chosen candidate (not just rank 0) is what gets
            // committed and recorded as history.
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
            candidateWindow_.hide();
            buffer_.clear();
            return true;
        }
        case KeymapAction::Cancel: {
            if (buffer_.empty()) return false;
            if (test) return true;
            // Escape semantics from the macOS controller: commit the
            // raw Latin buffer verbatim. cancel_sync resets engine
            // composition state but doesn't insert anywhere; we
            // bypass it and write buffer_ via the composition.
            worker_.drain_and_wait_idle();
            (void)worker_.cancel_sync();
            std::string raw = buffer_;
            commitComposition(currentContext_.get(), raw);
            candidateWindow_.hide();
            buffer_.clear();
            return true;
        }
        case KeymapAction::NavUp:
            if (!candidateWindow_.isVisible()) return false;
            if (test) return true;
            candidateWindow_.moveUp();
            return true;
        case KeymapAction::NavDown:
            if (!candidateWindow_.isVisible()) return false;
            if (test) return true;
            candidateWindow_.moveDown();
            return true;
        case KeymapAction::NavPageUp:
            if (!candidateWindow_.isVisible()) return false;
            if (test) return true;
            candidateWindow_.pageUp();
            return true;
        case KeymapAction::NavPageDown:
            if (!candidateWindow_.isVisible()) return false;
            if (test) return true;
            candidateWindow_.pageDown();
            return true;
        case KeymapAction::NavHome:
        case KeymapAction::NavEnd:
            // Not part of the macOS / Linux keymap surface. Pass
            // through so the host's caret-navigation semantics work.
            return false;
    }
    return false;
}

// ---- ITfKeyEventSink -----------------------------------------------

HRESULT STDMETHODCALLTYPE TextService::OnSetFocus(BOOL gained) noexcept {
    // The ThreadMgrEventSink's OnSetFocus is the authoritative
    // focus-change hook for us — it gives us the new docMgr and is
    // already where we run the commit-on-focus-loss sequence.
    // The KeyEventSink's OnSetFocus is informational and fires on
    // input-language enable/disable plus focus changes; mostly we
    // just need to ignore it here. Logged in case it surfaces useful
    // patterns during dev.
    (void)gained;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE TextService::OnTestKeyDown(ITfContext*, WPARAM wParam, LPARAM lParam, BOOL* eaten) noexcept {
    if (!eaten) return E_POINTER;
    *eaten = handleKeyDown(wParam, lParam, /*test=*/true) ? TRUE : FALSE;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE TextService::OnKeyDown(ITfContext*, WPARAM wParam, LPARAM lParam, BOOL* eaten) noexcept {
    if (!eaten) return E_POINTER;
    *eaten = handleKeyDown(wParam, lParam, /*test=*/false) ? TRUE : FALSE;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE TextService::OnTestKeyUp(ITfContext*, WPARAM, LPARAM, BOOL* eaten) noexcept {
    if (!eaten) return E_POINTER;
    *eaten = FALSE;
    return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnKeyUp(ITfContext*, WPARAM, LPARAM, BOOL* eaten) noexcept {
    if (!eaten) return E_POINTER;
    *eaten = FALSE;
    return S_OK;
}
HRESULT STDMETHODCALLTYPE TextService::OnPreservedKey(ITfContext*, REFGUID, BOOL* eaten) noexcept {
    if (!eaten) return E_POINTER;
    *eaten = FALSE;
    return S_OK;
}

} // namespace burmese
