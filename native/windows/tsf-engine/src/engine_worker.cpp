#include "engine_worker.h"

#include <cstring>
#include <utility>

namespace burmese {

EngineWorker::EngineWorker() noexcept = default;

EngineWorker::~EngineWorker() noexcept { stop(); }

bool EngineWorker::start(const FfiTable*    ffi,
                         const std::string& lexicon_path,
                         const std::string& lm_path,
                         const std::string& history_path,
                         HWND               delivery_target,
                         WPARAM             delivery_user) noexcept {
    if (!ffi || handle_.load(std::memory_order_acquire) != nullptr) {
        return false;
    }

    ffi_              = ffi;
    delivery_target_  = delivery_target;
    delivery_user_    = delivery_user;
    shutting_down_    = false;
    pending_          = false;
    in_flight_        = false;
    pending_buffer_.clear();
    pending_result_.reset();

    // Create the engine handle. Empty path strings -> the FFI's
    // empty-store / null-LM fallbacks (see ffi.h).
    auto cstr = [](const std::string& s) -> const char* {
        return s.empty() ? nullptr : s.c_str();
    };
    burmese_engine_t* h = ffi_->engine_new(
        cstr(lexicon_path),
        cstr(lm_path),
        cstr(history_path),
        /*settings_suite_name=*/nullptr);
    if (!h) {
        return false;
    }
    handle_.store(h, std::memory_order_release);

    try {
        worker_ = std::thread(&EngineWorker::worker_main, this);
    } catch (...) {
        // Thread spawn failed; clean up the engine handle so we don't
        // leak it.
        ffi_->engine_free(h);
        handle_.store(nullptr, std::memory_order_release);
        return false;
    }
    return true;
}

void EngineWorker::stop() noexcept {
    burmese_engine_t* h = handle_.load(std::memory_order_acquire);
    if (!h && !worker_.joinable()) return;

    {
        AcquireSRWLockExclusive(&lock_);
        shutting_down_ = true;
        pending_       = false;
        WakeAllConditionVariable(&work_pending_);
        // Wait for an in-flight call to wind down — drains the worker
        // before we free the engine handle. Same shape as
        // drain_and_wait_idle().
        while (in_flight_) {
            SleepConditionVariableSRW(&idle_, &lock_, INFINITE, 0);
        }
        ReleaseSRWLockExclusive(&lock_);
    }

    if (worker_.joinable()) worker_.join();

    // Null the handle BEFORE freeing it so any racing access via
    // running() sees the disabled state. The worker is joined so this
    // is uncontended in practice; the atomic store is still useful
    // for the synchronous commit / cancel paths.
    handle_.store(nullptr, std::memory_order_release);
    if (h && ffi_) ffi_->engine_free(h);

    pending_buffer_.clear();
    pending_result_.reset();
}

void EngineWorker::schedule_update(const std::string& buffer) noexcept {
    AcquireSRWLockExclusive(&lock_);
    pending_buffer_ = buffer;
    pending_       = true;
    WakeConditionVariable(&work_pending_);
    ReleaseSRWLockExclusive(&lock_);
}

void EngineWorker::drain_and_wait_idle() noexcept {
    AcquireSRWLockExclusive(&lock_);
    pending_ = false;
    while (in_flight_) {
        SleepConditionVariableSRW(&idle_, &lock_, INFINITE, 0);
    }
    ReleaseSRWLockExclusive(&lock_);
}

std::string EngineWorker::commit_sync() noexcept {
    burmese_engine_t* h = handle_.load(std::memory_order_acquire);
    if (!h || !ffi_) return {};
    char* raw = ffi_->engine_commit(h);
    std::string out = (raw && *raw) ? raw : "";
    if (raw) ffi_->engine_string_free(raw);
    return out;
}

std::string EngineWorker::cancel_sync() noexcept {
    burmese_engine_t* h = handle_.load(std::memory_order_acquire);
    if (!h || !ffi_) return {};
    char* raw = ffi_->engine_cancel(h);
    std::string out = (raw && *raw) ? raw : "";
    if (raw) ffi_->engine_string_free(raw);
    return out;
}

void EngineWorker::record_selection_sync() noexcept {
    burmese_engine_t* h = handle_.load(std::memory_order_acquire);
    if (!h || !ffi_) return;
    ffi_->engine_record_selection(h);
}

void EngineWorker::set_selected_sync(int idx) noexcept {
    burmese_engine_t* h = handle_.load(std::memory_order_acquire);
    if (!h || !ffi_) return;
    ffi_->engine_set_selected(h, static_cast<int32_t>(idx));
}

void EngineWorker::push_committed_context_sync(const std::string& utf8_surface) noexcept {
    burmese_engine_t* h = handle_.load(std::memory_order_acquire);
    if (!h || !ffi_ || utf8_surface.empty()) return;
    ffi_->engine_push_committed_context(h, utf8_surface.c_str());
}

void EngineWorker::sync_update_buffer(const std::string& buffer) noexcept {
    burmese_engine_t* h = handle_.load(std::memory_order_acquire);
    if (!h || !ffi_) return;
    char* raw = ffi_->engine_update(h, buffer.c_str());
    if (raw) ffi_->engine_string_free(raw);
}

std::unique_ptr<EngineSnapshot> EngineWorker::take_pending_result() noexcept {
    AcquireSRWLockExclusive(&lock_);
    auto result = std::move(pending_result_);
    pending_result_.reset();
    ReleaseSRWLockExclusive(&lock_);
    return result;
}

void EngineWorker::worker_main(EngineWorker* self) noexcept {
    for (;;) {
        std::string buf;
        burmese_engine_t* h = nullptr;
        {
            AcquireSRWLockExclusive(&self->lock_);
            while (!self->shutting_down_ && !self->pending_) {
                SleepConditionVariableSRW(
                    &self->work_pending_, &self->lock_, INFINITE, 0);
            }
            if (self->shutting_down_) {
                ReleaseSRWLockExclusive(&self->lock_);
                return;
            }
            buf = self->pending_buffer_;
            self->pending_   = false;
            self->in_flight_ = true;
            h = self->handle_.load(std::memory_order_acquire);
            ReleaseSRWLockExclusive(&self->lock_);
        }

        // Run the (possibly slow) engine call without holding the lock.
        // The FFI is internally locked, so the synchronous commit /
        // cancel paths on the TIP thread aren't reordered with this.
        std::string json;
        if (h && self->ffi_) {
            char* raw = self->ffi_->engine_update(h, buf.c_str());
            if (raw) {
                json.assign(raw);
                self->ffi_->engine_string_free(raw);
            }
        }

        // Marshal the result back to the TIP thread. The TIP picks it
        // up via take_pending_result() from its WM_MYANGLER_RESULT
        // handler. We store under the lock and post the message; the
        // receiver's stale-buffer guard runs on the TIP thread.
        {
            AcquireSRWLockExclusive(&self->lock_);
            self->pending_result_ = std::make_unique<EngineSnapshot>(
                EngineSnapshot{std::move(buf), std::move(json)});
            ReleaseSRWLockExclusive(&self->lock_);
        }
        if (self->delivery_target_) {
            // PostMessageW failure is non-fatal (the receiver is
            // probably tearing down); the slot stays populated and
            // gets discarded by the next cycle or stop().
            PostMessageW(self->delivery_target_,
                         kMessageResult,
                         self->delivery_user_, 0);
        }

        {
            AcquireSRWLockExclusive(&self->lock_);
            self->in_flight_ = false;
            WakeAllConditionVariable(&self->idle_);
            ReleaseSRWLockExclusive(&self->lock_);
        }
    }
}

} // namespace burmese
