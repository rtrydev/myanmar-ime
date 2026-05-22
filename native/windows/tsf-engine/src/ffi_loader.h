// Dynamic loader for BurmeseIMEFFI.dll (the Swift shim around
// BurmeseIMECore). The TIP DLL deliberately doesn't link against
// BurmeseIMEFFI.lib at build time so a missing/incompatible shim
// surfaces as a clean "Activate failed" diagnostic instead of a hard
// process-load failure of every text-receiving host. The DLL is
// loaded on TextService::Activate and unloaded on Deactivate.
//
// Symbol set must stay in sync with the .def file at
// `native/windows/swift-shim/BurmeseIMEFFI.def` and the C ABI at
// `native/linux/ibus-engine/src/ffi.h`. The C compiler / linker catch
// drift at TIP-build time.

#pragma once

#include <Windows.h>
#include <cstdint>
#include <string>

// The shared FFI header lives under native/linux/ibus-engine/src/ — we
// add that directory to the include path in CMakeLists.txt so both
// shells stay bound to the same contract.
extern "C" {
#include "ffi.h"
}

namespace burmese {

// Function-pointer table for every burmese_engine_* entry point. One
// per symbol declared in ffi.h. The order in this struct doesn't
// matter — names are resolved by string lookup.
struct FfiTable {
    decltype(&::burmese_engine_new)                            engine_new                            = nullptr;
    decltype(&::burmese_engine_free)                           engine_free                           = nullptr;
    decltype(&::burmese_engine_update)                         engine_update                         = nullptr;
    decltype(&::burmese_engine_commit)                         engine_commit                         = nullptr;
    decltype(&::burmese_engine_record_selection)               engine_record_selection               = nullptr;
    decltype(&::burmese_engine_set_selected)                   engine_set_selected                   = nullptr;
    decltype(&::burmese_engine_cancel)                         engine_cancel                         = nullptr;
    decltype(&::burmese_engine_push_committed_context)         engine_push_committed_context         = nullptr;
    decltype(&::burmese_engine_clear_committed_context)        engine_clear_committed_context        = nullptr;
    decltype(&::burmese_engine_set_candidate_page_size)        engine_set_candidate_page_size        = nullptr;
    decltype(&::burmese_engine_set_commit_on_space)            engine_set_commit_on_space            = nullptr;
    decltype(&::burmese_engine_set_cluster_aliases_enabled)    engine_set_cluster_aliases_enabled    = nullptr;
    decltype(&::burmese_engine_set_lm_prune_margin)            engine_set_lm_prune_margin            = nullptr;
    decltype(&::burmese_engine_set_anchor_commit_threshold)    engine_set_anchor_commit_threshold    = nullptr;
    decltype(&::burmese_engine_set_burmese_punctuation_enabled) engine_set_burmese_punctuation_enabled = nullptr;
    decltype(&::burmese_engine_set_number_measure_words_enabled) engine_set_number_measure_words_enabled = nullptr;
    decltype(&::burmese_engine_set_learning_enabled)           engine_set_learning_enabled           = nullptr;
    decltype(&::burmese_engine_reconcile_settings)             engine_reconcile_settings             = nullptr;
    decltype(&::burmese_engine_map_empty_buffer_punctuation)   engine_map_empty_buffer_punctuation   = nullptr;
    decltype(&::burmese_engine_diagnostics)                    engine_diagnostics                    = nullptr;
    decltype(&::burmese_engine_reverse_romanize)               engine_reverse_romanize               = nullptr;
    decltype(&::burmese_engine_string_free)                    engine_string_free                    = nullptr;
};

// Owns the loaded HMODULE. Move-only; on destruction unloads the DLL.
class FfiLibrary {
public:
    FfiLibrary() noexcept = default;
    ~FfiLibrary() noexcept;

    FfiLibrary(const FfiLibrary&) = delete;
    FfiLibrary& operator=(const FfiLibrary&) = delete;

    FfiLibrary(FfiLibrary&& other) noexcept;
    FfiLibrary& operator=(FfiLibrary&& other) noexcept;

    // Load BurmeseIMEFFI.dll using these resolution rules, in order:
    //   1. %MYANGLER_FFI_DLL% if set (absolute path to the .dll).
    //   2. Same directory as the TIP DLL itself (production install).
    //   3. The standard LoadLibraryW search path (DLL search order).
    // On success, the FfiTable is fully populated and ready to call.
    // Returns false on any failure; call `errorDetail()` for a string.
    bool load(HMODULE selfModule) noexcept;

    // Test invariant: returns true only after a successful load().
    bool ready() const noexcept { return module_ != nullptr; }

    const FfiTable& table() const noexcept { return table_; }

    // Human-readable diagnostic populated on load failure. Used by
    // TextService::Activate to write an OutputDebugString and bail
    // out gracefully instead of crashing the host.
    const wchar_t* errorDetail() const noexcept { return error_.c_str(); }

private:
    HMODULE     module_ = nullptr;
    FfiTable    table_{};
    std::wstring error_;

    void unload() noexcept;
};

} // namespace burmese
