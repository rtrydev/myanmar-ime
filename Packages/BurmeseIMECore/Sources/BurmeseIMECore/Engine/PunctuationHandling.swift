import Foundation

extension BurmeseEngine {

    internal struct EmbeddedPunctSplit {
        let renderedPrefix: String
        let activeBuffer: String
    }

    /// Replace mapped ASCII punctuation (`.`, `,`, `!`, `?`, `;`) with their
    /// Myanmar equivalents. Non-mapped characters pass through untouched.
    internal static func mapPunctuation(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if let replacement = PunctuationMapper.mapped(c) {
                out += replacement
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Vowel suffixes that end in `.` (e.g. `u.`, `i.`, `an.`). When the
    /// buffer already has one of these at a candidate split position, the
    /// `.` is acting as a creaky-tone / vowel modifier in the romanization
    /// and must not be folded into the Myanmar full stop.
    internal static let vowelSuffixesWithTrailingDot: [String] = {
        Romanization.vowels.compactMap { entry in
            entry.roman.hasSuffix(".") ? entry.roman : nil
        }
    }()

    /// Subset of `vowelSuffixesWithTrailingDot` whose Myanmar output does NOT
    /// end in U+103A (asat). These "open" vowel forms (e.g. `u.`, `i.`, `ar.`)
    /// leave no structural boundary in the scalar stream, so a following
    /// onset-less syllable would fuse onto the preceding vowel cluster unless
    /// the engine forces a split at the dot.
    ///
    /// "Closed" forms like `e.` (→ `yzATBATBATD`) and `in.` (→ `IngATBATBATD`) end in
    /// asat, giving the parser a structural break; they do not need the split.
    internal static let openDotVowelSuffixes: Set<String> = {
        Set(Romanization.vowels.compactMap { entry -> String? in
            guard entry.roman.hasSuffix(".") else { return nil }
            guard entry.myanmar.unicodeScalars.last?.value != 0x103A else { return nil }
            return entry.roman
        })
    }()

    internal static let vowelSuffixesWithTrailingColon: [String] = {
        Romanization.vowels.compactMap { entry in
            entry.roman.hasSuffix(":") ? entry.roman : nil
        }
    }()

    /// Subset of `vowelSuffixesWithTrailingColon` whose Myanmar output does NOT
    /// end in U+103A (asat). Visarga `1038` itself does not provide a
    /// structural break in the next-syllable parse, so the colon-vowel
    /// modifier is "open" by the same definition as the dot-vowel modifier:
    /// when followed by an onset-less syllable, the suffix would fuse onto
    /// the preceding vowel cluster unless the engine forces a split at the
    /// colon (TASK-009). "Closed" colon forms (e.g. `aw:` → `ော်း` ending
    /// in `103A`) provide a structural break and do not need the split.
    internal static let openColonVowelSuffixes: Set<String> = {
        Set(Romanization.vowels.compactMap { entry -> String? in
            guard entry.roman.hasSuffix(":") else { return nil }
            guard entry.myanmar.unicodeScalars.last?.value != 0x103A else { return nil }
            return entry.roman
        })
    }()

    internal static func dotActsAsVowelModifier(prefixEndingAtDot prefix: Substring) -> Bool {
        vowelSuffixesWithTrailingDot.contains(where: { prefix.hasSuffix($0) })
    }

    /// TASK-079: dot-vowel-modifier suffixes whose creaky cluster legally
    /// accepts a trailing asat — the aw-family creaky forms (`aw.` →
    /// `1031 102C 1037`, `aw2.` → `1031 102B 1037`), which close into the
    /// regular `ော့်` / `ေါ့်` coda (`… 1037 103A`, the creaky
    /// possessive/emphatic of every `ော်` word). When the user types `*`
    /// directly after one of these suffixes, the `*` is the syllable's
    /// coda asat, not adjacent document punctuation, so the embedded
    /// composing-punct split must not fire and the frozen renderer must
    /// keep the `*` attached to the composable run. Derived from the
    /// romanization table: roman ends in `.` and Myanmar output ends with
    /// the aw-creaky cluster `1031 102B|102C 1037`.
    internal static let asatAcceptingCreakyDotSuffixes: Set<String> = {
        Set(Romanization.vowels.compactMap { entry -> String? in
            guard entry.roman.hasSuffix(".") else { return nil }
            let scalars = Array(entry.myanmar.unicodeScalars.map(\.value))
            guard scalars.count >= 3 else { return nil }
            guard scalars[scalars.count - 1] == 0x1037,
                  scalars[scalars.count - 2] == 0x102B
                    || scalars[scalars.count - 2] == 0x102C,
                  scalars[scalars.count - 3] == 0x1031 else { return nil }
            return entry.roman
        })
    }()

    /// True when the `*` at `idx` completes an aw-family creaky-asat coda:
    /// the chars before it end with an asat-accepting creaky dot suffix
    /// (`aw.` / `aw2.`). Such a `*` belongs to the preceding syllable.
    internal static func starCompletesCreakyAsatCoda(
        in buffer: String,
        at idx: String.Index
    ) -> Bool {
        guard buffer[idx] == "*", idx > buffer.startIndex else { return false }
        let prefix = buffer[..<idx]
        return asatAcceptingCreakyDotSuffixes.contains(where: { prefix.hasSuffix($0) })
    }

    /// TASK-014 / TASK-023 / TASK-024: when a candidate surface ends in a
    /// shape that can take a tone marker on its existing syllable cluster
    /// and the trailing literal text starts with `:` or `.`, return a
    /// sibling whose surface absorbs the leading `:`/`.` as visarga
    /// (U+1038) or creaky tone (U+1037). The eligible suffix shapes:
    ///
    ///   1. Bare base consonant (`<C>`) — inherent-`a` open syllable.
    ///      Tone is appended after the consonant: creaky `<C> 1037`,
    ///      visarga `<C> 1038`. (TASK-014)
    ///
    ///   2. Asat-closed coda (`<C> 103A`) — stop or nasal coda. Tone
    ///      is inserted at the orthographic position dictated by
    ///      Burmese rule: creaky goes BEFORE the asat
    ///      (`<C> 1037 103A`), visarga goes AFTER the asat
    ///      (`<C> 103A 1038`). (TASK-023)
    ///
    ///   3. Medial-bearing inherent-`a` (`<C> + medial(s)` ending in
    ///      U+103B..U+103E). Tone is appended after the trailing
    ///      medial scalar: creaky `<C> <medial(s)> 1037`,
    ///      visarga `<C> <medial(s)> 1038`. (TASK-024)
    ///
    /// The remainder of the tail is returned alongside so the caller
    /// can re-attach it. Returns nil when the tail doesn't start with
    /// one of the tone markers, the surface doesn't match an eligible
    /// suffix shape, or the next character in the tail is itself an
    /// ASCII letter (mid-buffer position — `kit.kha`, `kya.kha`).
    internal static func applyBareConsonantToneFromTail(
        candidateSurface: String,
        tail: String
    ) -> (surface: String, remainder: String)? {
        guard let first = tail.first else { return nil }
        let toneScalar: UInt32
        switch first {
        case ":": toneScalar = 0x1038
        case ".": toneScalar = 0x1037
        default: return nil
        }
        let scalars = Array(candidateSurface.unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        // Reject when the very next character of the tail is an ASCII
        // letter — that means the user is mid-typing an English word
        // and the `:`/`.` is intended as ASCII punctuation, not a
        // Burmese tone marker.
        let tailChars = Array(tail)
        if tailChars.count >= 2 {
            let next = tailChars[1]
            if next.isLetter && next.isASCII {
                return nil
            }
        }
        // Classify the surface suffix shape and decide where the tone
        // scalar lands.
        guard let toned = insertToneIntoSurface(
            scalars: scalars,
            toneScalar: toneScalar
        ) else {
            return nil
        }
        let remainder = String(tailChars.dropFirst())
        return (toned, remainder)
    }

    /// TASK-049: split a composed tail of shape `<Myanmar-body><:|.>`
    /// off into its body and trailing tone marker so the engine can
    /// attach the tone scalar to `candidate.surface + body` rather
    /// than to `candidate.surface` alone. Returns `nil` when the
    /// tail does not end in a tone marker, when the tone is
    /// preceded by an ASCII letter (mid-buffer literal — same
    /// guard `applyBareConsonantToneFromTail` itself applies), or
    /// when the body still contains ASCII letters (composition
    /// failed; routing through tone attachment would interleave
    /// scripts).
    internal static func splitTrailingComposedTaggedTone(
        _ tail: String
    ) -> (body: String, tone: String)? {
        guard let last = tail.last else { return nil }
        guard last == ":" || last == "." else { return nil }
        let body = String(tail.dropLast())
        if let prev = body.last, prev.isLetter, prev.isASCII {
            return nil
        }
        // Reject when the body still has ASCII letters — that means
        // the parser couldn't compose the tail cleanly and there is
        // residual romanization present. Attaching a tone scalar to
        // such a mixed-script surface would entrench the
        // interleaved-Latin invariant violation.
        if body.unicodeScalars.contains(where: {
            ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A)
        }) {
            return nil
        }
        return (body, String(last))
    }

    /// Insert `toneScalar` into a candidate surface at the
    /// orthographically correct position for Burmese tone marking.
    /// Returns nil if the surface does not match a tone-eligible
    /// suffix shape.
    ///
    /// Eligible shapes:
    /// - `<C>` (bare base consonant) — append tone.
    /// - `<C> 103A` (asat-closed coda) — creaky inserts BEFORE asat,
    ///   visarga inserts AFTER asat.
    /// - `<C> <medial(s)>` (one or more U+103B..U+103E after a base
    ///   consonant, with no asat or vowel sign past the medials) —
    ///   append tone after medials.
    private static func insertToneIntoSurface(
        scalars: [Unicode.Scalar],
        toneScalar: UInt32
    ) -> String? {
        guard let last = scalars.last else { return nil }
        let v = last.value
        let toneChar = Character(Unicode.Scalar(toneScalar)!)
        // Case 1: surface ends in a bare base consonant.
        if isBaseConsonantScalar(v) {
            // Walk back through any medials (`103B..103E`) — if the
            // base consonant is the *only* scalar after the medials
            // (i.e. the trailing scalar is the consonant itself with
            // nothing after it), this is the bare-consonant case.
            // Otherwise it's the medial-bearing case below; we
            // identify medial-bearing by the *last* scalar being a
            // medial, not a base.
            let toned = String(scalars.map(Character.init)) + String(toneChar)
            return toned
        }
        // Case 2: surface ends in an asat (`103A`). The scalar before
        // the asat must be a base consonant (or a base consonant
        // optionally preceded by medials/vowels — the orthographic
        // rule only requires the immediate predecessor of the asat to
        // be a base consonant).
        if v == 0x103A, scalars.count >= 2 {
            let prev = scalars[scalars.count - 2].value
            if isBaseConsonantScalar(prev) {
                // Creaky inserts BEFORE the asat (between base and
                // asat); visarga inserts AFTER the asat.
                let head = scalars.dropLast()
                let baseStr = String(head.map(Character.init))
                if toneScalar == 0x1037 {
                    // creaky → `<…C> 1037 103A`
                    return baseStr + String(toneChar) + String(Character(Unicode.Scalar(0x103A)!))
                } else {
                    // visarga → `<…C> 103A 1038`
                    return baseStr + String(Character(Unicode.Scalar(0x103A)!)) + String(toneChar)
                }
            }
        }
        // Case 3: surface ends in one or more medials
        // (`103B..103E`). Walk back through the medial run; the
        // immediately-preceding scalar must be a base consonant.
        if isMedialScalar(v) {
            var idx = scalars.count - 1
            while idx > 0, isMedialScalar(scalars[idx - 1].value) {
                idx -= 1
            }
            if idx > 0, isBaseConsonantScalar(scalars[idx - 1].value) {
                // The base is at idx-1; medials run from idx..count-1.
                // Append the tone scalar after the trailing medial.
                let toned = String(scalars.map(Character.init)) + String(toneChar)
                return toned
            }
        }
        return nil
    }

    @inline(__always)
    private static func isBaseConsonantScalar(_ v: UInt32) -> Bool {
        (v >= 0x1000 && v <= 0x1021) || v == 0x103F
    }

    @inline(__always)
    private static func isMedialScalar(_ v: UInt32) -> Bool {
        v >= 0x103B && v <= 0x103E
    }

    internal static func colonActsAsVowelModifier(prefixEndingAtColon prefix: Substring) -> Bool {
        vowelSuffixesWithTrailingColon.contains(where: { prefix.hasSuffix($0) })
    }

    internal static let midBufferComposingPunctuation: Set<Character> = [".", ":", "*", "'"]

    internal func splitAtLastEmbeddedComposingPunct(_ buffer: String) -> EmbeddedPunctSplit? {
        // Reverse-iterate and return on the first qualifying position
        // so multi-`:` / multi-`.` buffers (`ain:ain:ain:ain:`) don't
        // call the expensive `renderFrozenPunctSegments` per qualifying
        // index only to throw all but the last result away. Mirrors the
        // pattern already used in `splitAtLastEmbeddedLiteralPunct`.
        for idx in buffer.indices.reversed() {
            guard shouldSplitEmbeddedComposingPunct(in: buffer, at: idx) else { continue }
            let after = buffer.index(after: idx)
            guard after != buffer.endIndex else { continue }
            guard buffer[after...].contains(where: { !Self.isFrozenPunctuationLiteral($0) }) else {
                continue
            }
            let renderedPrefix = renderFrozenPunctSegments(String(buffer[..<after]))
            guard !Self.hasAsciiLetters(renderedPrefix) else { continue }
            return EmbeddedPunctSplit(
                renderedPrefix: renderedPrefix,
                activeBuffer: String(buffer[after...])
            )
        }
        return nil
    }

    /// TASK-078: lexicon/LM/history-aligned rendering of the frozen
    /// prefix at an embedded composing-punct split.
    ///
    /// The parser-only `renderFrozenPunctSegments` render always picks
    /// the DP's aliasCost-first sibling, which flips a prefix the user
    /// already saw rendered correctly (`kyaung:` → `ကျောင်း` flipped
    /// to `ကြောင်း` on the very next keystroke, `myar:` → `များ`
    /// flipped to `မြား`) and wedges raw ASCII `*`/`:` between Myanmar
    /// scalars for ဉ်/ည်-coda readings (`sany*:` → `စန်ယ*:`).
    ///
    /// Instead, re-run the full pipeline on the prefix slice — exactly
    /// what rendered it before the split fired — and adopt the first
    /// candidate that
    ///   - is not a pure-lexicon completion (lexicon hits for a prefix
    ///     reading include longer words such as `to.` → `တို့၌`; the
    ///     prefix must cover exactly the typed slice), and
    ///   - covers exactly the slice's alias reading, and
    ///   - is a pure Myanmar surface (no leaked ASCII).
    /// Grammar candidates carry absorbed lexicon scores, ya-pin
    /// promotion, and LM ranking; history candidates carry the user's
    /// own committed choice. When no candidate qualifies (bare-engine
    /// shapes, unparseable slices) the parser-only absorb render is
    /// kept, so engines without evidence sources behave exactly as
    /// before.
    ///
    /// Memoised in `punctPrefixRenderCache`: the slice is stable while
    /// the user extends the active suffix, so the recursive
    /// `updateInternal` runs once per new split point, not per
    /// keystroke.
    internal func evidenceAlignedPunctPrefix(
        _ slice: String,
        context: [String]
    ) -> String {
        let cacheKey = slice + "\u{1F}" + (context.last ?? "")
        cacheLock.lock()
        if let cached = punctPrefixRenderCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        var resolved = renderFrozenPunctSegments(
            slice,
            absorbTrailingToneIfBurmeseFollows: true
        )
        let sliceAlias = Romanization.aliasReading(slice)
        // The evidence candidate must agree with the baseline on how
        // the slice ENDS. A standalone parse of the slice is free to
        // re-interpret the trailing punctuation (`ka.` standalone maps
        // the dot to `။` under punctuation mapping; `ka*.` standalone
        // absorbs `*` as asat then `.` as creaky), but in split
        // position the baseline's absorb/flush decision is the
        // product-pinned one — only the SIBLING choice earlier in the
        // surface (ya-pin vs ya-yit, ဉ် vs န်ယ) may differ. Comparing
        // the final scalar enforces exactly that: tone-flip prefixes
        // share their tail scalar (`ကြောင်း`/`ကျောင်း` both end
        // U+1038), while a re-interpreted trailing punct never does
        // (`က*.` ends ASCII `.`, `က။` ends U+104B). An empty baseline
        // rejects all evidence and keeps pre-TASK-078 behaviour.
        let baselineTail = resolved.unicodeScalars.last
        // Evidence may only flip between pure-Myanmar sibling renders.
        // When the baseline deliberately preserved literal ASCII punct
        // (`ka'.` → `က'။`, `ka*.` → `က*.`, `sany*:` → `စန်ယ*:`), the
        // literal-preservation behaviour is product-pinned — a
        // standalone re-parse that consumed the punct (`က။`, `က့်`)
        // must not silently erase what the user typed. Whole-buffer
        // exact-alias injection still covers the curated readings
        // behind those shapes (`sany*:sar:` → `စဉ်းစား`).
        if !resolved.isEmpty, !Self.hasAsciiScalars(resolved) {
            let inner = updateInternal(buffer: slice, context: context)
            for cand in inner.candidates {
                guard cand.source != .lexicon,
                      !cand.surface.isEmpty,
                      !Self.hasAsciiScalars(cand.surface),
                      cand.surface.unicodeScalars.last == baselineTail,
                      Romanization.aliasReading(cand.reading) == sliceAlias else {
                    continue
                }
                resolved = cand.surface
                break
            }
        }
        cacheLock.lock()
        if punctPrefixRenderCache.count >= Self.maxPunctPrefixRenderCache {
            punctPrefixRenderCache.removeAll(keepingCapacity: true)
        }
        punctPrefixRenderCache[cacheKey] = resolved
        cacheLock.unlock()
        return resolved
    }

    /// TASK-078: whole-buffer evidence for embedded composing-punct
    /// split buffers. The split branch recurses only on the active
    /// suffix, so without this pass the exact alias/compose rows for
    /// the COMPLETE reading (curated multi-word entries such as
    /// `myar:ar:` → `များအား`, digit-stripped ဉ-coda words such as
    /// `sany*:sar:` → `စဉ်းစား`, and `ng*:ka` → `၎င်းက`) never reach
    /// the panel, and a selection previously committed under the
    /// full-buffer alias is never promoted.
    ///
    /// Exact lexicon hits are inserted ahead of the composed
    /// prefix+suffix candidates (penalty-0 exact hits are the
    /// strongest signal this branch can have); history hits are then
    /// promoted to the very front, mirroring the regular pipeline's
    /// merge order. Buffers carrying a literal ASCII digit skip the
    /// lexicon injection — digits are literal (durable rule), and the
    /// alias-normalised lookup would otherwise resurface
    /// digit-stripped rows without the user's typed digit.
    internal func injectWholeBufferPunctSplitEvidence(
        into candidates: [Candidate],
        displayBuffer: String,
        context: [String]
    ) -> [Candidate] {
        var merged = candidates
        let hasAsciiDigit = displayBuffer.unicodeScalars.contains {
            (0x30...0x39).contains($0.value)
        }
        if !hasAsciiDigit {
            let fullAlias = Romanization.aliasReading(displayBuffer)
            let exactHits = candidateStore.lookupExact(
                reading: displayBuffer,
                previousSurface: context.last
            )
            var front: [Candidate] = []
            var seen: Set<String> = []
            for hit in exactHits {
                guard front.count < Self.maxWholeBufferExactInjection else { break }
                // Alias-exact only. `lookupExact` also folds in
                // compose-key variants, which strip the `'`/`+`
                // separators — for a buffer like `'thar` that would
                // resurface `သာ` and silently drop the user's typed
                // apostrophe from rank 0. A row only qualifies when
                // its canonical reading covers the typed buffer
                // alias verbatim.
                guard Romanization.aliasReading(hit.reading) == fullAlias,
                      !hit.surface.isEmpty,
                      !Self.hasAsciiScalars(hit.surface),
                      seen.insert(hit.surface).inserted else {
                    continue
                }
                // Move-or-insert: when the composed prefix+suffix list
                // already produced the same surface, promote THAT
                // candidate (keeping its grammar/history source) so a
                // later `evidenceAlignedPunctPrefix` scan over this
                // panel — which skips pure-lexicon completions — still
                // sees the surface as exact-reading evidence when this
                // buffer becomes the frozen prefix of a longer one.
                if let existing = merged.firstIndex(where: { $0.surface == hit.surface }) {
                    front.append(merged.remove(at: existing))
                } else {
                    front.append(Candidate(
                        surface: hit.surface,
                        reading: displayBuffer,
                        source: hit.source,
                        score: hit.score
                    ))
                }
            }
            if !front.isEmpty {
                merged = front + merged
            }
        }
        // History promotion mirrors the regular path: walk lowest
        // score first so the strongest entry lands at index 0 after
        // successive front-inserts; surfaces already present are
        // moved, unseen surfaces injected.
        if settings?.learningEnabled ?? true {
            let historyCandidates = historyStore.lookup(
                prefix: Romanization.aliasReading(displayBuffer),
                previousSurface: context.last
            )
            for historyCandidate in historyCandidates.sorted(by: { $0.score < $1.score }) {
                if let existing = merged.firstIndex(where: { $0.surface == historyCandidate.surface }) {
                    let keeper = merged.remove(at: existing)
                    merged.insert(keeper, at: 0)
                } else {
                    merged.insert(historyCandidate, at: 0)
                }
            }
        }
        return merged
    }

    /// Cap on whole-buffer exact-hit injection at an embedded
    /// composing-punct split. Mirrors the regular pipeline's
    /// prioritized-lexicon cap (2) plus one slot for surface variants
    /// that share the exact reading (`ng*:to.` carries both `၎င်းတို့`
    /// and `င်းတို့`).
    internal static let maxWholeBufferExactInjection = 3

    private func shouldSplitEmbeddedComposingPunct(
        in buffer: String,
        at idx: String.Index
    ) -> Bool {
        let c = buffer[idx]
        guard Self.midBufferComposingPunctuation.contains(c) else { return false }
        if c == "'" {
            // Treat apostrophe as a literal split character when at least one
            // neighbour is not a composable ASCII letter. This covers leading
            // `'` (quote, no left neighbour), trailing `'` adjacent to
            // end-of-buffer (handled separately by the trailing-strip path in
            // BurmeseEngine), and `'` next to punctuation/digits.
            //
            // When both neighbours ARE letters (e.g. `nya'n`, `don't`) the
            // null-vowel connector role is preserved here — the split does
            // not fire. English-contraction handling is done at the engine
            // level (TASK-021) where the literal-preserved candidate can be
            // injected at rank 0 directly, instead of going through the
            // split-and-render-prefix path which would render the prefix as
            // mixed Myanmar + literal `'`.
            let hasLetterLeft: Bool = idx > buffer.startIndex && {
                let prev = buffer.index(before: idx)
                let v = buffer[prev].unicodeScalars.first?.value ?? 0
                return (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A)
            }()
            let nextIdx = buffer.index(after: idx)
            let hasLetterRight: Bool = nextIdx < buffer.endIndex && {
                let v = buffer[nextIdx].unicodeScalars.first?.value ?? 0
                return (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A)
            }()
            return !(hasLetterLeft && hasLetterRight)
        }
        if c == ".",
           Self.dotActsAsVowelModifier(prefixEndingAtDot: buffer[...idx]) {
            // When an OPEN dot vowel-modifier (no asat at the end of its Myanmar
            // output) is immediately followed by a vowel-starting letter, the
            // suffix begins an onset-less syllable. Force a split so each syllable
            // renders with its own base instead of fusing with the preceding vowel
            // cluster (task 02). Closed forms like `e.` already end in asat and
            // provide a structural break; they must not trigger the split.
            let after = buffer.index(after: idx)
            if after < buffer.endIndex,
               Self.isVowelStartChar(buffer[after]),
               Self.openDotVowelSuffixes.contains(where: { buffer[...idx].hasSuffix($0) }),
               Self.hasOnlyComposableLettersBefore(buffer, dotAt: idx) {
                return true
            }
            return false
        }
        if c == ":",
           Self.colonActsAsVowelModifier(prefixEndingAtColon: buffer[...idx]) {
            // Mirror the open-dot vowel-modifier branch above: when an OPEN
            // colon vowel-modifier (whose Myanmar output ends in `1038`
            // visarga, not in asat) is immediately followed by a vowel-
            // starting letter, the suffix begins an onset-less syllable.
            // Without a split, the inherent-`a` arc gets silently absorbed
            // and the user's `အ` syllable boundary is lost (TASK-009).
            // Closed colon forms (e.g. `aw:` → `ော်း`) already end in asat
            // and provide a structural break; they must not trigger the
            // split.
            let after = buffer.index(after: idx)
            if after < buffer.endIndex,
               Self.isVowelStartChar(buffer[after]),
               Self.openColonVowelSuffixes.contains(where: { buffer[...idx].hasSuffix($0) }),
               Self.hasOnlyComposableLettersBefore(buffer, dotAt: idx) {
                return true
            }
            return false
        }
        if c == "." || c == ":" {
            return true
        }
        // TASK-079: a `*` that completes an aw-family creaky-asat coda
        // (`taw.` + `*` → `တော့်`) is the syllable's coda asat — the
        // `.` before it is a vowel modifier, not document punctuation,
        // so the `.*` adjacency must not force a split here.
        if c == "*", Self.starCompletesCreakyAsatCoda(in: buffer, at: idx) {
            return false
        }
        return Self.hasAdjacentComposingPunctuation(in: buffer, at: idx)
    }

    private static func isFrozenPunctuationLiteral(_ c: Character) -> Bool {
        midBufferComposingPunctuation.contains(c) || PunctuationMapper.isMappable(c)
    }

    /// Common English contraction suffix tails that follow an
    /// apostrophe (`'t` / `'s` / `'re` / `'ll` / `'ve` / `'d` / `'m`
    /// / `'nt`). When the buffer matches `<letters>'<suffix>` and the
    /// suffix runs to the end of the buffer (or to a natural word
    /// boundary), the engine routes the buffer through the
    /// literal-preservation path so the surface keeps the typed `'`.
    /// TASK-021.
    internal static let englishContractionSuffixes: Set<String> = [
        "nt", "ll", "re", "ve",
        "t", "s", "d", "m",
    ]

    /// Locate a letter-flanked apostrophe whose suffix matches a
    /// common English contraction shape (`'t`, `'s`, `'re`, `'ll`,
    /// `'ve`, `'d`, `'m`, `'nt`). Returns the substring index of the
    /// apostrophe when one is found, or nil if none qualifies.
    /// Conservative by design — Burmese-romanization buffers typed
    /// with `'` as a syllable separator (`nya'n`, `kya'aung`, `a'a`)
    /// do not match because their suffix is not in the contraction
    /// set, so the connector-rule behaviour at the top rank is
    /// preserved (TASK-021 acceptance criterion).
    /// TASK-021: build a CompositionState for an English-contraction
    /// buffer. Strategy: rank 0 is the literal `buffer` so the user
    /// can commit the contraction as typed (apostrophe preserved).
    /// Lower ranks include the connector-collapsed form (the
    /// apostrophe acting as a null-vowel separator, producing the
    /// pre-fix Burmese reading) so users who genuinely typed the
    /// apostrophe-flanked pattern as a syllable separator still have
    /// a path to it. The connector form is reachable by re-running
    /// `update` on the apostrophe-stripped buffer; if that produces
    /// no candidates (e.g. `cant` for `can't`), the literal is the
    /// only candidate — guaranteeing a non-empty panel.
    internal func englishContractionState(
        buffer: String,
        context: [String]
    ) -> CompositionState {
        let stripped = String(buffer.filter { $0 != "'" })
        let collapsed = stripped.isEmpty
            ? CompositionState(committedContext: context)
            : updateInternal(buffer: stripped, context: context)
        var combined: [Candidate] = []
        // Rank 0: literal contraction surface.
        combined.append(Candidate(
            surface: buffer,
            reading: buffer,
            source: .grammar,
            score: 0
        ))
        // Rank 1+: connector-collapsed candidates (deduplicated
        // against the literal, which would only collide if the user
        // typed an apostrophe-stripped surface — can't happen here).
        for cand in collapsed.candidates where cand.surface != buffer {
            combined.append(Candidate(
                surface: cand.surface,
                reading: buffer,
                source: cand.source,
                score: cand.score
            ))
        }
        cacheLock.lock()
        lastHistoryKey = Romanization.aliasReading(buffer)
        cacheLock.unlock()
        return CompositionState(
            rawBuffer: buffer,
            selectedCandidateIndex: 0,
            candidates: combined,
            committedContext: context
        )
    }

    internal static func englishContractionApostropheIndex(
        in buffer: String
    ) -> String.Index? {
        guard buffer.contains("'") else { return nil }
        for idx in buffer.indices where buffer[idx] == "'" {
            // Both neighbours must be ASCII letters. Otherwise the
            // existing literal-split path already handles it.
            let prevIdx = idx > buffer.startIndex
                ? buffer.index(before: idx) : nil
            let nextIdx = buffer.index(after: idx)
            guard let prevIdx, nextIdx < buffer.endIndex else { continue }
            let prevValue = buffer[prevIdx].unicodeScalars.first?.value ?? 0
            let nextValue = buffer[nextIdx].unicodeScalars.first?.value ?? 0
            let prevIsLetter = (prevValue >= 0x61 && prevValue <= 0x7A)
                || (prevValue >= 0x41 && prevValue <= 0x5A)
            let nextIsLetter = (nextValue >= 0x61 && nextValue <= 0x7A)
                || (nextValue >= 0x41 && nextValue <= 0x5A)
            guard prevIsLetter && nextIsLetter else { continue }
            // Walk to the end of the letter run after `'`.
            var end = nextIdx
            while end < buffer.endIndex {
                let v = buffer[end].unicodeScalars.first?.value ?? 0
                let isLetter = (v >= 0x61 && v <= 0x7A)
                    || (v >= 0x41 && v <= 0x5A)
                guard isLetter else { break }
                end = buffer.index(after: end)
            }
            let suffix = String(buffer[nextIdx..<end]).lowercased()
            if englishContractionSuffixes.contains(suffix) {
                return idx
            }
        }
        return nil
    }

    private static func hasAsciiLetters(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }
    }

    /// Any ASCII scalar at all — letters, digits, or punctuation.
    /// Used by the TASK-078 evidence paths, which only ever adopt
    /// pure-Myanmar surfaces (a sibling like `သ:`/`စဉ်:` would wedge
    /// raw punctuation between Myanmar scalars once composed with the
    /// active suffix).
    internal static func hasAsciiScalars(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x80 }
    }

