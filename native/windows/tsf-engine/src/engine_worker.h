// Per-engine async dispatch — direct translation of the worker thread
// in `native/linux/ibus-engine/src/engine.c`. Goal: a slow per-
// keystroke burmese_engine_update must never block the TSF
// ITfKeyEventSink::OnKeyDown return — the host's UI thread is on the
// hook for that callback.
//
// The shape is identical to the Linux version, with Win32 primitives
// in place of the GLib ones:
//
//   IBus / Linux                    Windows
//   ------------------------------  --------------------------------
//   GMutex worker_mutex             SRWLOCK worker_lock_
//   GCond  worker_cond              CONDITION_VARIABLE work_pending_
//   GCond  idle_cond                CONDITION_VARIABLE idle_
//   GThread* worker_thread          std::thread worker_
//   g_main_context_invoke           PostMessageW to a message-only
//                                   window owned by the TIP thread
//
// Invariants the rest of the TIP must preserve (taken verbatim from
// the macOS controller and IBus engine):
//
//   1. The keystroke handler synchronously echoes the raw Latin
//      buffer (no async wait) before scheduling work, so the user
//      always sees their typing immediately.
//   2. Repeated schedule() calls during a typing burst simply
//      overwrite pending_buffer_, so the engine processes only the
//      most recent buffer the user has typed.
//   3. Results that arrive after the buffer has moved on are dropped
//      via the stale-buffer guard on the TIP thread.
//   4. Commit / cancel / clear paths drain_and_wait_idle() before
//      issuing synchronous FFI calls, so engine state is never
//      touched concurrently.
//   5. Engine handle teardown nulls handle_ under worker_lock_ so a
//      result already en route to the message window becomes a
//      null-check no-op instead of a use-after-free.

#pragma once

#include <Windows.h>

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "ffi_loader.h"

namespace burmese {

// Snapshot delivered back to the TIP thread for a finished update.
// `json` is the raw JSON string the FFI produced (already malloc-
// duplicated locally, so the FFI's string buffer is freed inside the
// worker before we leave). Empty `json` indicates a dropped or null
// result.
struct EngineSnapshot {
    std::string buffer;   // the buffer the engine ran against
    std::string json;     // burmese_engine_update output, may be empty
};

// Owns the worker thread + the engine handle for one TIP instance.
// Construction does NOT start the engine — call start() once the FFI
// table has been resolved and the resource paths are known.
class EngineWorker {
public:
    EngineWorker() noexcept;
    ~EngineWorker() noexcept;

    EngineWorker(const EngineWorker&) = delete;
    EngineWorker& operator=(const EngineWorker&) = delete;

    // Bring up the worker thread and create the burmese engine handle.
    // `ffi` must remain valid for the lifetime of the worker.
    // `lexicon_path`, `lm_path`, `history_path` are passed through to
    // burmese_engine_new (empty -> EmptyCandidateStore etc, per ffi.h).
    // `delivery_target` is the HWND that receives WM_MYANGLER_RESULT
    // messages; `delivery_user` is the wParam to use for those
    // messages so the receiver can route them to the right
    // TextService instance.
    //
    // Returns false on engine_new failure or worker-thread spawn
    // failure. On false, internal state is left empty.
    bool start(const FfiTable*       ffi,
               const std::string&    lexicon_path,
               const std::string&    lm_path,
               const std::string&    history_path,
               HWND                  delivery_target,
               WPARAM                delivery_user) noexcept;

    // Synchronously stop the worker, drain any pending result, and
    // free the engine handle. Safe to call multiple times; subsequent
    // calls are no-ops. Called from TextService::Deactivate on the
    // TIP thread.
    void stop() noexcept;

    // Enqueue (or overwrite) the most recent buffer the engine should
    // process. Returns immediately. Called from the TIP thread inside
    // ITfKeyEventSink::OnKeyDown after the synchronous preedit echo.
    void schedule_update(const std::string& buffer) noexcept;

    // Drop any queued buffer and block until any in-flight update
    // returns. After this call, the TIP thread holds exclusive
    // logical access to the engine handle — safe to issue commit /
    // cancel synchronously.
    void drain_and_wait_idle() noexcept;

    // Synchronous FFI calls used by the TIP commit / cancel paths.
    // Caller MUST have first drain_and_wait_idle()'d.
    std::string commit_sync() noexcept;
    std::string cancel_sync() noexcept;
    void        record_selection_sync() noexcept;
    void        set_selected_sync(int idx) noexcept;
    void        push_committed_context_sync(const std::string& utf8_surface) noexcept;

    // True iff start() succeeded and stop() has not run.
    bool running() const noexcept { return handle_.load(std::memory_order_acquire) != nullptr; }

    // Receive-side hook for the TIP thread: take ownership of the
    // most recently delivered snapshot (if any) and clear the slot.
    // Returns std::nullopt if no result is pending. Called from the
    // TIP message loop on WM_MYANGLER_RESULT.
    std::unique_ptr<EngineSnapshot> take_pending_result() noexcept;

    // Custom message: posted by the worker via PostMessageW to the
    // TIP-owned message-only window. wParam = delivery_user provided
    // to start(); lParam = unused (the snapshot lives in the
    // EngineWorker; take it via take_pending_result()).
    static constexpr UINT kMessageResult = WM_USER + 0x100;

private:
    static void worker_main(EngineWorker* self) noexcept;

    const FfiTable*       ffi_         = nullptr;
    std::atomic<burmese_engine_t*> handle_{nullptr};

    SRWLOCK               lock_        = SRWLOCK_INIT;
    CONDITION_VARIABLE    work_pending_ = CONDITION_VARIABLE_INIT;
    CONDITION_VARIABLE    idle_         = CONDITION_VARIABLE_INIT;

    // All five fields below are protected by lock_.
    bool                  shutting_down_ = false;
    bool                  pending_       = false;
    std::string           pending_buffer_;
    bool                  in_flight_     = false;
    std::unique_ptr<EngineSnapshot> pending_result_;   // last result for take_pending_result()

    std::thread           worker_;
    HWND                  delivery_target_ = nullptr;
    WPARAM                delivery_user_   = 0;
};

} // namespace burmese
