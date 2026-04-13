#!/usr/bin/env node
/**
 * build_lexicon.js
 *
 * Builds a comprehensive Burmese IME lexicon TSV from four legacy JSON files:
 *   - mm_tokens.json: 82,082 Burmese surface forms (dictionary-indexed words)
 *   - mm_index.json:  Burmese surface → array of entry IDs they appear in
 *   - entries.json:   [english_headword, definition, frequency_rank]
 *   - en_index.json:  [english_term, entry_id] pairs
 *
 * Output: Packages/BurmeseIMECore/Data/BurmeseLexiconSource.tsv
 *
 * Scoring strategy:
 *   entries.json has a rank field (0 = most common, 30000 = rare).
 *   For each Burmese token in mm_index, we compute importance as:
 *     avgInvertedRank * sqrt(refCount) * lengthMultiplier
 *   Definition-extracted tokens get a secondary, lower-weighted score.
 *   Final scores are log-normalized to 1–10000.
 */

const fs = require('fs');
const path = require('path');

const BASE = __dirname;
const OUT = path.join(BASE, '..', 'Packages', 'BurmeseIMECore', 'Data', 'BurmeseLexiconSource.tsv');

console.error('Loading legacy data...');
const mmTokens = JSON.parse(fs.readFileSync(path.join(BASE, 'mm_tokens.json'), 'utf8'));
const mmIndex = JSON.parse(fs.readFileSync(path.join(BASE, 'mm_index.json'), 'utf8'));
const entries = JSON.parse(fs.readFileSync(path.join(BASE, 'entries.json'), 'utf8'));

const MAX_RANK = 30000;

// ─── Helpers ────────────────────────────────────────────────────────────────

// Myanmar Unicode ranges
const MYANMAR_BASE_RE = /[\u1000-\u1021\u1025-\u1027]/; // consonants + independent vowels
const MYANMAR_ONLY_RE = /^[\u1000-\u109F\u200C\u200D]+$/;
const MYANMAR_SEGMENT_RE = /[\u1000-\u109F]+/g;
// Burmese punctuation to strip
const PUNCT_RE = /[။၊\u200C\u200D]+$/;
const LEADING_PUNCT_RE = /^[။၊\u200C\u200D]+/;

function cleanBurmese(s) {
    return s.replace(PUNCT_RE, '').replace(LEADING_PUNCT_RE, '');
}

function burmeseCharLen(s) {
    return [...s].length;
}

// ─── Step 1: Entry importance scores ────────────────────────────────────────
// Lower rank = more common. Invert: importance = MAX_RANK - rank.
const entryImportance = new Float64Array(entries.length);
for (let i = 0; i < entries.length; i++) {
    entryImportance[i] = MAX_RANK - entries[i][2];
}

// ─── Step 2: Score mm_tokens (primary source — dictionary-indexed words) ────
const primaryScores = new Map();

for (const token of mmTokens) {
    const refIds = mmIndex[token];
    if (!refIds || refIds.length === 0) continue;

    let totalImportance = 0;
    for (const id of refIds) {
        if (id >= 0 && id < entryImportance.length) {
            totalImportance += Math.max(entryImportance[id], 1); // floor at 1 so every entry counts
        }
    }

    const avgImportance = totalImportance / refIds.length;
    const refBoost = Math.sqrt(refIds.length);
    let score = avgImportance * refBoost + 1; // +1 ensures every token gets a positive score

    // Length-based multiplier for IME relevance
    const charLen = burmeseCharLen(token);
    if (charLen <= 2) score *= 2.0;       // single syllable — highest value
    else if (charLen <= 4) score *= 1.5;   // short word
    else if (charLen <= 8) score *= 1.0;   // normal word
    else if (charLen <= 12) score *= 0.7;  // compound/phrase
    else if (charLen <= 20) score *= 0.4;  // long phrase
    else score *= 0.15;                    // sentence fragment

    if (score > 0) primaryScores.set(token, score);
}

console.error(`Primary (mm_tokens): ${primaryScores.size} scored entries.`);

