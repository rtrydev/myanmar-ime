import Foundation

extension SyllableParser {

    // MARK: - N-best DP Parse

    /// Bucket at a single DP position. Holds arena indices only — the arena
    /// (shared across all buckets in one parse) is where `ParseState` values
    /// live. Buckets grow until they exceed `limit * 2`, at which point
    /// `pruneBucket` drops everything below the top `limit` by score.
    internal struct DPBucket {
        var stateIndices: [Int32] = []
        var needsPrune = false
    }

    /// Pack two 32-bit ids into a single dictionary key. Callers are
    /// responsible for treating each half as unsigned.
    @inline(__always)
    internal static func packPair(_ a: Int32, _ b: Int32) -> UInt64 {
        (UInt64(UInt32(bitPattern: a)) << 32) | UInt64(UInt32(bitPattern: b))
    }

    internal func nBestParse(
        _ chars: [Character],
        onsetMatchesByStart: [[OnsetMatch]],
        vowelMatchesByStart: [[VowelMatch]],
        maxResults: Int,
        allowLiberalStacks: Bool = false
    ) -> (arena: [ParseState], finalIndices: [Int32]) {
        var (arena, dp) = runDP(
            chars,
            onsetMatchesByStart: onsetMatchesByStart,
            vowelMatchesByStart: vowelMatchesByStart,
            maxResults: maxResults,
            allowLiberalStacks: allowLiberalStacks
        )
        let n = chars.count
        if dp[n].needsPrune {
            pruneBucket(&dp[n], arena: arena, limit: maxResults)
        }
        return (arena, dp[n].stateIndices)
    }

