#include "settings.h"

#include "engine_worker.h"

#include <cstdlib>
#include <cwchar>
#include <string>

namespace burmese {

namespace {

constexpr wchar_t kSubKey[] = L"Software\\Myangler\\BurmeseIME";

constexpr wchar_t kCandidatePageSize       [] = L"CandidatePageSize";
constexpr wchar_t kCommitOnSpace           [] = L"CommitOnSpace";
constexpr wchar_t kClusterAliasesEnabled   [] = L"ClusterAliasesEnabled";
constexpr wchar_t kLMPruneMargin           [] = L"LMPruneMargin";
constexpr wchar_t kAnchorCommitThreshold   [] = L"AnchorCommitThreshold";
constexpr wchar_t kBurmesePunctuation      [] = L"BurmesePunctuationEnabled";
constexpr wchar_t kNumberMeasureWords      [] = L"NumberMeasureWordsEnabled";
constexpr wchar_t kLearningEnabled         [] = L"LearningEnabled";

LSTATUS set_dword(HKEY k, const wchar_t* name, DWORD v) {
    return RegSetValueExW(k, name, 0, REG_DWORD,
                          reinterpret_cast<const BYTE*>(&v), sizeof(v));
}

LSTATUS set_sz(HKEY k, const wchar_t* name, const wchar_t* v) {
    const DWORD bytes = static_cast<DWORD>((std::wcslen(v) + 1) * sizeof(wchar_t));
    return RegSetValueExW(k, name, 0, REG_SZ,
                          reinterpret_cast<const BYTE*>(v), bytes);
}

bool get_dword(HKEY k, const wchar_t* name, DWORD& out) {
    DWORD type = 0;
    DWORD val  = 0;
    DWORD sz   = sizeof(val);
    if (RegQueryValueExW(k, name, nullptr, &type,
                         reinterpret_cast<BYTE*>(&val), &sz) != ERROR_SUCCESS) {
        return false;
    }
    if (type != REG_DWORD) return false;
    out = val;
    return true;
}

bool get_sz(HKEY k, const wchar_t* name, std::wstring& out) {
    DWORD type = 0;
    DWORD bytes = 0;
    if (RegQueryValueExW(k, name, nullptr, &type, nullptr, &bytes) != ERROR_SUCCESS) {
        return false;
    }
    if (type != REG_SZ || bytes == 0) return false;
    out.assign((bytes / sizeof(wchar_t)) - 1, L'\0');
    DWORD bytes2 = bytes;
    if (RegQueryValueExW(k, name, nullptr, nullptr,
                         reinterpret_cast<BYTE*>(out.data()), &bytes2) != ERROR_SUCCESS) {
        return false;
    }
    while (!out.empty() && out.back() == L'\0') out.pop_back();
    return true;
}

} // namespace

Settings::~Settings() noexcept { stop(); }

bool Settings::start(EngineWorker* worker) noexcept {
    if (!worker) return false;
    worker_ = worker;

    LSTATUS s = RegCreateKeyExW(
        HKEY_CURRENT_USER, kSubKey, 0, nullptr,
        REG_OPTION_NON_VOLATILE,
        KEY_READ | KEY_WRITE | KEY_NOTIFY,
        nullptr, &key_, nullptr);
    if (s != ERROR_SUCCESS) {
        key_ = nullptr;
        return false;
    }

    // Read once. Any missing keys come back as defaults from
    // SettingsValues's in-class initialisers — write those back so
    // they're visible to a future Preferences app / regedit pass
    // without forcing the user to discover them manually.
    SettingsValues v;
    read_all(v);   // populates v with whatever is on disk, leaving
                   // defaults for missing keys
    {
        set_dword(key_, kCandidatePageSize,        static_cast<DWORD>(v.candidate_page_size));
        set_dword(key_, kCommitOnSpace,            v.commit_on_space ? 1 : 0);
        set_dword(key_, kClusterAliasesEnabled,    v.cluster_aliases_enabled ? 1 : 0);
        wchar_t buf[32]; std::swprintf(buf, 32, L"%g", v.lm_prune_margin);
        set_sz   (key_, kLMPruneMargin, buf);
        set_dword(key_, kAnchorCommitThreshold,    static_cast<DWORD>(v.anchor_commit_threshold));
        set_dword(key_, kBurmesePunctuation,       v.burmese_punctuation ? 1 : 0);
        set_dword(key_, kNumberMeasureWords,       v.number_measure_words ? 1 : 0);
        set_dword(key_, kLearningEnabled,          v.learning_enabled ? 1 : 0);
    }
    apply(v);

    notifyEvent_   = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    shutdownEvent_ = CreateEventW(nullptr, TRUE,  FALSE, nullptr);
    if (!notifyEvent_ || !shutdownEvent_) {
        stop();
        return false;
    }

    try {
        thread_ = std::thread(&Settings::watcher_main, this);
    } catch (...) {
        stop();
        return false;
    }
    return true;
}

void Settings::stop() noexcept {
    if (shutdownEvent_) SetEvent(shutdownEvent_);
    if (thread_.joinable()) thread_.join();
    if (notifyEvent_)   { CloseHandle(notifyEvent_);   notifyEvent_   = nullptr; }
    if (shutdownEvent_) { CloseHandle(shutdownEvent_); shutdownEvent_ = nullptr; }
    if (key_)           { RegCloseKey(key_);           key_           = nullptr; }
    worker_ = nullptr;
}

bool Settings::read_all(SettingsValues& v) noexcept {
    if (!key_) return false;
    DWORD d = 0;
    if (get_dword(key_, kCandidatePageSize, d))     v.candidate_page_size = static_cast<int32_t>(d);
    if (get_dword(key_, kCommitOnSpace, d))         v.commit_on_space = (d != 0);
    if (get_dword(key_, kClusterAliasesEnabled, d)) v.cluster_aliases_enabled = (d != 0);
    std::wstring s;
    if (get_sz(key_, kLMPruneMargin, s)) {
        wchar_t* endp = nullptr;
        double parsed = std::wcstod(s.c_str(), &endp);
        if (endp != s.c_str()) v.lm_prune_margin = parsed;
    }
    if (get_dword(key_, kAnchorCommitThreshold, d)) v.anchor_commit_threshold = static_cast<int32_t>(d);
    if (get_dword(key_, kBurmesePunctuation, d))    v.burmese_punctuation = (d != 0);
    if (get_dword(key_, kNumberMeasureWords, d))    v.number_measure_words = (d != 0);
    if (get_dword(key_, kLearningEnabled, d))       v.learning_enabled = (d != 0);
    return true;
}

void Settings::apply(const SettingsValues& v) noexcept {
    if (worker_) worker_->apply_settings(v);
}

void Settings::watcher_main(Settings* self) noexcept {
    if (!self->key_ || !self->notifyEvent_ || !self->shutdownEvent_) return;

    HANDLE waits[2] = { self->notifyEvent_, self->shutdownEvent_ };
    for (;;) {
        // RegNotifyChangeKeyValue fires the event exactly once per
        // call, so we re-arm on every cycle after a notification.
        LSTATUS s = RegNotifyChangeKeyValue(
            self->key_,
            /*bWatchSubtree=*/FALSE,
            REG_NOTIFY_CHANGE_LAST_SET,
            self->notifyEvent_,
            TRUE);
        if (s != ERROR_SUCCESS) {
            // Registry handle is gone (likely stop() running on the
            // main thread); bail.
            return;
        }
        DWORD wait = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
        if (wait == WAIT_OBJECT_0 + 1) return;   // shutdown signalled
        if (wait != WAIT_OBJECT_0) return;       // unexpected
        SettingsValues v;
        if (!self->read_all(v)) continue;
        self->apply(v);
    }
}

} // namespace burmese