    private static func hasAdjacentComposingPunctuation(
        in buffer: String,
        at idx: String.Index
    ) -> Bool {
        if idx > buffer.startIndex {
            let prev = buffer.index(before: idx)
            if midBufferComposingPunctuation.contains(buffer[prev]) {
                return true
            }
        }
        let next = buffer.index(after: idx)
        if next < buffer.endIndex,
           midBufferComposingPunctuation.contains(buffer[next]) {
            return true
        }
        return false
    }

    /// Locate the last literal-punct character that has at least one
    /// composable letter after it, and split `buffer` there. "Literal
    /// punct" is any character that cannot extend a composable run —
    /// mapped punct (`.`, `,`, `!`, `?`, `;`), the composing-punct
    /// subset (`*`, `'`, `:`, `.` outside the modifier exception),
    /// and every other non-letter / non-digit / non-`+` character
    /// (`-`, `_`, `(`, `)`, brackets, whitespace, ...).
    ///
    /// Purely trailing literal punct returns `nil` so the existing
    /// trailing-punct path (`stripTrailingMappablePunctuation` /
    /// literal-tail concatenation) still handles `thar,`, `thar.`, …
    /// without recursing.
    ///
    /// Generalises `splitAtLastEmbeddedMappedPunct`. Task 03.
    internal func splitAtLastEmbeddedLiteralPunct(_ buffer: String) -> EmbeddedPunctSplit? {
        var boundary: String.Index? = nil
        var renderedPrefixCache: String? = nil
        for idx in buffer.indices.reversed() {
            let c = buffer[idx]
            guard Self.isLiteralPunctSplitChar(c) else { continue }
            // `.` and `:` are overloaded: they terminate / separate when
            // they follow arbitrary content, but they are also creaky-
            // tone modifiers on vowel suffixes like `u.`, `i.`, `an.`,
            // `aung.`, `aw:`. When the current position closes one of
            // those modifier endings, leave the char attached to the
            // composable run instead of splitting on it.
            if c == ".",
               Self.dotActsAsVowelModifier(prefixEndingAtDot: buffer[...idx]) {
                let after = buffer.index(after: idx)
                if after < buffer.endIndex,
                   Self.isVowelStartChar(buffer[after]),
                   Self.openDotVowelSuffixes.contains(where: { buffer[...idx].hasSuffix($0) }),
                   Self.hasOnlyComposableLettersBefore(buffer, dotAt: idx) {
                    // Open dot vowel-modifier followed by an onset-less syllable,
                    // with a pure composable prefix: fall through to split logic.
                } else {
                    continue
                }
            }
            if c == ":",
               Self.colonActsAsVowelModifier(prefixEndingAtColon: buffer[...idx]) {
                let after = buffer.index(after: idx)
                if after < buffer.endIndex,
                   Self.isVowelStartChar(buffer[after]),
                   Self.openColonVowelSuffixes.contains(where: { buffer[...idx].hasSuffix($0) }),
                   Self.hasOnlyComposableLettersBefore(buffer, dotAt: idx) {
                    // Open colon vowel-modifier followed by an onset-less syllable,
                    // with a pure composable prefix: fall through to split logic
                    // (mirror of the open-dot branch above; TASK-009).
                } else {
                    continue
                }
            }
            let after = buffer.index(after: idx)
            guard after != buffer.endIndex else { continue }
            // Active suffix must contain at least one composable letter
            // (a-z) — otherwise there's nothing to recompose and the
            // legacy literal-tail path is fine.
            guard buffer[after...].contains(where: Self.isAsciiLetter) else {
                continue
            }
            // The rendered prefix must be ASCII-letter-free. If a
            // segment in the prefix can't compose cleanly (parser
            // dropping unparseable chars to the literal tail —
            // common on fuzz inputs like `arc:dlax...`), splitting
            // here would leak ASCII into the surface. Defer to the
            // regular pipeline's parser-driven cleanup instead.
            // Mirrors the same guard in `splitAtLastEmbeddedComposingPunct`.
            let renderedPrefix = renderFrozenPunctSegments(String(buffer[..<after]))
            guard !Self.hasAsciiLetters(renderedPrefix) else { continue }
            boundary = after
            renderedPrefixCache = renderedPrefix
            break
        }
        guard let boundary, let renderedPrefix = renderedPrefixCache else {
            return nil
        }
        return EmbeddedPunctSplit(
            renderedPrefix: renderedPrefix,
            activeBuffer: String(buffer[boundary...])
        )
    }

