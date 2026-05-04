import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for the ya-pin-cluster promotion failing on long buffers.
/// The TASK-058 fix landed in 1827c61 lifts the rank-0 ya-pin candidate
/// for short buffers (`kwyantaw`, `kyantaw`, …), but the promotion fails
/// once the buffer is long enough that either:
///
///   1. **Parser N-best beam pruning** drops the ya-pin sibling at the
///      DP-bucket level — the ya-pin onset carries an extra alias-cost
///      digit (`kwy2…` vs `kwy…`), so once enough syllables accumulate,
///      lower-aliasCost ya-yit alternatives crowd it out and the
///      engine never sees a ya-pin candidate to promote.
///
///   2. **Sliding-window freezing** kicks in (`compositionWindowSize = 18`)
///      and the frozen-prefix path renders only the parser's single-best
///      walk. The engine-level promotion gate is also disabled in the
///      windowed path (`appliesYapinPromotion = !effectiveWindowed`),
///      so even if the sibling were available, no promotion would fire.
///
/// Both failure modes manifest at user-realistic sentence lengths — the
/// suite samples 15-40 char buffers across diverse topics (eating,
/// school, love, work, fame, travel, daily life) and across all eight
/// promotion clusters (`khwy`/`ghwy`/`khy`/`ghy`/`kwy`/`gwy`/`ky`/`gy`)
/// to make sure the fix is not specific to any single phrase shape.
public enum LongBufferYaPinPromotionSuite {

    private static let yaPin: UInt32 = 0x103B
    private static let yaYit: UInt32 = 0x103C