// ─── Step 3: Extract Burmese words from definitions (secondary source) ──────
// Split definition text into Burmese segments, clean punctuation, deduplicate.
const secondaryScores = new Map();

for (let i = 0; i < entries.length; i++) {
    const def = entries[i][1];
    const importance = entryImportance[i];
    const adjImportance = Math.max(importance, 1);

    const matches = def.match(MYANMAR_SEGMENT_RE);
    if (!matches) continue;

    for (let raw of matches) {
        const cleaned = cleanBurmese(raw);
        if (!cleaned) continue;
        if (!MYANMAR_BASE_RE.test(cleaned)) continue;

        const charLen = burmeseCharLen(cleaned);
        if (charLen < 2 || charLen > 20) continue;

        // Weight by importance and length preference
        let w = adjImportance;
        if (charLen <= 4) w *= 1.3;
        else if (charLen > 12) w *= 0.4;

        secondaryScores.set(cleaned, (secondaryScores.get(cleaned) || 0) + w);
    }
}

console.error(`Secondary (definitions): ${secondaryScores.size} unique segments.`);

// ─── Step 4: Merge into final lexicon ───────────────────────────────────────
const finalLexicon = new Map();

// Primary source gets full weight
for (const [token, score] of primaryScores) {
    const cleaned = cleanBurmese(token);
    if (!cleaned) continue;
    finalLexicon.set(cleaned, (finalLexicon.get(cleaned) || 0) + score);
}

// Secondary source gets 20% weight — supplements, doesn't dominate
for (const [token, score] of secondaryScores) {
    // Only add if it passes quality filters
    if (!MYANMAR_ONLY_RE.test(token)) continue;
    finalLexicon.set(token, (finalLexicon.get(token) || 0) + score * 0.2);
}

console.error(`Merged lexicon: ${finalLexicon.size} unique surfaces.`);

// ─── Step 5: Normalize to 1–10000 scale (log-normalized) ───────────────────
const scores = [...finalLexicon.values()].filter(s => s > 0);
scores.sort((a, b) => a - b);
const logMin = Math.log(scores[0] + 1);
const logMax = Math.log(scores[scores.length - 1] + 1);
const logRange = logMax - logMin || 1;

function normalize(raw) {
    if (raw <= 0) return 1;
    return Math.max(1, Math.round(1 + ((Math.log(raw + 1) - logMin) / logRange) * 9999));
}

