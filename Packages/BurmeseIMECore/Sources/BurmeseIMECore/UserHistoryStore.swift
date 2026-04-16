import Foundation

/// Persistent record of previously-committed candidate selections. Today this
/// is a stub — the symbol exists so the preferences UI can wire a functional
/// "Reset learned history" button without a dangling TODO. The implementation
/// is filled in by the user-history task (see tasks/user-history.md).
public enum UserHistoryStore {
    public static func clearAll() {
        // No-op until user-history.md lands.
    }
}