    private static func containsYaYit(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == yaYit }
    }

    /// Returns true when the surface's first medial marker (U+103B or
    /// U+103C) is ya-pin. Mid-buffer ya-yit clusters are tolerated —
    /// the cluster-promotion only fires at the START of the buffer
    /// (`bufferStartsWithYaPinCluster`), so non-leading occurrences
    /// of `py` / `ry` / inner `ky` etc. remain on whichever path
    /// their parser rule produces.
    private static func leadingMedialIsYaPin(_ surface: String) -> Bool {
        for scalar in surface.unicodeScalars {
            if scalar.value == yaPin { return true }
            if scalar.value == yaYit { return false }
        }
        return false
    }

    public static let suite = TestSuite(name: "LongBufferYaPinPromotion", cases: [

        // Sub-window (≤18 chars) failures driven purely by parser
        // N-best beam pruning. These buffers are short enough that
        // `effectiveWindowed` is false, but the ya-pin sibling has
        // already been pruned out of `parseCandidates` by the time
        // the engine runs `promoteYapinForExactBareReading`.
        // Topics: I-pronoun (m./f.), school, work, love.
        TestCase("bareEngine_subWindow_parserBeamLoss_yaPinTop") { ctx in
            let engine = BurmeseEngine()
            let buffers = [
                "kwyantawmainntal",     // 16 — "I'm busy"
                "kwyantawraysauttal",   // 18 — "I drink water"
                "kwyanmasayartal",      // 15 — "I'm tired (f.)"
                "kyaung:saryarmar",     // 16 — "school's letter"
                "kyaw:kyar:thawalok",   // 18 — "famous job"
                "khyitthukhyitthu",     // 16 — "love love (reduplicated)"
                "kwyantawkhyitthuko",   // 18 — "to my love (kwy + inner khy)"
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    leadingMedialIsYaPin(top),
                    buffer,
                    detail: "expected ya-pin (U+103B) at the leading-cluster position of rank 0 for \(buffer.count)-char buffer, got '\(top)'"
                )
            }
        },

        // Windowed (>18 chars), 20–29 chars: real-sentence inputs that
        // cross the sliding-window threshold. Diverse topics — eating,
        // travel, school, romance — and a mix of leading clusters
        // (`kwy`, `kwyanma`, `ky`, `kyaw`, `gy`). Exactly one buffer
        // covers the user-reported `kahtamin:masar:` ("eat rice")
        // case; the remaining buffers exercise different vocabulary.
        TestCase("bareEngine_windowed_20to29_yaPinTop") { ctx in
            let engine = BurmeseEngine()
            let buffers = [
                "kwyantawkahtamin:masar:",     // 23 — "I eat rice" (the originally reported buffer)
                "kwyantawgyapankothwar:",      // 22 — "I go to Japan"
                "kwyantawkyaung:kothwar:",     // 23 — "I go to school"
                "kwyantawmin:koeakhyittal",    // 24 — "I love you (m.)"
                "kwyanmamin:koeakhyittal",     // 23 — "I love you (f.)"
                "kyaung:thar:talkhainnay:",    // 24 — "be a student"
                "kyaw:kyar:thawsaryar",        // 20 — "famous teacher"
                "gyapan:gyaungkothwar:",       // 21 — "go to a Japan school"
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    leadingMedialIsYaPin(top),
                    buffer,
                    detail: "expected ya-pin (U+103B) at the leading-cluster position of rank 0 for windowed \(buffer.count)-char buffer, got '\(top)'"
                )
            }
        },

        // Windowed (>18 chars), 30–40 chars: extra-long inputs that
        // push well past the window boundary. The frozen prefix's LM
        // rendering plus the disambiguator-tiebreaker must still land
        // ya-pin at rank 0. None of these reuse the `kahtamin:masar:`
        // phrase — the topics span school life, fame, travel,
        // greetings, daily routine, and weariness, with leading
        // clusters chosen from `ky`, `kyaw`, `gy`, `kwy`, `kwyanma`.
        TestCase("bareEngine_windowed_30to40_yaPinTop") { ctx in
            let engine = BurmeseEngine()
            let buffers = [
                "kyaung:thartainthankharmaynaylar",        // 32 — "students playing nowadays"
                "kyaw:kyar:thawpyitparmaynaykwarphyithay", // 39 — "becoming famous"
                "gyapan:naynaylaylewparphyitparmal",       // 33 — "(it) is in Japan now"
                "kwyantawminkohomingalarparyaynaynay",     // 35 — "I greet you slowly"
                "kwyantawmykarmaynaykway:phyithawphyithay", // 40 — "I traveled today"
                "kwyanmamar:saryartainnaynaymainnaytay",   // 37 — "I'm a tired teacher (f.)"
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    leadingMedialIsYaPin(top),
                    buffer,
                    detail: "expected ya-pin (U+103B) at the leading-cluster position of rank 0 for \(buffer.count)-char buffer, got '\(top)'"
                )
            }
        },

        // The ya-yit sibling must remain reachable in the panel for
        // sub-window buffers (≤ compositionWindowSize, so non-windowed).
        // The promotion is a ranking flip, not a substitution — users
        // who want the ya-yit form must still be able to pick it from
        // the candidate panel. (Windowed buffers retain only one
        // frozen-prefix branch by design — `frozenPrefixBranchCount = 1`
        // — so this guarantee is intentionally limited to non-windowed
        // inputs.)
        TestCase("bareEngine_subWindow_yaYitSiblingReachable") { ctx in
            let engine = BurmeseEngine()
            let buffers = [
                "kwyantawmainntal",
                "kwyantawraysauttal",
                "kyaw:kyar:thawalok",
                "kyaung:saryarmar",
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                let any = state.candidates.contains { containsYaYit($0.surface) }
                ctx.assertTrue(
                    any,
                    buffer,
                    detail: "ya-yit sibling must remain reachable in the candidate panel for sub-window ya-pin-cluster buffer '\(buffer)'"
                )
            }
        },

        // Excluded clusters (`phy` / `phwy`) must NOT gain a ya-pin
        // promotion at long lengths. The fix applies only to the
        // eight clusters in `yaPinPreferredOnsetClusters`; everything
        // else stays on the structural `Cy` → ya-yit (or
        // alias-driven) rule. Topics chosen to be different from the
        // ya-pin set (food / philosophy / weather) so this isn't
        // structurally a mirror of the same phrases.
        TestCase("bareEngine_long_excludedClusters_unchanged") { ctx in
            let engine = BurmeseEngine()
            let phyBuffers = [
                "phyantawmin:kowmar:tarbu:",  // 25 — `phy` excluded cluster
                "phwyaymyathwarkanntoesoe:",  // 25 — `phwy` excluded cluster
            ]
            for buffer in phyBuffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    containsYaYit(top),
                    buffer,
                    detail: "expected ya-yit (U+103C) at rank 0 for excluded cluster on long buffer, got '\(top)'"
                )
                ctx.assertFalse(
                    leadingMedialIsYaPin(top),
                    buffer,
                    detail: "ya-pin (U+103B) must not be the leading medial for excluded-cluster buffer '\(buffer)', got '\(top)'"
                )
            }
        },

        // Plain `Cw…` long buffers without a following `y` must NOT
        // trigger any ya-pin promotion. `kwantawkahtamin:masar:` and
        // siblings carry medial-wa with no medial-ya — neither ya-pin
        // nor ya-yit appears at rank 0.
        TestCase("bareEngine_long_plainCwBuffers_unchanged") { ctx in
            let engine = BurmeseEngine()
            let buffers = [
                "kwantawmin:kosohkya:tarbu:",   // 26 — plain kw + medial-wa
                "khwantawayparayyahmar",         // 21 — plain khw
                "gwantawalokloktayyhmar",        // 22 — plain gw
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertFalse(
                    leadingMedialIsYaPin(top),
                    buffer,
                    detail: "plain Cw long buffer must not be promoted to ya-pin, got '\(top)'"
                )
            }
        },
    ])
}