// ─── Step 5a: Curated high-value entries with override readings ─────────────
// These are essential words that must appear in the lexicon with correct
// readings, regardless of whether they were extracted from the data.
const curatedEntries = [
    // [surface, minFreq, overrideReading?]
    ['မင်္ဂလာပါ', 10000, 'min+galarpar2'],        // hello
    ['မင်္ဂလာ', 9000, 'min+galar'],                // auspicious
    ['ကျေးဇူးတင်ပါတယ်', 9500, null],              // thank you
    ['ရွေးချယ်', 7500, null],                         // choose/select
    ['ကြော်', 6000, null],                            // fry
    ['သာ', 9000, null],                               // only/pleasant
    ['ပါ', 9200, null],                               // polite particle
    ['ကောင်း', 8500, null],                           // good
    ['ဘာ', 8000, null],                               // what
    ['ဟုတ်', 7500, null],                             // correct/true
    ['နေ', 8000, null],                                // stay/live
    ['ကြ', 7000, null],                               // plural verb particle
    ['တယ်', 9500, null],                              // sentence-final particle
    ['ပြည်', 7000, null],                              // country/state
    ['မြန်မာ', 9000, null],                            // Myanmar
    ['ဗမာ', 6000, null],                               // Burma(n)
    ['ရေ', 7500, null],                                // water
    ['ကလေး', 7000, null],                             // child
    ['စာ', 8000, null],                                // letter/text
    ['ရှမ်းခေါက်ဆွဲ', 6000, null],                    // shan noodles
    ['ကျေးဇူး', 8500, null],                          // gratitude
    ['ဟုတ်ကဲ့', 8000, null],                          // yes (polite)
    ['မဟုတ်', 8500, null],                             // not
    ['ဟုတ်တယ်', 8000, null],                          // that's right
    ['ဘယ်', 7500, null],                              // where/which
    ['ဘယ်လို', 7500, null],                            // how
    ['ဘာလဲ', 7500, null],                             // what is it
    ['ဘယ်မှာ', 7500, null],                            // where (at)
    ['ဘယ်သူ', 7000, null],                            // who
    ['ဘယ်အချိန်', 7000, null],                        // when
    ['ဘယ်နှစ်', 6500, null],                           // how many
    ['ဘယ်လောက်', 7000, null],                         // how much
    ['ခင်ဗျာ', 8000, null],                           // sir/polite address
    ['ရှင်', 7500, null],                              // you (polite, female)
    ['ကျွန်တော်', 8000, null],                        // I (male)
    ['ကျွန်မ', 7500, null],                            // I (female)
    ['သူ', 7800, null],                               // he/she
    ['သူမ', 7000, null],                               // she
    ['သူတို့', 7500, null],                             // they
    ['ငါ', 7000, null],                                // I (casual)
    ['မင်း', 7000, null],                              // you (casual)
    ['ဒီ', 7500, null],                                // this
    ['ဟို', 7000, null],                               // that
    ['အဲဒီ', 7500, null],                              // that (demonstrative)
    ['ဒီမှာ', 7000, null],                             // here
    ['ဟိုမှာ', 6500, null],                            // there
    ['လာ', 8000, null],                                // come
    ['သွား', 8000, null],                              // go
    ['စား', 8000, null],                               // eat
    ['သောက်', 7500, null],                             // drink
    ['ပြော', 8000, null],                              // say/speak
    ['မြင်', 7500, null],                              // see
    ['ကြား', 7500, null],                              // hear
    ['သိ', 8000, null],                                // know
    ['ချစ်', 7500, null],                              // love
    ['ကူညီ', 7500, null],                              // help
    ['ရောက်', 7500, null],                             // arrive
    ['ပေး', 8000, null],                               // give
    ['ယူ', 7500, null],                                // take
    ['ထိုင်', 7000, null],                              // sit
    ['ရပ်', 7000, null],                               // stand/stop
    ['အိပ်', 7000, null],                              // sleep
    ['နိုး', 7000, null],                               // wake
    ['ပြေး', 7000, null],                              // run
    ['လမ်းလျှောက်', 6500, null],                       // walk
    ['ကောင်းပါတယ်', 8500, null],                      // it's fine/good
    ['နေကောင်းလား', 8000, null],                      // how are you?
    ['ဘယ်သွားမလဲ', 7000, null],                       // where are you going?
    ['ဘာစားမလဲ', 7000, null],                          // what will you eat?
    ['ကျေးဇူးပြု၍', 7500, null],                      // please
    ['တစ်', 7500, null],                               // one
    ['နှစ်', 7500, null],                              // two
    ['သုံး', 7500, null],                              // three
    ['လေး', 7500, null],                               // four
    ['ငါး', 7500, null],                               // five
    ['ခြောက်', 7000, null],                            // six
    ['ခုနစ်', 7000, null],                              // seven
    ['ရှစ်', 7000, null],                              // eight
    ['ကိုး', 7000, null],                              // nine
    ['ဆယ်', 7000, null],                               // ten
    ['ရာ', 7000, null],                                // hundred
    ['ထောင်', 6500, null],                             // thousand
    ['သောင်း', 6500, null],                            // ten thousand
    ['သိန်း', 6500, null],                             // hundred thousand
    ['သန်း', 6500, null],                              // million
    ['တနင်္ဂနွေ', 6000, null],                          // Sunday
    ['တနင်္လာ', 6000, null],                            // Monday
    ['အင်္ဂါ', 6000, null],                             // Tuesday
    ['ဗုဒ္ဓဟူး', 6000, null],                           // Wednesday
    ['ကြာသပတေး', 6000, null],                          // Thursday
    ['သောကြာ', 6000, null],                            // Friday
    ['စနေ', 6000, null],                               // Saturday
    ['ယနေ့', 7000, null],                              // today
    ['မနေ့', 7000, null],                               // yesterday
    ['မနက်ဖြန်', 7000, null],                           // tomorrow
    ['အခု', 7500, null],                               // now
    ['အရင်', 7000, null],                              // before/previous
    ['နောက်', 7500, null],                              // after/next/behind
];