    /// Run the N-best DP and return the raw arena + per-position buckets.
    /// Callers that only need the final bucket should use `nBestParse`;
    /// callers that walk intermediate positions (e.g.
    /// `parseLongestAcceptablePrefix`) use this variant.
    internal func runDP(
        _ chars: [Character],
        onsetMatchesByStart: [[OnsetMatch]],
        vowelMatchesByStart: [[VowelMatch]],
        maxResults: Int,
        allowLiberalStacks: Bool = false
    ) -> (arena: [ParseState], dp: [DPBucket]) {
        let n = chars.count
        var arena: [ParseState] = []
        arena.reserveCapacity(max(n * maxResults / 4, 64))
        var dp = [DPBucket](repeating: DPBucket(), count: n + 1)

        // Seed
        let seedIdx = Int32(arena.count)
        arena.append(ParseState(
            parentIdx: -1,
            matchRef: .seed,
            charEnd: 0,
            score: 0,
            legalityScore: 0,
            aliasCost: 0,
            syllableCount: 0,
            structureCost: 0,
            isLegal: true
        ))
        dp[0].stateIndices.append(seedIdx)

        // Lazy legality cache for paired (onsetId, vowelId). Bare-onset and
        // standalone-vowel cases are already pre-computed at init time.
        var pairLegality: [UInt64: Int] = [:]

        // Virama-stack validation can only fire if the buffer contains a
        // "+" connector. Precompute this once so the common case (plain
        // buffers, including the worst-case "garbage" scenario) skips the
        // per-state match-ref inspection entirely.
        let hasViramaInBuffer = chars.contains("+")

        for i in 0..<n {
            guard !dp[i].stateIndices.isEmpty else { continue }

            if dp[i].needsPrune {
                pruneBucket(&dp[i], arena: arena, limit: maxResults)
            }

            let onsetMatches = onsetMatchesByStart[i]
            let standaloneVowels = vowelMatchesByStart[i]
            // Snapshot — the bucket's stateIndices is mutated by insertState
            // into downstream buckets, but we only read dp[i] here.
            let prevIndices = dp[i].stateIndices
            for prevIdx in prevIndices {
                let previous = arena[Int(prevIdx)]
                var matched = false

                // If the previous syllable ended with a virama connector
                // ("+"), the next onset is the subscript of a virama stack
                // and must be validated against the upper consonant.
                // Cross-class stacks (e.g. က္ယ, က္ဝ, က္ဿ) fall outside the
                // native subscript model; force their onset legality to 0
                // so the resulting parse drops below the legality
                // threshold. The DP admits several DP shapes that reach
                // the virama:
                //   - `.onsetVowel(X, +)` — onset glued with virama
                //   - `.onsetOnly(X) → .vowelOnly(+)` — split path, X is upper
                //   - `.onsetVowel(X, asatV) → .vowelOnly(+)` — kinzi
                //   - `.onsetVowel(X, plainV) → .vowelOnly(+)` — illegal:
                //      virama cannot bond to a dependent vowel sign, so the
                //      transition must be rejected outright regardless of
                //      whether X happens to be same-class as the lower.
                //   - `.vowelOnly(asatV) → .vowelOnly(+)` — kinzi via split
                //   - `.vowelOnly(plainV) → .vowelOnly(+)` — illegal: same
                //      reason as above.
                let viramaCtx = hasViramaInBuffer
                    ? viramaContext(previous: previous, arena: arena)
                    : .none

                for (onsetEnd, onsetEntry) in onsetMatches {
                    let stackLegal: Bool
                    switch viramaCtx {
                    case .upper(let upper):
                        stackLegal = isValidStack(
                            upper: upper,
                            lower: onsetEntry.onset,
                            allowLiberalStacks: allowLiberalStacks
                        )
                    case .reject:
                        stackLegal = false
                    case .none:
                        stackLegal = true
                    }
                    let onsetLegality = stackLegal
                        ? onsetBareLegality[Int(onsetEntry.id)]
                        : 0
                    let newState = ParseState(
                        parentIdx: prevIdx,
                        matchRef: .onsetOnly(onsetId: onsetEntry.id),
                        charEnd: Int32(onsetEnd),
                        score: previous.score + scoreMatch(
                            consumed: onsetEnd - i,
                            ruleCount: 1,
                            legality: onsetLegality,
                            aliasCost: onsetEntry.aliasCost
                        ),
                        legalityScore: previous.legalityScore + max(onsetLegality, 0),
                        aliasCost: previous.aliasCost + onsetEntry.aliasCost,
                        syllableCount: previous.syllableCount + 1,
                        structureCost: previous.structureCost + onsetEntry.structureCost,
                        isLegal: previous.isLegal && onsetLegality > 0
                    )
                    insertState(&arena, &dp, at: onsetEnd, state: newState, limit: maxResults)
                    matched = true

                    let vowelMatches = vowelMatchesByStart[onsetEnd]
                    for (vowelEnd, vowelEntry) in vowelMatches {
                        // Soft-boundary `+` fallback is only ever emitted as
                        // a standalone vowelOnly transition, where its
                        // emission is gated on a digraph-collision check
                        // (see below). Skipping it here prevents redundant
                        // onset-glued pair states that would bypass the gate.
                        if vowelEntry.id == softBoundaryViramaVowelId { continue }
                        let key = Self.packPair(onsetEntry.id, vowelEntry.id)
                        let pairLegalityRaw: Int
                        if let cached = pairLegality[key] {
                            pairLegalityRaw = cached
                        } else {
                            pairLegalityRaw = Grammar.validateSyllable(
                                onset: onsetEntry.onset,
                                medials: onsetEntry.medials,
                                vowelRoman: vowelEntry.canonicalRoman
                            )
                            pairLegality[key] = pairLegalityRaw
                        }
                        let legality = stackLegal ? pairLegalityRaw : 0
                        // TASK-007 (paired-arc branch): the same standalone
                        // particle / independent-vowel rules that the
                        // standalone-vowel loop guards against can also
                        // fire as the vowel half of an `onsetVowel(X, ei)`
                        // /`onsetVowel(X, oo)` paired arc — the parser's
                        // primary path for `monein` / `kein` / `phei`
                        // etc. The paired arc emits BOTH the consonant
                        // base AND the standalone-particle scalar in a
                        // single transition, so the surface always has
                        // the polluting structural shape `<consonant>
                        // <standalone>` which is structurally invalid
                        // Burmese (independent vowels and free-standing
                        // particles never sit immediately after a
                        // consonant base inside a syllable). Skip the
                        // transition entirely. The bare-standalone
                        // fallback (`ei` typed alone) reaches the
                        // panel through the standalone-vowel loop with
                        // `previous = seed`, not through this paired-
                        // arc branch.
                        if vowelIsMidBufferPenalised[Int(vowelEntry.id)] {
                            continue
                        }
                        let pairState = ParseState(
                            parentIdx: prevIdx,
                            matchRef: .onsetVowel(onsetId: onsetEntry.id, vowelId: vowelEntry.id),
                            charEnd: Int32(vowelEnd),
                            score: previous.score + scoreMatch(
                                consumed: vowelEnd - i,
                                ruleCount: 2,
                                legality: legality,
                                aliasCost: onsetEntry.aliasCost + vowelEntry.aliasCost
                            ),
                            legalityScore: previous.legalityScore + max(legality, 0),
                            aliasCost: previous.aliasCost + onsetEntry.aliasCost + vowelEntry.aliasCost,
                            syllableCount: previous.syllableCount + 1,
                            structureCost: previous.structureCost + onsetEntry.structureCost,
                            isLegal: previous.isLegal && legality > 0
                        )
                        insertState(&arena, &dp, at: vowelEnd, state: pairState, limit: maxResults)
                        matched = true
                    }
                }

                let previousEndedWithVowel: Bool
                switch previous.matchRef {
                case .onsetVowel, .vowelOnly: previousEndedWithVowel = true
                default: previousEndedWithVowel = false
                }

                for (vowelEnd, vowelEntry) in standaloneVowels where !vowelEntry.isPureMedial {
                    // Gate the empty-emission `+` fallback. Two cases:
                    //   - After a kinzi/asat vowel: digraph collision
                    //     (legal short stack + unstackable long onset).
                    //   - After a plain vowel: syllable-break when the
                    //     virama stack is cross-class illegal OR the
                    //     digraph collision exists.
                    // After a bare `onsetOnly(X)` the user has typed no
                    // vowel, so a virama stack is the natural reading and
                    // the soft-boundary must not fire.
                    if vowelEntry.id == softBoundaryViramaVowelId {
                        let sbCtx = softBoundaryContext(previous: previous, arena: arena)
                        // Admission rule depends on predecessor category:
                        //   - seedOnset(stackable): stacker when a same-
                        //     class lower follows; cross-class or non-
                        //     stackable lower falls through to a break
                        //     so the tail isn't right-shrunk away.
                        //   - seedOnset(non-stackable): stack is
                        //     structurally impossible (`ah+dhi`); admit
                        //     whenever a valid onset follows.
                        //   - asatVowel: fire on digraph collision or
                        //     cross-class illegal stack — either makes
                        //     the user-typed `+` a break rather than an
                        //     impossible virama.
                        //   - plainVowel: fire on cross-class illegal or
                        //     digraph collision (`ka+ta+pa`, `mar+ta`).
                        enum AdmitMode { case unconditional, digraphOnly, crossClassOrDigraph }
                        let upperForGate: Character?
                        let admit: AdmitMode
                        switch sbCtx {
                        case .none:
                            continue
                        case .seedOnset(let ch):
                            // Stackable seed onset: honour the stack when
                            // a same-class lower is available, otherwise
                            // admit the break so `k+tar`, `p+tar`, etc.
                            // survive as two syllables instead of being
                            // pruned by right-shrink.
                            if Grammar.stackableConsonants.contains(ch) {
                                upperForGate = ch
                                admit = .crossClassOrDigraph
                            } else {
                                upperForGate = nil
                                admit = .unconditional
                            }
                        case .asatVowel(let ch):
                            if Grammar.stackableConsonants.contains(ch) {
                                upperForGate = ch
                                admit = .crossClassOrDigraph
                            } else {
                                upperForGate = nil
                                admit = .unconditional
                            }
                        case .plainVowel:
                            // Plain dependent vowel sign between the
                            // base consonant and `+`: virama cannot
                            // bond to a vowel sign, so `+` is always
                            // a syllable break regardless of the
                            // onset that follows.
                            upperForGate = nil
                            admit = .unconditional
                        }

                        let onsetsAtVowelEnd = onsetMatchesByStart[vowelEnd]
                        guard !onsetsAtVowelEnd.isEmpty else { continue }

                        if admit != .unconditional, let upper = upperForGate {
                            var hasShortLegal = false
                            var hasLongUnstackable = false
                            for (oEnd, oEntry) in onsetsAtVowelEnd {
                                let len = oEnd - vowelEnd
                                if len == 1
                                    && isValidStack(
                                        upper: upper,
                                        lower: oEntry.onset,
                                        allowLiberalStacks: allowLiberalStacks
                                    ) {
                                    hasShortLegal = true
                                }
                                if len >= 2
                                    && !Grammar.stackableConsonants.contains(oEntry.onset) {
                                    hasLongUnstackable = true
                                }
                            }
                            let digraphCollision = hasShortLegal && hasLongUnstackable
                            switch admit {
                            case .digraphOnly:
                                guard digraphCollision else { continue }
                            case .crossClassOrDigraph:
                                let crossClassIllegal = !hasShortLegal
                                guard crossClassIllegal || digraphCollision else { continue }
                            case .unconditional:
                                break
                            }
                        }
                    }

                    var legality = vowelOnlyLegality[Int(vowelEntry.id)]

                    // Kinzi rule: U+103A (asat) immediately before U+1039
                    // (virama) is legal only when the character two positions
                    // back is U+1004 (nga). Anything else is a stacking
                    // artifact from the DP combining an asat-final vowel with
                    // a virama vowel. Zero legality so the virama-only
                    // alternative wins when the beam holds both.
                    if vowelEntry.id == viramaVowelId {
                        var prevTrailsAsat = false
                        var prevPreAsat: UInt32 = 0
                        switch previous.matchRef {
                        case .onsetVowel(let onsetId, let vowelId):
                            if vowelEndsWithAsat[Int(vowelId)] {
                                prevTrailsAsat = true
                                let pre = vowelPreAsatScalar[Int(vowelId)]
                                prevPreAsat = pre != 0 ? pre : onsetLastScalar[Int(onsetId)]
                            }
                        case .vowelOnly(let vowelId):
                            if vowelEndsWithAsat[Int(vowelId)] {
                                prevTrailsAsat = true
                                prevPreAsat = vowelPreAsatScalar[Int(vowelId)]
                            }
                        default:
                            break
                        }
                        if prevTrailsAsat && prevPreAsat != 0x1004 {
                            legality = 0
                        }
                    }
                    // Stacking a dependent vowel sign onto a syllable that
                    // already carries a vowel is orthographically unusual,
                    // but legal — the glyph exists and users occasionally
                    // want it. Add an aliasCost penalty at the final
                    // transition so a standalone-vowel alternative (e.g.
                    // ဥ via `u2.`) outranks it when both are available.
                    //
                    // TASK-046: when the previous arc was a multi-scalar
                    // bare-diphthong rule (`aing`, `aung`, `ai`) ending
                    // in `<nga> 103A` AND the current arc is also a
                    // bare-diphthong vowelOnly rule, the stackedFinal
                    // penalty would unfairly demote the user-intended
                    // chained-bare-diphthong parse (`aing + aing`)
                    // against a re-segmented sibling (`ain + gaing`)
                    // that doesn't pay it. Carve out only that
                    // structural shape; ordinary `<C>aaY` stacking and
                    // `an + ar` (closed-syllable + bare-vowel) keep the
                    // existing penalty so their established rankings
                    // are preserved.
                    let prevWasBareDiphthongShape: Bool = {
                        guard case .vowelOnly(let prevId) = previous.matchRef else {
                            return false
                        }
                        guard vowelEndsWithAsat[Int(prevId)] else { return false }
                        // The diphthong-shape rules are the multi-scalar
                        // standalones (`aing`, `aung`, `ai`) — at least
                        // 4 scalars in their Myanmar output AND the
                        // scalar before the asat closer is `nga` (1004).
                        let entry = vowelTerminals[Int(prevId)]
                        let scalars = Array(entry.myanmar.unicodeScalars)
                        guard scalars.count >= 4 else { return false }
                        guard scalars[scalars.count - 2].value == 0x1004 else { return false }
                        return true
                    }()
                    let stackedFinal =
                        !vowelEntry.isStandalone
                        && previousEndedWithVowel
                        && !prevWasBareDiphthongShape
                        && vowelEnd == n
                    // TASK-007: skip the transition entirely when a
                    // standalone vowel rule whose Myanmar output begins
                    // with an independent-vowel scalar (U+1023..U+102A)
                    // or a free-standing particle (U+104D / U+104F)
                    // would land between consonant bases. Two trigger
                    // shapes: (a) the previous state is non-seed
                    // (already-emitted Burmese context), or (b) more
                    // buffer follows so the standalone scalar will sit
                    // mid-surface once subsequent onsets land. Skipping
                    // the transition (rather than charging an alias-
                    // cost or zeroing legality) avoids both DP bucket
                    // pressure and the materialized `isBetter`
                    // comparator's syllable-count override that would
                    // otherwise float a polluted parse to rank 0. Bare
                    // standalone usage (`ei`, `ywe`, `oo` typed alone)
                    // is unaffected because both gates fail.
                    if vowelIsMidBufferPenalised[Int(vowelEntry.id)] {
                        let previousIsSeed: Bool = {
                            if case .seed = previous.matchRef { return true }
                            return false
                        }()
                        if !previousIsSeed || vowelEnd < n { continue }
                    }
                    // TASK-009: a standalone vowel whose Myanmar output
                    // begins with an independent-vowel scalar
                    // (U+1023..U+102A) AND whose canonical bears a
                    // numeric disambiguator (e.g. the digit-stripped
                    // alias of `u2 → ဦ` registered under trie key
                    // `"u"`) is intentionally NOT tagged by the
                    // TASK-007 gate above — two-syllable shapes like
                    // `thiu` need it to fire after a real vowel-mark-
                    // ending arc to produce `သီဦ`. But when the
                    // previous arc is a `vowelOnly` with empty Myanmar
                    // emission (the inherent-`a` rule, the only such
                    // entry today), the standalone rule lands directly
                    // after an empty position — equivalent to firing
                    // at the start of a new syllable with no anchor.
                    // This is the cross-task interaction surfaced by
                    // TASK-009 where `kar:au` splits into
                    // `[kar:][au]`, the suffix `au` parses as
                    // inherent-A + standalone-u, and the materialized
                    // output is `[1021 1026]` (independent A + 1026)
                    // — concatenated with the visarga prefix it
                    // produces `ကားအဦ`. Skipping the standalone here
                    // forces the dependent-vowel sibling (`u → 1030`)
                    // to win, giving the expected `ကားအူ`.
                    //
                    // Narrowly scoped: only fires when the standalone
                    // vowel produces an independent-vowel scalar
                    // (1023..102A) AND the previous arc is `vowelOnly`
                    // with empty emission. Free-standing particles
                    // (`104D / 104F`) and any non-empty previous arc
                    // are unaffected.
                    var standaloneAfterEmptyAliasPenalty = 0
                    var standaloneAfterEmptyForceMin = false
                    if vowelEntry.isStandalone,
                       let firstOut = vowelEntry.myanmar.unicodeScalars.first,
                       firstOut.value >= 0x1023 && firstOut.value <= 0x102A {
                        let predecessorEmptyEmission: Bool = {
                            switch previous.matchRef {
                            case .vowelOnly(let prevVowelId):
                                return vowelTerminals[Int(prevVowelId)].myanmar.isEmpty
                            case .onsetVowel(_, let prevVowelId):
                                return vowelTerminals[Int(prevVowelId)].myanmar.isEmpty
                            default:
                                return false
                            }
                        }()
                        if predecessorEmptyEmission {
                            switch previous.matchRef {
                            case .vowelOnly:
                                // TASK-009 (original carve-out): skip
                                // outright. The visarga-prefix path
                                // doesn't need a panel sibling — the
                                // user reached the indep-vowel form
                                // through the bare-vowel input,
                                // not through `<C>aa<vowel>`.
                                continue
                            case .onsetVowel:
                                // TASK-020: don't skip — demote both
                                // alias cost AND legality magnitude so
                                // the dep-vowel sibling wins rank 0
                                // but the free-standing form remains
                                // reachable at lower rank for users
                                // who explicitly want it. The TASK-009
                                // visarga skip can stay strict because
                                // there's no buffer-leading bare-vowel
                                // path to recover the form; the
                                // `<C>aaY` path needs the panel
                                // sibling per TASK-020 acceptance.
                                standaloneAfterEmptyAliasPenalty = 64
                                standaloneAfterEmptyForceMin = true
                            default:
                                break
                            }
                        }
                    }
                    // TASK-016: reject chained inherent-`a` arcs — i.e.
                    // a `vowelOnly(inherent-a)` transition after a
                    // previous arc that already consumed an
                    // inherent-`a` (either an `onsetVowel` whose vowel
                    // was inherent-`a`, or another bare inherent-`a`
                    // `vowelOnly`). The bare-inherent-`a` rule emits
                    // empty surface, so chaining produces the same
                    // surface scalar count as the no-chain parse —
                    // the user's repeated `a` keystrokes silently
                    // disappear (`kaa` → `က`, `kaaa` → `က`). Rejecting
                    // forces the right-shrink probe to drop the
                    // trailing `a`(s) and reattach them as a literal
                    // tail.
                    //
                    // Carve-out: buffer-leading `aa…` chains (no
                    // consonant onset anywhere in the parent chain)
                    // are LEGAL — the leading-A promotion converts the
                    // empty output to `1021`, giving the user a
                    // visible glyph that represents the typing. Walk
                    // back through `parentIdx` to verify a consonant
                    // arc exists before rejecting.
                    if inherentAVowelId >= 0,
                       vowelEntry.id == inherentAVowelId {
                        let previousConsumedInherentA: Bool = {
                            switch previous.matchRef {
                            case .onsetVowel(_, let prevVowelId):
                                return prevVowelId == inherentAVowelId
                            case .vowelOnly(let prevVowelId):
                                return prevVowelId == inherentAVowelId
                            default:
                                return false
                            }
                        }()
                        if previousConsumedInherentA {
                            // Walk back to detect a consonant arc.
                            var ancestor = previous
                            var hasConsonantAncestor = false
                            // Cap the walk depth to avoid pathological
                            // O(n) worst case on every transition; the
                            // depth in practice is bounded by the
                            // input length and an inherent-A chain
                            // can only be a few levels deep before
                            // this guard fires.
                            var depth = 0
                            while ancestor.parentIdx >= 0, depth < 8 {
                                switch ancestor.matchRef {
                                case .onsetOnly, .onsetVowel:
                                    hasConsonantAncestor = true
                                default:
                                    break
                                }
                                if hasConsonantAncestor { break }
                                ancestor = arena[Int(ancestor.parentIdx)]
                                depth += 1
                            }
                            if hasConsonantAncestor {
                                continue
                            }
                        }
                    }
                    // TASK-026: generalisation of TASK-016 for the
                    // four other bare-vowel letters (`i`, `u`, `e`,
                    // `o`). When the user types `<C><X><X>` (a
                    // consonant followed by the same bare vowel
                    // letter twice), the DP picks one of two
                    // chained shapes that both materialise as a
                    // malformed multi-anchor or doubled coda-asat
                    // surface (`ကီည်`, `ကူဦ`, `ကယ်ယ်`, `ကိုအို`):
                    //
                    //   (a) `onsetVowel(C, X) + vowelOnly(X')` —
                    //       the consonant onset consumes the first
                    //       `X`, the second `X` chains as a
                    //       standalone `vowelOnly` arc whose
                    //       canonical may be a different suffix
                    //       variant (e.g. `i` paired with the
                    //       consonant, `i2` standalone).
                    //
                    //   (b) `onsetVowel(C, a) + vowelOnly(X) + vowelOnly(X')`
                    //       — the consonant onset takes the
                    //       inherent `a`, then two `vowelOnly` arcs
                    //       consume `XX`. This shape produces the
                    //       same malformed surface and must be
                    //       rejected so the inherent-A path doesn't
                    //       become an alternate route to the bug
                    //       once shape (a) is gated off.
                    //
                    // No Burmese typist intends either shape — the
                    // user wants the long-vowel form or a clean
                    // recovery via the engine's literal-tail
                    // trimming.
                    //
                    // Reject the chain whenever:
                    //   - the current `vowelOnly` arc consumed a
                    //     single ASCII letter at position `i`,
                    //   - that letter is one of `i`/`u`/`e`/`o`,
                    //   - and either:
                    //       - previous = `onsetVowel` whose last
                    //         consumed input letter equals the
                    //         current letter (shape a), or
                    //       - previous = `vowelOnly` whose last
                    //         consumed input letter equals the
                    //         current letter, AND grand-parent =
                    //         `onsetVowel` taking the inherent-`a`
                    //         vowel (shape b — anchors the pattern
                    //         to a real `<C>VV` typing site rather
                    //         than a mid-buffer doubled-vowel run
                    //         after a vowel-bearing syllable).
                    //
                    // Buffer-leading doubled-vowel inputs (`ee`,
                    // `oo`, …) are unaffected because there is no
                    // `onsetVowel` ancestor at all; they reach the
                    // panel via `bareVowelOverrideSurface`.
                    // Mid-buffer doubled vowels after a vowel-
                    // bearing syllable (e.g. `larme.oogotel` —
                    // `oo` after `me.`) are unaffected because the
                    // chained `vowelOnly + vowelOnly` predecessor
                    // is not anchored on an inherent-`a`
                    // `onsetVowel`.
                    //
                    // The chars-based check (instead of comparing
                    // vowel terminal IDs as TASK-016 does) handles
                    // the variant-suffix case where the current arc
                    // uses a *different* vowel terminal for the
                    // matching input letter (`i` vs `i2`, `u` vs
                    // `u2`, …). Without this, the parser silently
                    // produces the malformed surface.
                    if vowelEnd - i == 1 {
                        let cur = chars[i]
                        let isOtherBareVowel = cur == "i" || cur == "u"
                            || cur == "e" || cur == "o"
                        if isOtherBareVowel {
                            let prevEnd = Int(previous.charEnd)
                            let prevLastLetterMatches = prevEnd >= 1
                                && prevEnd <= chars.count
                                && chars[prevEnd - 1] == cur
                            // Shape (a): previous is onsetVowel
                            // ending on the matching letter.
                            let shapeA: Bool = {
                                if case .onsetVowel = previous.matchRef,
                                   prevLastLetterMatches {
                                    return true
                                }
                                return false
                            }()
                            // Shape (b): previous is vowelOnly
                            // ending on the matching letter, AND
                            // grand-parent is a consonant arc that
                            // took the inherent `a` (either an
                            // explicit `onsetVowel(C, a)` or a bare
                            // `onsetOnly(C)` whose syllable is the
                            // inherent-`a` open form).
                            let shapeB: Bool = {
                                guard prevLastLetterMatches,
                                      previous.parentIdx >= 0,
                                      case .vowelOnly = previous.matchRef
                                else {
                                    return false
                                }
                                let grandparent = arena[Int(previous.parentIdx)]
                                switch grandparent.matchRef {
                                case .onsetOnly:
                                    return true
                                case .onsetVowel(_, let prevVowelId):
                                    return inherentAVowelId >= 0
                                        && prevVowelId == inherentAVowelId
                                default:
                                    return false
                                }
                            }()
                            if shapeA || shapeB {
                                continue
                            }
                        }
                    }
                    let aliasCostAdj = vowelEntry.aliasCost
                        + (stackedFinal ? 2 : 0)
                        + standaloneAfterEmptyAliasPenalty
                    // TASK-020: cap the legality contribution of a
                    // post-empty-emission standalone vowel at 1 so the
                    // engine's grammar comparator (which prefers
                    // higher legalityScore among equal-syllableCount
                    // candidates) does not promote it over the dep-
                    // vowel sibling. Legality stays >0 so the parse
                    // remains acceptable and the candidate is
                    // reachable in the panel — just not at rank 0.
                    let effectiveLegality = standaloneAfterEmptyForceMin
                        ? min(legality, 1)
                        : legality
                    let newState = ParseState(
                        parentIdx: prevIdx,
                        matchRef: .vowelOnly(vowelId: vowelEntry.id),
                        charEnd: Int32(vowelEnd),
                        score: previous.score + scoreMatch(
                            consumed: vowelEnd - i,
                            ruleCount: 1,
                            legality: effectiveLegality,
                            aliasCost: aliasCostAdj
                        ),
                        legalityScore: previous.legalityScore + max(effectiveLegality, 0),
                        aliasCost: previous.aliasCost + aliasCostAdj,
                        syllableCount: previous.syllableCount + 1,
                        structureCost: previous.structureCost,
                        isLegal: previous.isLegal && effectiveLegality > 0
                    )
                    insertState(&arena, &dp, at: vowelEnd, state: newState, limit: maxResults)
                    matched = true
                }

                if !matched {
                    let newState = ParseState(
                        parentIdx: prevIdx,
                        matchRef: .skip,
                        charEnd: Int32(i + 1),
                        score: previous.score - 100,
                        legalityScore: previous.legalityScore,
                        aliasCost: previous.aliasCost,
                        syllableCount: previous.syllableCount,
                        structureCost: previous.structureCost,
                        isLegal: false
                    )
                    insertState(&arena, &dp, at: i + 1, state: newState, limit: maxResults)
                }
            }
        }

        return (arena, dp)
    }

