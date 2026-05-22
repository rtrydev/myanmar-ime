#include "ffi_loader.h"

#include <string>

namespace burmese {

namespace {

// Resolve one symbol; record a useful error and return false on miss.
template <typename Fn>
bool resolve(HMODULE module, const char* name, Fn*& out, std::wstring& err) {
    auto* raw = GetProcAddress(module, name);
    if (!raw) {
        err  = L"missing export: ";
        // GetProcAddress takes ANSI symbol names; widen for diagnostic.
        for (const char* p = name; *p; ++p) err.push_back(static_cast<wchar_t>(*p));
        return false;
    }
    // void(*)(void) is the safe intermediate before casting to the
    // typed function pointer. Avoids the "casting object pointer to
    // function pointer" undefined-behaviour warning that GCC would
    // emit; harmless under MSVC too.
    out = reinterpret_cast<Fn*>(reinterpret_cast<void(*)()>(raw));
    return true;
}

// Try LoadLibraryEx with LOAD_WITH_ALTERED_SEARCH_PATH so Windows
// resolves the loaded DLL's transitive dependencies (Foundation.dll,
// swiftCore.dll, vcruntime140.dll, ...) from the SAME directory the
// DLL itself lives in.
//
// Without this flag, Windows uses the standard search path for
// dependency resolution — host-exe-dir + System32 + cwd + PATH,
// NOT the directory of the DLL being loaded. For a TIP loaded into
// e.g. Notepad's process, host-exe-dir is System32 and the Swift
// runtime DLLs are nowhere on the standard path; the load would
// succeed for BurmeseIMEFFI.dll itself but fail when it tries to
// pull in its Swift runtime siblings, and the TIP would silently
// go inert with a "missing exports" error.
//
// (LOAD_LIBRARY_SEARCH_* flags cannot be combined with
// LOAD_WITH_ALTERED_SEARCH_PATH per MSDN — combining them makes
// the call fail. AddDllDirectory in DllMain is the parallel
// safety net for code paths that don't go through this helper.)
HMODULE try_load(const std::wstring& path) noexcept {
    if (path.empty()) return nullptr;
    return LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
}

std::wstring module_directory(HMODULE self) {
    wchar_t buf[MAX_PATH] = {0};
    DWORD n = GetModuleFileNameW(self, buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return {};
    std::wstring s(buf, n);
    auto slash = s.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return {};
    return s.substr(0, slash + 1);   // keep trailing slash
}

std::wstring env(const wchar_t* name) {
    wchar_t buf[1024] = {0};
    DWORD n = GetEnvironmentVariableW(name, buf, 1024);
    if (n == 0 || n >= 1024) return {};
    return std::wstring(buf, n);
}

} // namespace

FfiLibrary::~FfiLibrary() noexcept { unload(); }

FfiLibrary::FfiLibrary(FfiLibrary&& other) noexcept
    : module_(other.module_), table_(other.table_), error_(std::move(other.error_)) {
    other.module_ = nullptr;
    other.table_ = FfiTable{};
}

FfiLibrary& FfiLibrary::operator=(FfiLibrary&& other) noexcept {
    if (this != &other) {
        unload();
        module_ = other.module_;
        table_  = other.table_;
        error_  = std::move(other.error_);
        other.module_ = nullptr;
        other.table_ = FfiTable{};
    }
    return *this;
}

void FfiLibrary::unload() noexcept {
    if (module_) {
        FreeLibrary(module_);
        module_ = nullptr;
        table_ = FfiTable{};
    }
}

bool FfiLibrary::load(HMODULE selfModule) noexcept {
    unload();
    error_.clear();

    constexpr wchar_t kBaseName[] = L"BurmeseIMEFFI.dll";

    // 1) explicit override via env var (dev convenience).
    std::wstring envPath = env(L"MYANGLER_FFI_DLL");
    HMODULE mod = try_load(envPath);

    // 2) sibling of the TIP DLL (production install layout).
    if (!mod) {
        std::wstring dir = module_directory(selfModule);
        if (!dir.empty()) {
            mod = try_load(dir + kBaseName);
        }
    }

    // 3) standard search path.
    if (!mod) {
        mod = LoadLibraryW(kBaseName);
    }

    if (!mod) {
        error_ = L"LoadLibraryW(BurmeseIMEFFI.dll) failed (GetLastError=";
        error_ += std::to_wstring(GetLastError());
        error_ += L")";
        return false;
    }

    module_ = mod;

    // Resolve every entry point. If any single one is missing, treat
    // the whole library as bad rather than letting the TIP run with a
    // partially-populated table that would null-deref later.
    bool ok = true;
    ok &= resolve(mod, "burmese_engine_new",                            table_.engine_new,                            error_);
    ok &= resolve(mod, "burmese_engine_free",                           table_.engine_free,                           error_);
    ok &= resolve(mod, "burmese_engine_update",                         table_.engine_update,                         error_);
    ok &= resolve(mod, "burmese_engine_commit",                         table_.engine_commit,                         error_);
    ok &= resolve(mod, "burmese_engine_record_selection",               table_.engine_record_selection,               error_);
    ok &= resolve(mod, "burmese_engine_set_selected",                   table_.engine_set_selected,                   error_);
    ok &= resolve(mod, "burmese_engine_cancel",                         table_.engine_cancel,                         error_);
    ok &= resolve(mod, "burmese_engine_push_committed_context",         table_.engine_push_committed_context,         error_);
    ok &= resolve(mod, "burmese_engine_clear_committed_context",        table_.engine_clear_committed_context,        error_);
    ok &= resolve(mod, "burmese_engine_set_candidate_page_size",        table_.engine_set_candidate_page_size,        error_);
    ok &= resolve(mod, "burmese_engine_set_commit_on_space",            table_.engine_set_commit_on_space,            error_);
    ok &= resolve(mod, "burmese_engine_set_cluster_aliases_enabled",    table_.engine_set_cluster_aliases_enabled,    error_);
    ok &= resolve(mod, "burmese_engine_set_lm_prune_margin",            table_.engine_set_lm_prune_margin,            error_);
    ok &= resolve(mod, "burmese_engine_set_anchor_commit_threshold",    table_.engine_set_anchor_commit_threshold,    error_);
    ok &= resolve(mod, "burmese_engine_set_burmese_punctuation_enabled", table_.engine_set_burmese_punctuation_enabled, error_);
    ok &= resolve(mod, "burmese_engine_set_number_measure_words_enabled", table_.engine_set_number_measure_words_enabled, error_);
    ok &= resolve(mod, "burmese_engine_set_learning_enabled",           table_.engine_set_learning_enabled,           error_);
    ok &= resolve(mod, "burmese_engine_reconcile_settings",             table_.engine_reconcile_settings,             error_);
    ok &= resolve(mod, "burmese_engine_map_empty_buffer_punctuation",   table_.engine_map_empty_buffer_punctuation,   error_);
    ok &= resolve(mod, "burmese_engine_diagnostics",                    table_.engine_diagnostics,                    error_);
    ok &= resolve(mod, "burmese_engine_reverse_romanize",               table_.engine_reverse_romanize,               error_);
    ok &= resolve(mod, "burmese_engine_string_free",                    table_.engine_string_free,                    error_);

    if (!ok) {
        unload();
        return false;
    }
    return true;
}

} // namespace burmese
