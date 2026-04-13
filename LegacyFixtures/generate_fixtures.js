#!/usr/bin/env node
// Generates and validates legacy fixture data from the web transliteration engine.
// Run: node generate_fixtures.js

const { MyanglishParser, MyanmarParser, RULES } = require('./myangler');

const forward = new MyanglishParser();
const reverse = new MyanmarParser();

function escapeUnicode(str) {
    return Array.from(str).map(ch => {
        const cp = ch.codePointAt(0);
        if (cp > 0x7e || cp < 0x20) {
            return '\\u{' + cp.toString(16) + '}';
        }
        return ch;
    }).join('');
}

// --- Known-Good Legacy Conversions ---
const knownGood = [
    ['min+galarpar2', 'မင်္ဂလာပါ'],
    ['ahin+gar2gyoh*', 'အင်္ဂါဂြိုဟ်'],
    ['hran2:khout2hswe:', 'ရှမ်းခေါက်ဆွဲ'],
    ['rway:khy2e', 'ရွေးချယ်'],
    ['kyaw', 'ကြော်'],
    ['kyaw2', 'ကြေါ်'],
    ['thar', 'သာ'],
    ['thar2', 'သါ'],
];

// --- Known-Bad Legacy Conversions ---
const knownBad = [
    ['par', 'ပာ'],
    ['kya2', 'ကြ2'],
    ['foo', 'fိုို'],
    ['abc', 'ဘc'],
    ['mingalarpar2', 'မီငလာပါ'],
    ['nay2', 'နဧ'],
];

// --- Leading-Vowel / U+200C Fixtures ---
const leadingVowel = [
    ['u', '\u200Cူ'],
    ['ay', '\u200Cေ'],
    ['aw', '\u200Cော်'],
    ['aw2', '\u200Cေါ်'],
    ['aw:', '\u200Cော'],
    ['aw2:', '\u200Cေါ'],
    ['own', '\u200Cုန်'],
    ['own2', '\u200Cုမ်'],
    ['own3', '\u200Cုံ'],
];

// --- Reverse Parser Fixtures ---
const reverseFixtures = [
    ['မင်္ဂလာပါ', 'min+glarpar2'],
    ['ကြ', 'ky'],
    ['ကျ', 'ky2'],
    ['ကွ', 'kw'],
    ['ကှ', 'hk'],
    ['ကျွှ', 'hkwy2'],
    ['ပာ', 'par'],
    ['ဧ', 'ay2'],
    ['ဦး', 'u2:'],
];

let pass = 0;
let fail = 0;

function check(label, input, expected, actual) {
    if (expected === actual) {
        pass++;
    } else {
        fail++;
        console.error(`FAIL [${label}] input="${input}" expected="${escapeUnicode(expected)}" got="${escapeUnicode(actual)}"`);
    }
}

console.log('=== Known-Good Forward Conversions ===');
for (const [input, expected] of knownGood) {
    const actual = forward.parse(input);
    check('good', input, expected, actual);
}

console.log('=== Known-Bad Forward Conversions ===');
for (const [input, expected] of knownBad) {
    const actual = forward.parse(input);
    check('bad', input, expected, actual);
}

console.log('=== Leading-Vowel / U+200C Fixtures ===');
for (const [input, expected] of leadingVowel) {
    const actual = forward.parse(input);
    check('vowel', input, expected, actual);
}

console.log('=== Reverse Parser Fixtures ===');
for (const [input, expected] of reverseFixtures) {
    const actual = reverse.parse(input);
    check('reverse', input, expected, actual);
}

console.log(`\nResults: ${pass} passed, ${fail} failed out of ${pass + fail} total`);
console.log(`Rule count: ${RULES.length}`);

if (fail > 0) {
    process.exit(1);
}