// Override map: surface → [minFreq, reading]
const curatedOverrides = new Map();
for (const [surface, minFreq, reading] of curatedEntries) {
    curatedOverrides.set(surface, [minFreq, reading]);
    // Ensure surface is in the lexicon with at least the curated score
    const existing = finalLexicon.get(surface) || 0;
    // We'll apply the floor after normalization, but ensure it exists
    if (!finalLexicon.has(surface)) {
        // Give it a score that will roughly map to its target frequency
        finalLexicon.set(surface, avgScoreForTarget(minFreq));
    }
}

// Helper: approximate raw score needed for a target normalized frequency
function avgScoreForTarget(targetFreq) {
    // Estimate based on current score distribution — will be corrected later
    const scores = [...finalLexicon.values()].filter(s => s > 0);
    scores.sort((a, b) => a - b);
    const idx = Math.floor((targetFreq / 10000) * scores.length);
    return scores[Math.min(idx, scores.length - 1)] || 1;
}

// ─── Step 6: Filter and output ──────────────────────────────────────────────
const output = [];
for (const [surface, rawScore] of finalLexicon) {
    if (!MYANMAR_BASE_RE.test(surface)) continue;
    if (!MYANMAR_ONLY_RE.test(surface)) continue;
    let freq = normalize(rawScore);

    // Apply curated floor and get override reading
    let overrideReading = null;
    if (curatedOverrides.has(surface)) {
        const [minFreq, reading] = curatedOverrides.get(surface);
        freq = Math.max(freq, minFreq);
        overrideReading = reading;
    }

    output.push({ surface, freq, overrideReading });
}

// Sort by frequency descending, then by surface for stability
output.sort((a, b) => b.freq - a.freq || a.surface.localeCompare(b.surface));

console.error(`Final lexicon: ${output.length} entries.`);

// ─── Step 7: Write TSV ─────────────────────────────────────────────────────
const lines = [];
lines.push('# Burmese Lexicon Source — generated from legacy dictionary data');
lines.push('# Format: surface<TAB>frequency[<TAB>override_reading]');
lines.push(`# Generated: ${new Date().toISOString()}`);
lines.push(`# Total entries: ${output.length}`);
lines.push(`# Sources: mm_tokens (${primaryScores.size}), definitions (${secondaryScores.size})`);

for (const entry of output) {
    if (entry.overrideReading) {
        lines.push(`${entry.surface}\t${entry.freq}\t${entry.overrideReading}`);
    } else {
        lines.push(`${entry.surface}\t${entry.freq}`);
    }
}

fs.writeFileSync(OUT, lines.join('\n') + '\n', 'utf8');
console.error(`\nWrote ${output.length} entries to ${OUT}`);

// ─── Distribution stats ────────────────────────────────────────────────────
const bands = [
    [9000, 10000, 'Top'],
    [7000, 8999, 'High'],
    [4000, 6999, 'Mid-high'],
    [2000, 3999, 'Mid'],
    [1, 1999, 'Low'],
];
console.error('\nFrequency distribution:');
for (const [lo, hi, label] of bands) {
    const count = output.filter(e => e.freq >= lo && e.freq <= hi).length;
    console.error(`  ${label.padEnd(10)} (${lo}-${hi}): ${count}`);
}

console.error('\nTop 40 entries:');
for (const e of output.slice(0, 40)) {
    console.error(`  ${String(e.freq).padStart(5)}\t${e.surface}`);
}

console.error('\nSample short common words:');
const shortCommon = output.filter(e => burmeseCharLen(e.surface) <= 4 && e.freq >= 5000);
for (const e of shortCommon.slice(0, 30)) {
    console.error(`  ${String(e.freq).padStart(5)}\t${e.surface}`);
}
