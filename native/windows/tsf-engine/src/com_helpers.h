// Minimum-surface IUnknown helpers for the BurmeseIME TIP.
//
// Deliberately avoids ATL / WRL — every COM object in this DLL is
// small, and hand-rolled reference counting is easier to audit than a
// templated abstraction. Two ingredients:
//
//   1. UnknownBase — embeds the ref count and provides default
//      AddRef / Release. Derived classes implement QueryInterface.
//   2. ComPtr — a minimal scoped pointer for IUnknown-derived
//      interfaces. AddRef on copy, Release on destruction.
//
// Both are header-only; no .cpp companion.

#pragma once

#include <Unknwn.h>
#include <atomic>
#include <utility>

namespace burmese {

// Base for every COM object the DLL implements. Provides thread-safe
// reference counting and standard AddRef / Release. Subclasses must
// implement QueryInterface to expose their interfaces.
class UnknownBase : public IUnknown {
public:
    UnknownBase() noexcept : ref_(1) {}
    virtual ~UnknownBase() = default;

    UnknownBase(const UnknownBase&) = delete;
    UnknownBase& operator=(const UnknownBase&) = delete;

    ULONG STDMETHODCALLTYPE AddRef() noexcept override {
        return static_cast<ULONG>(ref_.fetch_add(1, std::memory_order_relaxed) + 1);
    }

    ULONG STDMETHODCALLTYPE Release() noexcept override {
        const auto remaining = ref_.fetch_sub(1, std::memory_order_acq_rel) - 1;
        if (remaining == 0) {
            delete this;
        }
        return static_cast<ULONG>(remaining);
    }

private:
    std::atomic<long> ref_;
};

// Resolve QueryInterface for one specific IID. Use in a chain inside a
// derived class's QueryInterface implementation.
template <typename Iface>
inline bool QueryOne(REFIID riid, void** ppv, Iface* self) noexcept {
    if (riid == __uuidof(Iface)) {
        *ppv = static_cast<Iface*>(self);
        self->AddRef();
        return true;
    }
    return false;
}

// Minimum scoped COM pointer. AddRef on copy, Release on destruction.
template <typename T>
class ComPtr {
public:
    ComPtr() noexcept = default;

    ~ComPtr() noexcept { reset(); }

    ComPtr(const ComPtr& other) noexcept : ptr_(other.ptr_) {
        if (ptr_) ptr_->AddRef();
    }

    ComPtr(ComPtr&& other) noexcept : ptr_(other.ptr_) {
        other.ptr_ = nullptr;
    }

    ComPtr& operator=(const ComPtr& other) noexcept {
        if (this != &other) {
            reset();
            ptr_ = other.ptr_;
            if (ptr_) ptr_->AddRef();
        }
        return *this;
    }

    ComPtr& operator=(ComPtr&& other) noexcept {
        if (this != &other) {
            reset();
            ptr_ = other.ptr_;
            other.ptr_ = nullptr;
        }
        return *this;
    }

    void reset() noexcept {
        if (ptr_) {
            ptr_->Release();
            ptr_ = nullptr;
        }
    }

    // Take ownership of an interface that already has an AddRef on
    // its caller's behalf (e.g. fresh QueryInterface output).
    void attach(T* raw) noexcept {
        reset();
        ptr_ = raw;
    }

    // Receive a freshly AddRef'd pointer from an out-parameter:
    //   ComPtr<IFoo> foo;
    //   producer->Get(foo.put());
    T** put() noexcept {
        reset();
        return &ptr_;
    }

    void** put_void() noexcept {
        return reinterpret_cast<void**>(put());
    }

    T* get() const noexcept { return ptr_; }
    T* operator->() const noexcept { return ptr_; }
    explicit operator bool() const noexcept { return ptr_ != nullptr; }

private:
    T* ptr_ = nullptr;
};

} // namespace burmese
