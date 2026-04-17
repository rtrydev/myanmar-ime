import Foundation

/// Resolves paths for the bundled SQLite lexicon and trigram LM binary that
/// ship under `native/macos/Data/`. Returns `nil` when the artifact is
/// missing (e.g. in a fresh checkout before the lexicon/LM have been built),
/// so callers can skip real-data tests cleanly.
public enum BundledArtifacts {

    private static let repoRoot: URL = {
        // This file lives at:
        //   <repo>/Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Fixtures/BundledArtifacts.swift
        // Six `deletingLastPathComponent()` calls climb to the repo root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    public static var lexiconPath: String? {
        let url = repoRoot.appendingPathComponent("native/macos/Data/BurmeseLexicon.sqlite")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    public static var trigramLMPath: String? {
        let url = repoRoot.appendingPathComponent("native/macos/Data/BurmeseLM.bin")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }
}