    @inline(__always)
    internal func isValidStack(
        upper: Character,
        lower: Character,
        allowLiberalStacks: Bool
    ) -> Bool {
        allowLiberalStacks
            ? Grammar.isValidStackLiberal(upper: upper, lower: lower)
            : Grammar.isValidStack(upper: upper, lower: lower)
    }

    // MARK: - Virama Context

    /// Outcome of inspecting a DP state that may precede a virama (`+`)
    /// transition. Drives the stack-class check on the following onset.
    internal enum ViramaContext {
        /// Previous state ended with a virama; the given character is the
        /// upper consonant of the stack. Run `isValidStack` against the
        /// lower onset.
        case upper(Character)
        /// Previous state ended with a virama glued to a scalar that
        /// cannot serve as a stack upper (dependent vowel sign,
        /// independent vowel, anusvara, asat on a non-nga base, ...).
        /// The following onset must be treated as illegal regardless of
        /// its class.
        case reject
        /// Previous state did not end with a virama; no stack check.
        case none
    }

    /// Derive the stack-upper for a potential virama transition. The upper
    /// sits *immediately* above the virama scalar — not necessarily the
    /// current syllable's onset. Three structural cases reach the virama:
    ///
    ///   1. `onsetVowel(X, +)` — onset glued to virama in one match.
    ///   2. `onsetOnly(X) → vowelOnly(+)` — onset followed by standalone
    ///      virama. No intervening vowel, so upper = onset.
    ///   3. `...Vowel(V) → vowelOnly(+)` — a vowel sign sits between the
    ///      onset and the virama. This is legal only for kinzi, where the
    ///      vowel is asat-ending (e.g. `in` renders as U+1004 U+103A) and
    ///      the real upper is the scalar embedded in the vowel's render
    ///      (tracked as `vowelPreAsatScalar`). Any plain dependent vowel,
    ///      independent vowel, or anusvara before a virama is malformed
    ///      Burmese — reject the transition outright.
    internal func viramaContext(
        previous: ParseState,
        arena: [ParseState]
    ) -> ViramaContext {
        switch previous.matchRef {
        case let .onsetVowel(onsetId, vowelId) where vowelId == viramaVowelId:
            return .upper(onsetTerminals[Int(onsetId)].onset)

        case let .vowelOnly(vowelId)
            where vowelId == viramaVowelId && previous.parentIdx >= 0:
            switch arena[Int(previous.parentIdx)].matchRef {
            case let .onsetOnly(onsetId):
                return .upper(onsetTerminals[Int(onsetId)].onset)

            case let .onsetVowel(onsetId, parentVowelId):
                guard vowelEndsWithAsat[Int(parentVowelId)] else {
                    return .reject
                }
                let pre = vowelPreAsatScalar[Int(parentVowelId)]
                let scalar = pre != 0 ? pre : onsetLastScalar[Int(onsetId)]
                guard let ch = Unicode.Scalar(scalar).map(Character.init) else {
                    return .reject
                }
                return .upper(ch)

            case let .vowelOnly(parentVowelId):
                guard vowelEndsWithAsat[Int(parentVowelId)] else {
                    return .reject
                }
                let pre = vowelPreAsatScalar[Int(parentVowelId)]
                guard pre != 0,
                      let ch = Unicode.Scalar(pre).map(Character.init) else {
                    return .reject
                }
                return .upper(ch)

            default:
                // `seed`, `skip`, or any other unexpected parent means the
                // virama has no real consonant above it.
                return .reject
            }

        default:
            return .none
        }
    }

