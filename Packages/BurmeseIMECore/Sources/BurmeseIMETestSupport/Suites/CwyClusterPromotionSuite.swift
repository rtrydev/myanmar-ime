import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-058: the ya-pin cluster-promotion gate must be
/// symmetric in medial typing order. The four ya-pin-dominant clusters
/// (`ky`, `khy`, `gy`, `ghy`) can be typed with the medial-w either
/// after the medial-y (`Cyw…`, e.g. `kywantaw`) or before it
/// (`Cwy…`, e.g. `kwyantaw`). Both produce the same canonical onset
/// storage (`<C> 103B 103D` for ya-pin; `<C> 103C 103D` for ya-yit)
/// because the parser canonicalises medial typing order before trie
/// lookup. The promotion that lifts the ya-pin sibling to rank 0 must
/// fire for both typings — the previous gate only matched the literal
/// `Cy…` prefix, so `Cwy…` typings silently committed the rare
/// ya-yit form (e.g. `kwyantaw` → `ကြွန်တော်` instead of
/// `ကျွန်တော်`).
public enum CwyClusterPromotionSuite {

    private static let yaPin: UInt32 = 0x103B
    private static let yaYit: UInt32 = 0x103C

    private static func containsYaPin(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == yaPin }
    }

    private static func containsYaYit(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == yaYit }
    }

    private static func stripped(_ surface: String) -> String {
        String(surface.unicodeScalars.filter { $0.value != 0x200B && $0.value != 0x200C })
    }

    public static let suite = TestSuite(name: "CwyClusterPromotion", cases: [

        // Bare-engine: every Cwy typing of the four ya-pin-dominant
        // clusters must produce a ya-pin rank-0 surface, matching the
        // sister Cyw typing. This is the core bug-table in TASK-058.
        TestCase("bareEngine_cwyTyping_yaPinTop") { ctx in
            let engine = BurmeseEngine()
            let buffers = [
                "kwyar", "kwyaw", "kwyin", "kwyat", "kwyaung", "kwyantaw",
                "khwyar", "khwyin", "khwyantaw",
                "gwyar", "gwyantaw",
                "ghwyar", "ghwyantaw",
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    containsYaPin(top),
                    buffer,
                    detail: "expected ya-pin (U+103B) on top, got '\(top)'"
                )
                ctx.assertFalse(
                    containsYaYit(top),
                    buffer,
                    detail: "ya-yit (U+103C) must not appear on top for '\(buffer)', got '\(top)'"
                )
            }
        },

        // Bare-engine: Cwy and Cyw typings of the same canonical onset
        // must produce identical rank-0 surfaces. This is the parity
        // requirement — both spellings of the same word must commit to
        // the same canonical Burmese text.
        TestCase("bareEngine_cwyAndCywParity") { ctx in
            let engine = BurmeseEngine()
            let pairs: [(String, String)] = [
                ("kywar",     "kwyar"),
                ("kywaw",     "kwyaw"),
                ("kywin",     "kwyin"),
                ("kywat",     "kwyat"),
                ("kywaung",   "kwyaung"),
                ("kywantaw",  "kwyantaw"),
                ("kywar:",    "kwyar:"),
                ("kywar.",    "kwyar."),
                ("khywar",    "khwyar"),
                ("khywin",    "khwyin"),
                ("khywantaw", "khwyantaw"),
                ("gywar",     "gwyar"),
                ("gywantaw",  "gwyantaw"),
                ("ghywar",    "ghwyar"),
                ("ghywantaw", "ghwyantaw"),
            ]
            for (yw, wy) in pairs {
                let ywTop = engine.update(buffer: yw, context: []).candidates.first?.surface ?? ""
                let wyTop = engine.update(buffer: wy, context: []).candidates.first?.surface ?? ""
                let ywStripped = stripped(ywTop)
                let wyStripped = stripped(wyTop)
                ctx.assertEqual(
                    wyStripped,
                    ywStripped,
                    "\(yw) vs \(wy) (Cyw and Cwy typings must agree)"
                )
            }
        },

        // Bare-engine: explicit expected scalars for each Cwy buffer
        // from the TASK-058 bug table. This is the strongest assertion —
        // it nails down the exact canonical form, not just "contains
        // ya-pin".
        TestCase("bareEngine_cwyTyping_exactSurface") { ctx in
            let engine = BurmeseEngine()
            let cases: [(buffer: String, expected: String)] = [
                ("kwyar",     "\u{1000}\u{103B}\u{103D}\u{102C}"),
                ("kwyaw",     "\u{1000}\u{103B}\u{103D}\u{1031}\u{102C}\u{103A}"),
                ("kwyin",     "\u{1000}\u{103B}\u{103D}\u{1004}\u{103A}"),
                ("kwyat",     "\u{1000}\u{103B}\u{103D}\u{1010}\u{103A}"),
                ("kwyaung",   "\u{1000}\u{103B}\u{103D}\u{1031}\u{102C}\u{1004}\u{103A}"),
                ("kwyantaw",  "\u{1000}\u{103B}\u{103D}\u{1014}\u{103A}\u{1010}\u{1031}\u{102C}\u{103A}"),
                ("kwyar:",    "\u{1000}\u{103B}\u{103D}\u{102C}\u{1038}"),
                ("kwyar.",    "\u{1000}\u{103B}\u{103D}\u{102C}\u{1037}"),
                ("khwyar",    "\u{1001}\u{103B}\u{103D}\u{102C}"),
                ("khwyin",    "\u{1001}\u{103B}\u{103D}\u{1004}\u{103A}"),
                ("khwyantaw", "\u{1001}\u{103B}\u{103D}\u{1014}\u{103A}\u{1010}\u{1031}\u{102C}\u{103A}"),
                ("gwyar",     "\u{1002}\u{103B}\u{103D}\u{102C}"),
                ("gwyantaw",  "\u{1002}\u{103B}\u{103D}\u{1014}\u{103A}\u{1010}\u{1031}\u{102C}\u{103A}"),
                ("ghwyar",    "\u{1003}\u{103B}\u{103D}\u{102C}"),
                ("ghwyantaw", "\u{1003}\u{103B}\u{103D}\u{1014}\u{103A}\u{1010}\u{1031}\u{102C}\u{103A}"),
            ]
            for entry in cases {
                let state = engine.update(buffer: entry.buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(entry.buffer, detail: "no candidates")
                    continue
                }
                ctx.assertEqual(stripped(top), entry.expected, entry.buffer)
            }
        },

        // The ya-yit sibling stays in the panel for every Cwy buffer —
        // this is a ranking flip, not a substitution. Users can still
        // pick the ya-yit form from the panel.
        TestCase("bareEngine_cwyTyping_yaYitSiblingReachable") { ctx in
            let engine = BurmeseEngine()
            for buffer in ["kwyar", "kwyantaw", "khwyar", "gwyar", "ghwyar"] {
                let state = engine.update(buffer: buffer, context: [])
                let any = state.candidates.contains { containsYaYit($0.surface) }
                ctx.assertTrue(
                    any,
                    buffer,
                    detail: "ya-yit sibling must remain reachable in candidate panel"
                )
            }
        },

        // Out-of-scope clusters stay out of scope: phy / shy / chy and
        // their Cwy typings (phwy / shwy / chwy) must NOT have a ya-pin
        // promotion fired on them. Specifically, `phyar` and `phwyar`
        // are explicitly excluded by the comment at
        // CandidateRanking.swift:388-391.
        TestCase("bareEngine_outOfScopeClusters_unchanged") { ctx in
            let engine = BurmeseEngine()
            // For phy / phwy clusters, rank-0 should keep ya-yit (ြ).
            // The promotion does not apply.
            for buffer in ["phyar", "phwyar"] {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    containsYaYit(top),
                    buffer,
                    detail: "expected ya-yit (U+103C) on top for excluded cluster, got '\(top)'"
                )
                ctx.assertFalse(
                    containsYaPin(top),
                    buffer,
                    detail: "ya-pin (U+103B) must not be promoted for excluded cluster, got '\(top)'"
                )
            }
        },

        // Plain `Cw…` buffers without a following `y` must NOT trigger
        // the new gate. `kwantaw` (k + medial-wa, no medial-ya) keeps
        // its existing rank-0 surface — neither ya-pin nor ya-yit
        // appears, only the medial-wa.
        TestCase("bareEngine_plainCwBuffers_unchanged") { ctx in
            let engine = BurmeseEngine()
            for buffer in ["kwantaw", "khwantaw", "gwa", "ghwa"] {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertFalse(
                    containsYaPin(top),
                    buffer,
                    detail: "plain Cw buffer must not be promoted to ya-pin, got '\(top)'"
                )
                ctx.assertFalse(
                    containsYaYit(top),
                    buffer,
                    detail: "plain Cw buffer must not be promoted to ya-yit, got '\(top)'"
                )
            }
        },

        // The existing Cy / Cyw / cluster-alias pathways must continue
        // to produce ya-pin at rank 0 — this is the regression guard
        // for TASK-002 / TASK-013 work.
        TestCase("bareEngine_existingYaPinPaths_unchanged") { ctx in
            let engine = BurmeseEngine()
            let buffers = [
                // Existing Cy gate
                "kya", "kyaw", "kyantaw", "kyat", "kyin",
                "khya", "khyaw", "khyit",
                "gya", "gypan", "gyat",
                "ghya", "ghyaw",
                // Existing Cyw gate
                "kywar", "kywantaw", "kywaung",
                "khywar", "khywin", "khywantaw",
                "gywar", "gywantaw",
                "ghywar", "ghywantaw",
                // Cluster-alias direct ya-pin (j / jw / ch / chw / gyw)
                "jar", "jwantaw",
                "char", "chwantaw",
                "gywar",
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    containsYaPin(top),
                    buffer,
                    detail: "expected ya-pin (U+103B) at rank 0, got '\(top)'"
                )
            }
        },
    ])
}