    /// True for characters that break a composable run when seen
    /// mid-buffer. Excludes:
    /// - composable letters (a-z, A-Z)
    /// - digits (handled separately by `splitLeadingDigits` / digit
    ///   spliceback)
    /// - `+` (kinzi separator that the parser consumes)
    /// - `*` and `'` (asat / null-vowel separator that the parser
    ///   consumes — they belong inside a syllable, not between
    ///   syllables)
    /// - whitespace (script transition — stays literal per the
    ///   Pinyin-style inline-mixing convention; `thar english`
    ///   commits as `သာ english`, not `သာ ယ်ငလီရှ`)
    ///
    /// `:` and `.` are split candidates here, but the splitter calls
    /// `dotActsAsVowelModifier` / `colonActsAsVowelModifier` first to
    /// keep creaky-tone / tone-variant suffix usage attached to the
    /// composable run.
    internal static func isLiteralPunctSplitChar(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first else {
            return true
        }
        let v = scalar.value
        if v >= 0x61 && v <= 0x7A { return false }   // a-z
        if v >= 0x41 && v <= 0x5A { return false }   // A-Z
        if v >= 0x30 && v <= 0x39 { return false }   // 0-9
        if v == 0x2B { return false }                 // `+`  (kinzi)
        if v == 0x2A { return false }                 // `*`  (asat marker)
        if v == 0x27 { return false }                 // `'`  (null-vowel separator)
        // Whitespace — script transition, stays literal.
        if v == 0x20 || v == 0x09 || v == 0x0A || v == 0x0D { return false }
        return true
    }