    /// Classification of a DP state that might precede a soft-boundary
    /// `+`. Distinguishes three structurally different predecessors so
    /// the gate can pick the right admission rule:
    ///
    ///   - `.seedOnset` — onsetOnly(X) whose parent is the seed. User
    ///     typed no vowel and no preceding syllable, so `+` is a virama
    ///     stacker (e.g. `k+ya` must stay illegal rather than collapse
    ///     to `ကယ`).
    ///   - `.asatVowel(X)` — previous ended with an asat-bearing vowel
    ///     (kinzi lead-in) or a bare onset after a full syllable
    ///     (coda-like position). Soft-boundary fires only on digraph
    ///     collision.
    ///   - `.plainVowel(X)` — previous ended with a plain dependent
    ///     vowel. Soft-boundary fires when the virama stack is
    ///     cross-class illegal or subject to a digraph collision.
    ///   - `.none` — no usable stack upper (seed, skip, ...).
    internal enum SoftBoundaryContext {
        case seedOnset(Character)
        case asatVowel(Character)
        case plainVowel(Character)
        case none
    }

    /// Classify the predecessor of a hypothetical soft-boundary `+` so
    /// the DP gate can decide whether the `+` should be treated as a
    /// stacker, a syllable break, or rejected outright.
    internal func softBoundaryContext(
        previous: ParseState,
        arena: [ParseState]
    ) -> SoftBoundaryContext {
        switch previous.matchRef {
        case let .onsetOnly(onsetId):
            let upper = onsetTerminals[Int(onsetId)].onset
            // First onset after seed is the user's initial keystroke,
            // so `+` is clearly a stacker. Later bare onsets (coda-like
            // shape after a full syllable) behave like asat-vowel
            // predecessors for gating purposes.
            guard previous.parentIdx >= 0 else { return .seedOnset(upper) }
            if case .seed = arena[Int(previous.parentIdx)].matchRef {
                return .seedOnset(upper)
            }
            return .asatVowel(upper)

        case let .onsetVowel(onsetId, vowelId):
            if vowelEndsWithAsat[Int(vowelId)] {
                let pre = vowelPreAsatScalar[Int(vowelId)]
                let scalar = pre != 0 ? pre : onsetLastScalar[Int(onsetId)]
                guard let ch = Unicode.Scalar(scalar).map(Character.init) else { return .none }
                return .asatVowel(ch)
            }
            let scalar = onsetLastScalar[Int(onsetId)]
            guard let ch = Unicode.Scalar(scalar).map(Character.init) else { return .none }
            return .plainVowel(ch)

        case let .vowelOnly(vowelId):
            if vowelEndsWithAsat[Int(vowelId)] {
                let pre = vowelPreAsatScalar[Int(vowelId)]
                guard pre != 0,
                      let ch = Unicode.Scalar(pre).map(Character.init) else { return .none }
                return .asatVowel(ch)
            }
            // Plain vowelOnly: walk back to the parent onset for the
            // would-be stack upper. The split path `onsetOnly(X) →
            // vowelOnly(V)` is the only shape that yields a usable
            // upper here; anything else (vowelOnly after seed, kinzi
            // chains, ...) can't be a plain-vowel syllable break.
            guard previous.parentIdx >= 0 else { return .none }
            if case let .onsetOnly(onsetId) = arena[Int(previous.parentIdx)].matchRef {
                let scalar = onsetLastScalar[Int(onsetId)]
                guard let ch = Unicode.Scalar(scalar).map(Character.init) else { return .none }
                return .plainVowel(ch)
            }
            return .none

        default:
            return .none
        }
    }

