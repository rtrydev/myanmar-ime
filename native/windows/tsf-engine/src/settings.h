// HKCU-backed settings store for the BurmeseIME TIP.
//
// Per-user (HKCU\Software\Myangler\BurmeseIME), eight values that
// mirror IMESettings.Key in the Swift core (and the GSettings schema
// the Linux engine reads). When any value changes, the watcher
// thread re-reads the whole block and applies it via the FFI
// setters. The Swift side internally handles cluster-aliases-changed
// by rebuilding the engine — see
// native/linux/swift-shim/Sources/BurmeseIMEFFI/FFI.swift —
// so the C++ side never needs to explicitly call reconcile.
//
// Registry value names (all under the key above):
//   CandidatePageSize             REG_DWORD   (default 9)
//   CommitOnSpace                 REG_DWORD   (0/1, default 0)
//   ClusterAliasesEnabled         REG_DWORD   (0/1, default 1)
//   LMPruneMargin                 REG_SZ      (decimal, default "8.0")
//   AnchorCommitThreshold         REG_DWORD   (default 8)
//   BurmesePunctuationEnabled     REG_DWORD   (0/1, default 0)
//   NumberMeasureWordsEnabled     REG_DWORD   (0/1, default 0)
//   LearningEnabled               REG_DWORD   (0/1, default 1)
//
// Defaults match the macOS / Linux defaults in CLAUDE.md.
// LMPruneMargin is REG_SZ because the Windows registry has no
// native double type and BINARY would be opaque in regedit; the
// string form is the cleanest source of truth for a Preferences app.

#pragma once

#include <Windows.h>

#include <atomic>
#include <thread>

namespace burmese {

class EngineWorker;
struct FfiTable;

struct SettingsValues {
    int32_t candidate_page_size       = 9;
    bool    commit_on_space           = false;
    bool    cluster_aliases_enabled   = true;
    double  lm_prune_margin           = 8.0;
    int32_t anchor_commit_threshold   = 8;
    bool    burmese_punctuation       = false;
    bool    number_measure_words      = false;
    bool    learning_enabled          = true;
};

class Settings {
public:
    Settings() noexcept = default;
    ~Settings() noexcept;

    Settings(const Settings&) = delete;
    Settings& operator=(const Settings&) = delete;

    // Open / create HKCU\Software\Myangler\BurmeseIME with read +
    // write + notify access. Read every value (writing defaults
    // back for missing entries so the keys are visible in regedit
    // / Preferences-app), apply via worker.apply_settings, then
    // spawn the change-watcher thread. Returns false on registry
    // failure; the TIP keeps running with whatever default the
    // FFI was constructed with.
    bool start(EngineWorker* worker) noexcept;

    // Signal the watcher to exit, join it, close handles. Idempotent.
    void stop() noexcept;

private:
    static void watcher_main(Settings* self) noexcept;
    bool read_all(SettingsValues& out) noexcept;
    void apply(const SettingsValues& v) noexcept;

    EngineWorker* worker_ = nullptr;
    HKEY          key_     = nullptr;
    HANDLE        notifyEvent_   = nullptr;
    HANDLE        shutdownEvent_ = nullptr;
    std::thread   thread_;
};

} // namespace burmese