    @inline(__always)
    private static func isVowelStartChar(_ c: Character) -> Bool {
        switch c {
        case "a", "e", "i", "o", "u": return true
        default: return false
        }
    }

    /// True when every character in `buffer` strictly before `dotIdx`
    /// is a composable ASCII letter (`a`–`z`), stacker (`+`), or
    /// null-vowel connector (`'`). A pure prefix means that rendering
    /// `buffer[...dotIdx]` via a single parser call is safe — no
    /// embedded colons, asterisks, or earlier dots that would force a
    /// long multi-segment string onto the single-best parser path.
    private static func hasOnlyComposableLettersBefore(
        _ buffer: String,
        dotAt dotIdx: String.Index
    ) -> Bool {
        var i = buffer.startIndex
        while i < dotIdx {
            let v = buffer[i].unicodeScalars.first?.value ?? 0
            guard (v >= 0x61 && v <= 0x7A)
               || (v >= 0x41 && v <= 0x5A)
               || v == 0x2B               // '+'
               || v == 0x27               // '\''
            else { return false }
            i = buffer.index(after: i)
        }
        return true
    }

    @inline(__always)
    private static func isAsciiLetter(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first else {
            return false
        }
        let v = scalar.value
        return (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A)
    }

    /// Render a buffer slice as Myanmar, splitting on every literal-punct
    /// boundary (mapped, composing-punct, and any other non-composable
    /// non-digit char) and running single-best parsing on each composable
    /// run between them. Used only for the frozen prefix — lexicon + N-best
    /// are reserved for the active tail.
    ///
    /// When `absorbTrailingToneIfBurmeseFollows` is `true`, a trailing
    /// `:` or `.` (the LAST char of `s`, with no further content) is
    /// absorbed onto the preceding segment as visarga (U+1038) or
    /// creaky tone (U+1037) when that segment ends in a tone-eligible
    /// shape (bare base consonant, asat-coda, or medial-bearing
    /// onset). This is used by the `splitAtLastEmbeddedComposingPunct`
    /// call site (TASK-032) when the active buffer following the split
    /// is itself Burmese-composable — the user's `<C>a:<rest>` /
    /// `<C>a.<rest>` shape is unambiguously a Burmese tone marker
    /// rather than mid-buffer ASCII punctuation.
    internal func renderFrozenPunctSegments(
        _ s: String,
        absorbTrailingToneIfBurmeseFollows: Bool = false
    ) -> String {
        var out = ""
        var current = ""
        let chars = Array(s)
        // TASK-060: doubled-document-punct (`..`/`::`/`.:`/`:.`) between
        // a tone-eligible composable run and a Burmese-composable
        // continuation must NOT be absorbed as a tone modifier — every
        // tone-absorbed sibling produces a `<tone-scalar><single-punct>
        // <Myanmar onset>` shape that the TASK-055 sanitiser correctly
        // rejects, leaving the panel without any Burmese candidate. By
        // refusing the tone absorption when the next char is also a
        // composing-punct (`./:`), we surface a sibling parse where
        // both punct chars flush as literal between the rendered
        // syllables (`ကာ..က` style), giving the user a Burmese
        // candidate alongside the literal fallback.
        @inline(__always)
        func nextIsDocPunct(after i: Int) -> Bool {
            guard i + 1 < chars.count else { return false }
            let n = chars[i + 1]
            return n == "." || n == ":"
        }
        for (idx, c) in chars.enumerated() {
            // When `.` / `:` closes a creaky-tone or tone-variant vowel
            // suffix (`u.`, `i.`, `an.`, `aw:`, …) it stays attached to
            // the current composable run instead of flushing as
            // punctuation.
            if c == ".",
               !nextIsDocPunct(after: idx),
               Self.dotActsAsVowelModifier(prefixEndingAtDot: Substring(current + ".")) {
                current.append(".")
                continue
            }
            if c == ":",
               !nextIsDocPunct(after: idx),
               Self.colonActsAsVowelModifier(prefixEndingAtColon: Substring(current + ":")) {
                current.append(":")
                continue
            }
            // TASK-032: when an internal `:`/`.` is followed by a
            // Burmese-composable letter run (a-z/A-Z), absorb the tone
            // onto the preceding segment when that segment is
            // tone-eligible (bare-`<C>a`, medial-bearing inherent-`a`,
            // or asat-coda). The literal `:`/`.` between two Burmese
            // syllables is never legitimate ASCII document punctuation.
            //
            // The trailing-position case (last char of `s` is `:`/`.`)
            // is gated on `absorbTrailingToneIfBurmeseFollows` because
            // the renderer cannot see the active buffer that comes
            // AFTER the rendered prefix — the caller passes that
            // signal in.
            let isInternalPunct = (c == ":" || c == ".")
                && idx + 1 < chars.count
                && Self.isComposableLetter(chars[idx + 1])
            let isTrailingPunctWithBurmeseAfter = (c == ":" || c == ".")
                && idx == chars.count - 1
                && absorbTrailingToneIfBurmeseFollows
            if isInternalPunct || isTrailingPunctWithBurmeseAfter {
                if !current.isEmpty {
                    let rendered = renderFrozenSegment(current)
                    let toneScalar: UInt32 = (c == ":") ? 0x1038 : 0x1037
                    if let toned = Self.applyToneScalar(rendered, toneScalar: toneScalar) {
                        out += toned
                        current = ""
                        continue
                    }
                }
            }
            // TASK-079: a `*` completing an aw-family creaky-asat coda
            // (`taw.` + `*` → `တော့်`) stays attached to the composable
            // run — flushing it as a literal would wedge a raw `*`
            // between Myanmar scalars and strip the syllable's coda.
            if c == "*",
               Self.asatAcceptingCreakyDotSuffixes.contains(where: { current.hasSuffix($0) }) {
                current.append("*")
                continue
            }
            // Flush at any literal-punct split char *or* the in-syllable
            // composing-punct subset (`*`, `'`). The split-char set
            // already covers the broader literal-punct range
            // (`,`, `;`, `(`, `-`, ...); the additional check on
            // `midBufferComposingPunctuation` keeps `*` and `'` flushing
            // here so the older `splitAtLastEmbeddedComposingPunct` call
            // site (which expects `ka*.tar` to render the `*` as a
            // literal between rendered segments) keeps its behaviour.
            // The new mid-buffer literal-punct path never enters this
            // renderer with `*` or `'` because the composing-punct
            // splitter already runs first.
            if Self.isLiteralPunctSplitChar(c) || Self.midBufferComposingPunctuation.contains(c) {
                if !current.isEmpty {
                    out += renderFrozenSegment(current)
                    current = ""
                }
                if burmesePunctuationEnabled,
                   let mapped = PunctuationMapper.mapped(c) {
                    out += mapped
                } else {
                    out.append(c)
                }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty {
            out += renderFrozenSegment(current)
        }
        return out
    }

    /// TASK-032 helper. Apply a tone scalar (U+1037 creaky / U+1038
    /// visarga) to the END of a Myanmar surface when its trailing
    /// shape is tone-eligible (bare base consonant, asat-coda, or
    /// medial-bearing onset). Returns nil when the surface ends in a
    /// shape that does not accept the tone (already toned, vowel-
    /// closed, indep-vowel-only, …) so the caller falls back to
    /// flushing the literal `:`/`.`.
    @inline(__always)
    private static func applyToneScalar(_ surface: String, toneScalar: UInt32) -> String? {
        let scalars = Array(surface.unicodeScalars)
        return insertToneIntoSurface(scalars: scalars, toneScalar: toneScalar)
    }

    @inline(__always)
    private static func isComposableLetter(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first else {
            return false
        }
        let v = scalar.value
        return (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A)
    }

    /// Single-best render of a punct-free segment. Digits convert to
    /// Myanmar digits up front; the remaining composable run is parsed
    /// with right-shrink to skip chars the parser can't consume.
    /// Anything beyond the composable run passes through as-is (the
    /// caller has already stripped mapped-punct from the input).
    internal func renderFrozenSegment(_ segment: String) -> String {
        let (digits, rest) = Self.splitLeadingDigits(segment)
        let digitPart = Self.arabicToBurmeseDigits(digits)
        let (composable, literal) = splitComposablePrefix(rest)
        let normalized = Self.normalizeForParser(composable)
        guard !normalized.isEmpty else {
            return digitPart + composable + literal
        }
        var probe = normalized
        var dropped = ""
        while !probe.isEmpty {
            let parses = parser.parseCandidates(probe, maxResults: 1)
            if parses.contains(where: { Self.isAcceptableParse($0) }) { break }
            dropped = String(probe.removeLast()) + dropped
        }
        guard !probe.isEmpty else {
            return digitPart + composable + literal
        }
        // Ask for top-K parses (not just top-1). A bare vowel-modifier
        // segment such as `u:` parses with TWO competitive forms: the
        // ZWNJ-orphan dependent-vowel form (`[200C 1030 1038]`) and
        // the precomposed independent-vowel form (`[1026 1038]`).
        // The parser ranks the orphan form first on alias cost, but
        // it has lower legalityScore — the engine's full path prefers
        // the precomposed form for standalone inputs. The frozen-
        // segment render is the engine's parallel path for split
        // prefixes; without considering siblings, `u:akar` rendered
        // the orphan form (`အူး` after promotion) instead of the
        // precomposed form (`ဦး`) that bare `u:` produces. Picking
        // the highest-legality parse here aligns the split-prefix
        // surface with the standalone surface (TASK-009 follow-up).
        let parses = parser.parseCandidates(probe, maxResults: 4)
        let topParse = Self.preferIndependentVowelLeadParse(parses) ?? parses.first
        var output = topParse?.output ?? probe
        // Apply orphan-ZWNJ promotion so bare-vowel segments (`aung`,
        // `i`, `ee`, …) get an explicit `အ` independent-vowel anchor
        // instead of a leading U+200C that renders the dependent-vowel
        // marks unanchored. Mirrors the engine's `update` post-process.
        if let parse = topParse,
           let promoted = Self.promoteOrphanZwnjToImplicitA(parse) {
            output = promoted.output
        }
        // Mirror `expandAaVariants` — the parser emits short ာ; the
        // descender consonants (kh, g, ng, d, p, w) take tall ါ. Without
        // this the frozen-prefix render of `khaung:` would carry short
        // 102C and the concatenated split surface (e.g. `khaung:athit`)
        // would never reach the engine-level `correctAaShape` pass.
        output = Self.correctAaShape(output)
        return digitPart + output + dropped + literal
    }

    /// When the parser returns multiple competitive parses, prefer
    /// one whose Myanmar surface begins with an independent-vowel
    /// scalar (`U+1023..U+102A`) over a sibling whose surface begins
    /// with `U+200C` (ZWNJ) followed by a dependent vowel. The two
    /// forms exist in the parser candidate panel for bare-vowel
    /// suffixes like `u`, `u:`, `u.`, `ay`, `ay:`, `o`, `o:` —
    /// the orphan-ZWNJ form sorts first on alias cost / score but
    /// has lower legalityScore. The engine's full ranker prefers
    /// the precomposed form in those cases; the frozen-segment
    /// renderer is its parallel path and must match.
    ///
    /// Returns `nil` if no candidate begins with an independent
    /// vowel — caller falls back to the parser's top.
    private static func preferIndependentVowelLeadParse(
        _ parses: [SyllableParse]
    ) -> SyllableParse? {
        guard parses.count > 1 else { return nil }
        // Only act when the parser's top would otherwise be promoted
        // via orphan-ZWNJ — i.e. its surface starts with U+200C.
        guard let top = parses.first,
              let firstScalar = top.output.unicodeScalars.first,
              firstScalar.value == 0x200C else {
            return nil
        }
        for parse in parses.dropFirst() {
            guard let s = parse.output.unicodeScalars.first else { continue }
            let v = s.value
            if v >= 0x1023 && v <= 0x102A {
                return parse
            }
        }
        return nil
    }

    /// Strip trailing mapped-punctuation characters (`.`, `,`, `!`, `?`, `;`)
    /// from the end of `s`. Returns the kept prefix and the peeled suffix
    /// in original order. Used to rescue trailing `.` from the composable
    /// buffer (it's in `Romanization.composingCharacters`) so it can be
    /// routed through the literal-tail mapping path.
    ///
    /// A trailing `.` is only re-added to `kept` when the preceding chars
    /// actually accept it as a creaky-tone modifier (e.g. `mu.` → မု,
    /// `mi.` → မိ). Otherwise the `.` stays peeled and is mapped to the
    /// literal-tail substitution path — preventing inputs like `thar.`
    /// from polluting the parse with a tone marker the base can't take.
    internal func stripTrailingMappablePunctuation(_ s: String) -> (kept: String, stripped: String) {
        var kept = s
        var stripped = ""
        while let last = kept.last, PunctuationMapper.isMappable(last) {
            stripped = String(last) + stripped
            kept.removeLast()
        }
        if !kept.isEmpty, stripped.first == "." {
            if creakyToneAttachesTo(kept) {
                kept.append(".")
                stripped.removeFirst()
            }
        }
        return (kept, stripped)
    }

    /// True when appending `.` to `prefix` improves the parser's top
    /// legality — i.e. there is a creaky-tone reading that genuinely
    /// extends the base. A bare comparison ("with-dot scores higher than
    /// without") generalises across every creaky-tone rule in the table
    /// without hard-coding the eligible bases here.
    internal func creakyToneAttachesTo(_ prefix: String) -> Bool {
        let withDot = parser.parseCandidates(prefix + ".", maxResults: 1).first
        guard let withDot, withDot.legalityScore > 0 else { return false }
        let plain = parser.parseCandidates(prefix, maxResults: 1).first
        let plainLegality = plain?.legalityScore ?? 0
        return withDot.legalityScore >= plainLegality
    }

    /// Peel a leading run of non-alphanumeric literal characters (the
    /// "literal head") from the rest of the buffer. Lowercase ASCII
    /// letters start composable syllables; ASCII digits have their own
    /// downstream path (→ Myanmar numerals); `'` and `+` are composable
    /// null-vowel / kinzi separators handled by the parser. Everything
    /// else at the start is treated as a literal segment and carried
    /// verbatim onto each candidate surface — `.aung` → `.အောင်`,
    /// `(thar)` → `(သာ)`, `"thar"` → `"သာ"`. Note `.`, `:`, `*` are in
    /// `composingCharacters` but cannot start a legal parse, so peeling
    /// them here prevents the composable run from starting empty.
    internal static func splitLeadingLiteral(_ buffer: String) -> (literal: String, remainder: String) {
        let firstNonLiteral = buffer.firstIndex(where: { ch in
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
                return true
            }
            let v = scalar.value
            if v >= 0x61 && v <= 0x7A { return true }            // a-z
            if v >= 0x30 && v <= 0x39 { return true }            // 0-9
            if v == 0x27 || v == 0x2B { return true }            // ' and +
            return false
        }) ?? buffer.endIndex
        return (String(buffer[..<firstNonLiteral]), String(buffer[firstNonLiteral...]))
    }
}