    // MARK: - DP Scoring

    /// Score a match. Mirrors the legacy engine: score = sum(pronunciation_lengths) - rule_count.
    /// `ruleCount` is how many atomic rules this match represents (1 for onset-only or vowel-only,
    /// 2 for onset+vowel combined).
    internal func scoreMatch(consumed: Int, ruleCount: Int, legality: Int, aliasCost: Int) -> Int {
        var score = consumed - ruleCount
        if legality <= 0 {
            score -= 10000
        }
        score -= aliasCost
        return score
    }

    internal func insertState(
        _ arena: inout [ParseState],
        _ dp: inout [DPBucket],
        at index: Int,
        state: ParseState,
        limit: Int
    ) {
        guard index < dp.count else { return }
        let stateIdx = Int32(arena.count)
        arena.append(state)
        dp[index].stateIndices.append(stateIdx)
        if dp[index].stateIndices.count > limit * 2 {
            dp[index].needsPrune = true
        }
    }

    internal func pruneBucket(_ bucket: inout DPBucket, arena: [ParseState], limit: Int) {
        guard bucket.stateIndices.count > limit else {
            bucket.needsPrune = false
            return
        }
        bucket.stateIndices.sort { lhsIdx, rhsIdx in
            isBetterDP(arena[Int(lhsIdx)], than: arena[Int(rhsIdx)])
        }
        bucket.stateIndices.removeLast(bucket.stateIndices.count - limit)
        bucket.needsPrune = false
    }

    /// DP-internal ranking — operates on scalar fields only. The top-K
    /// surfaced to callers is re-sorted with the full string-aware tiebreak
    /// in `finalizeStates`, so DP-time order ties don't affect output.
    @inline(__always)
    internal func isBetterDP(_ lhs: ParseState, than rhs: ParseState) -> Bool {
        if lhs.isLegal != rhs.isLegal {
            return lhs.isLegal
        }
        if lhs.aliasCost != rhs.aliasCost {
            return lhs.aliasCost < rhs.aliasCost
        }
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.syllableCount != rhs.syllableCount {
            return lhs.syllableCount < rhs.syllableCount
        }
        if lhs.structureCost != rhs.structureCost {
            return lhs.structureCost < rhs.structureCost
        }
        return lhs.charEnd < rhs.charEnd
    }
}
