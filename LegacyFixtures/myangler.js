// Legacy transliteration engine from src/myangler.js
// Pasted verbatim from IMPLEMENTATION_PLAN.md Appendix A for fixture generation.

class Rule {
    constructor(pronunciation, pattern, standalone = false) {
        pattern = pattern.replace(/\u200C/g, '').replace(/\u200D/g, '');
        this.pronunciation = pronunciation;
        this.pattern = Array.from(pattern).map(char => char.codePointAt(0));
        this.standalone = standalone;
    }

    myanmar() {
        return this.pattern.map(code => String.fromCodePoint(code)).join('');
    }
}

const CONSONANTS = {
    "က": "ka",
    "ခ": "kha",
    "ဂ": "ga",
    "ဃ": "gha",
    "င": "nga",
    "ဆ": "hsa",
    "စ": "sa",
    "ဇ": "za",
    "ဈ": "zza",
    "ည": "nya",
    "တ": "ta",
    "သ": "tha",
    "ထ": "hta",
    "ဋ": "t2a",
    "ဌ": "ht2a",
    "န": "na",
    "ဏ": "n2a",
    "ဒ": "da",
    "ဍ": "d2a",
    "ဓ": "dha",
    "ဎ": "dh2a",
    "ပ": "pa",
    "ဖ": "pha",
    "ဗ": "va",
    "ဘ": "ba",
    "မ": "ma",
    "ယ": "ya",
    "ရ": "ra",
    "လ": "la",
    "ဝ": "wa",
    "ဟ": "ha",
    "ဠ": "l2a",
    "အ": "ah"
};

const VOWELS = {
    "+": "္",
    "*": "်",
    "'": "",
    "a": "",
    "ar": "ာ",
    "ar2": "ါ",
    "ar:": "ား",
    "ar2:": "ါး",
    "i.": "ိ",
    "i2.": "ည့်",
    "i": "ီ",
    "i2": "ည်",
    "i:": "ီး",
    "i2:": "ည်း",
    "u.": "ု",
    "u2.": "ဥ",
    "u": "ူ",
    "u2": "ဦ",
    "u:": "ူး",
    "u2:": "ဦး",
    "ay.": "\u200Cေ့",
    "ay": "\u200Cေ",
    "ay2": "ဧ",
    "ay:": "\u200Cေး",
    "e.": "ယ့်",
    "e2.": "ဲ့",
    "e": "ယ်",
    "e:": "ဲ",
    "aw.": "\u200Cော့",
    "aw2.": "\u200Cေါ့",
    "aw": "\u200Cော်",
    "aw2": "\u200Cေါ်",
    "aw:": "\u200Cော",
    "aw2:": "\u200Cေါ",
    "an.": "န့်",
    "an2.": "မ့်",
    "an3.": "ံ့",
    "an": "န်",
    "an2": "မ်",
    "an3": "ံ",
    "an:": "န်း",
    "an2:": "မ်း",
    "o.": "ို့",
    "o2.": "ိုယ့်",
    "o": "ို",
    "o2": "ိုယ်",
    "o:": "ိုး",
    "y": "ြ",
    "y2": "ျ",
    "w": "ွ",
    "et": "က်",
    "at": "တ်",
    "h": "ှ",
    "in.": "င့်",
    "in": "င်",
    "in:": "င်း",
    "it": "စ်",
    "own.": "ုန့်",
    "own2.": "ုမ့်",
    "own3.": "ုံ့",
    "own": "ုန်",
    "own2": "ုမ်",
    "own3": "ုံ",
    "own:": "ုန်း",
    "own2:": "ုမ်း",
    "own3:": "ုံး",
    "out": "\u200Cောက်",
    "out2": "\u200Cေါက်",
    "aung.": "\u200Cောင့်",
    "aung2.": "\u200Cေါင့်",
    "aung": "\u200Cောင်",
    "aung2": "\u200Cေါင်",
    "aung:": "\u200Cောင်း",
    "aung2:": "\u200Cေါင်း",
    "ote": "ုတ်",
    "ote2": "ုပ်",
    "ate": "ိတ်",
    "ate2": "ိပ်",
    "ain.": "ိန့်",
    "ain2.": "ိမ့်",
    "ain": "ိန်",
    "ain2": "ိမ်",
    "ain:": "ိန်း",
    "ain2:": "ိမ်း",
    "ite": "ိုက်",
    "ai.": "ိုင့်",
    "ai": "ိုင်",
    "ai:": "ိုင်း",
    "on.": "ွန့်",
    "on2.": "ွမ့်",
    "on3.": "ွံ့",
    "on": "ွန်",
    "on2": "ွမ်",
    "on3": "ွံ",
    "on:": "ွန်း",
    "on2:": "ွမ်း",
    "ut": "ွတ်"
};

const CONSONANT_BASES = {};
Object.entries(CONSONANTS).forEach(([key, val]) => {
    if (!val.startsWith('a')) {
        CONSONANT_BASES[key] = val.replace(/a/g, '');
    } else {
        CONSONANT_BASES[key] = val;
    }
});

function generateRuleCombinations() {
    let combinationsSet = new Set();
    for (let n_y = 0; n_y <= 1; n_y++) {
        for (let n_y2 = 0; n_y2 <= 1; n_y2++) {
            for (let n_w = 0; n_w <= 1; n_w++) {
                for (let n_h = 0; n_h <= 1; n_h++) {
                    for (let n_none = 0; n_none <= 2; n_none++) {
                        let total = n_y + n_y2 + n_w + n_h + n_none;
                        if (total === 3 && (n_y + n_y2) <= 1) {
                            let combo = []
                            for (let i = 0; i < n_y; i++) combo.push('y');
                            for (let i = 0; i < n_y2; i++) combo.push('y2');
                            for (let i = 0; i < n_w; i++) combo.push('w');
                            for (let i = 0; i < n_h; i++) combo.push('h');
                            for (let i = 0; i < n_none; i++) combo.push(null);
                            combo.sort(function(a, b) {
                                return (a === null ? 1 : -1) - (b === null ? 1 : -1) || (a > b ? 1 : -1);
                            });
                            combinationsSet.add(JSON.stringify(combo));
                        }
                    }
                }
            }
        }
    }
    let combinations = Array.from(combinationsSet).map(str => JSON.parse(str));
    return combinations;
}

const RULES = [
    ...Object.entries(CONSONANT_BASES).map(([pattern, pronunciation]) =>
        new Rule(pronunciation, pattern, true)
    )
];

const combinations = generateRuleCombinations();
Object.entries(CONSONANT_BASES).forEach(([pattern, pronunciation]) => {
    combinations.forEach(rule_combination => {
        const h_present = rule_combination.includes('h');
        const w_present = rule_combination.includes('w');
        const y_present = rule_combination.includes('y');
        const y2_present = rule_combination.includes('y2');

        const newPronunciation =
            (h_present ? 'h' : '') +
            pronunciation +
            (w_present ? 'w' : '') +
            (y_present ? 'y' : '') +
            (y2_present ? 'y2' : '');

        const newPattern =
            pattern +
            (y_present ? 'ြ' : '') +
            (y2_present ? 'ျ' : '') +
            (w_present ? 'ွ' : '') +
            (h_present ? 'ှ' : '');

        RULES.push(new Rule(newPronunciation, newPattern, true));
    });
});

RULES.push(
    new Rule("+", "္"),
    new Rule("*", "်"),
    new Rule("'", ""),
    new Rule("a", ""),
    new Rule("ar", "ာ"),
    new Rule("ar2", "ါ"),
    new Rule("ar:", "ား"),
    new Rule("ar2:", "ါး"),
    new Rule("i.", "ိ"),
    new Rule("i2.", "ည့်"),
    new Rule("i", "ီ"),
    new Rule("i2", "ည်"),
    new Rule("i:", "ီး"),
    new Rule("i2:", "ည်း"),
    new Rule("u.", "ု"),
    new Rule("u2.", "ဥ"),
    new Rule("u", "ူ"),
    new Rule("u2", "ဦ"),
    new Rule("u:", "ူး"),
    new Rule("u2:", "ဦး"),
    new Rule("ay.", "\u200Cေ့"),
    new Rule("ay", "\u200Cေ"),
    new Rule("ay2", "ဧ"),
    new Rule("ay:", "\u200Cေး"),
    new Rule("e.", "ယ့်"),
    new Rule("e2.", "ဲ့"),
    new Rule("e", "ယ်"),
    new Rule("e:", "ဲ"),
    new Rule("aw.", "\u200Cော့"),
    new Rule("aw2.", "\u200Cေါ့"),
    new Rule("aw", "\u200Cော်"),
    new Rule("aw2", "\u200Cေါ်"),
    new Rule("aw:", "\u200Cော"),
    new Rule("aw2:", "\u200Cေါ"),
    new Rule("an.", "န့်"),
    new Rule("an2.", "မ့်"),
    new Rule("an3.", "ံ့"),
    new Rule("an", "န်"),
    new Rule("an2", "မ်"),
    new Rule("an3", "ံ"),
    new Rule("an:", "န်း"),
    new Rule("an2:", "မ်း"),
    new Rule("o.", "ို့"),
    new Rule("o2.", "ိုယ့်"),
    new Rule("o", "ို"),
    new Rule("o2", "ိုယ်"),
    new Rule("o:", "ိုး"),
    new Rule("et", "က်"),
    new Rule("at", "တ်"),
    new Rule("h", "ှ"),
    new Rule("in.", "င့်"),
    new Rule("in", "င်"),
    new Rule("in:", "င်း"),
    new Rule("it", "စ်"),
    new Rule("own.", "ုန့်"),
    new Rule("own2.", "ုမ့်"),
    new Rule("own3.", "ုံ့"),
    new Rule("own", "ုန်"),
    new Rule("own2", "ုမ်"),
    new Rule("own3", "ုံ"),
    new Rule("own:", "ုန်း"),
    new Rule("own2:", "ုမ်း"),
    new Rule("own3:", "ုံး"),
    new Rule("out", "\u200Cောက်"),
    new Rule("out2", "\u200Cေါက်"),
    new Rule("aung.", "\u200Cောင့်"),
    new Rule("aung2.", "\u200Cေါင့်"),
    new Rule("aung", "\u200Cောင်"),
    new Rule("aung2", "\u200Cေါင်"),
    new Rule("aung:", "\u200Cောင်း"),
    new Rule("aung2:", "\u200Cေါင်း"),
    new Rule("ote", "ုတ်"),
    new Rule("ote2", "ုပ်"),
    new Rule("ate", "ိတ်"),
    new Rule("ate2", "ိပ်"),
    new Rule("ain.", "ိန့်"),
    new Rule("ain2.", "ိမ့်"),
    new Rule("ain", "ိန်"),
    new Rule("ain2", "ိမ်"),
    new Rule("ain:", "ိန်း"),
    new Rule("ain2:", "ိမ်း"),
    new Rule("ite", "ိုက်"),
    new Rule("ai.", "ိုင့်"),
    new Rule("ai", "ိုင်"),
    new Rule("ai:", "ိုင်း"),
    new Rule("on.", "ွန့်"),
    new Rule("on2.", "ွမ့်"),
    new Rule("on3.", "ွံ့"),
    new Rule("on", "ွန်"),
    new Rule("on2", "ွမ်"),
    new Rule("on3", "ွံ"),
    new Rule("on:", "ွန်း"),
    new Rule("on2:", "ွမ်း"),
    new Rule("ut", "ွတ်")
);

class MyanglishParser {
    constructor() {
        this.pronunciation_dict = {};
        RULES.forEach(rule => {
            if (!this.pronunciation_dict.hasOwnProperty(rule.pronunciation)) {
                this.pronunciation_dict[rule.pronunciation] = [];
            }
            this.pronunciation_dict[rule.pronunciation].push(rule);
        });
    }

    parse(text) {
        const n = text.length;
        const dp = new Array(n + 1).fill(null);
        dp[0] = { rules: [], output: "", score: 0 };
        const max_sub_length = Math.max(...Object.keys(this.pronunciation_dict).map(key => key.length));

        for (let i = 0; i < n; i++) {
            if (dp[i] === null) continue;
            const { rules: prev_rules, output: prev_output, score: prev_score } = dp[i];
            let matched = false;
            for (let j = i + 1; j <= Math.min(n, i + max_sub_length); j++) {
                const substr = text.slice(i, j);
                if (this.pronunciation_dict.hasOwnProperty(substr)) {
                    matched = true;
                    const rules = this.pronunciation_dict[substr];
                    for (const rule of rules) {
                        const new_rules = prev_rules.concat([rule]);
                        const new_output = prev_output + rule.myanmar();
                        const new_score = new_rules.reduce((a, r) => a + r.pronunciation.length, 0) - new_rules.length;
                        if (dp[j] === null || new_score > dp[j].score) {
                            dp[j] = { rules: new_rules, output: new_output, score: new_score };
                        }
                    }
                }
            }
            if (!matched) {
                const new_rules = prev_rules;
                const new_output = prev_output + text[i];
                const new_score = prev_score;
                if (dp[i + 1] === null || new_score >= dp[i + 1].score) {
                    dp[i + 1] = { rules: new_rules, output: new_output, score: new_score };
                }
            }
        }

        if (dp[n]) {
            const { output: best_output } = dp[n];
            return this._adjust_zero_width_non_joiner(best_output);
        } else {
            return "";
        }
    }

    _adjust_zero_width_non_joiner(text) {
        text = text.replace(/\u200c/g, '');
        const myanmar_vowel_signs = ['ေ', 'ဲ', 'ိ', 'ီ', 'ို', 'ု', 'ူ', 'ေါ', 'ှ'];
        if (text && myanmar_vowel_signs.includes(text[0])) {
            text = '\u200c' + text;
        }
        return text;
    }
}

class MyanmarParser {
    constructor() {
        this.myanmar_dict = {};
        for (let rule of RULES) {
            const myanmar_text = rule.myanmar();
            if (!(myanmar_text in this.myanmar_dict)) {
                this.myanmar_dict[myanmar_text] = [];
            }
            this.myanmar_dict[myanmar_text].push(rule);
        }
    }

    parse(text) {
        const n = text.length;
        const dp = new Array(n + 1).fill(null);
        dp[0] = [[], "", 0];
        const max_sub_length = Math.max(...Object.keys(this.myanmar_dict).map(key => key.length));

        for (let i = 0; i < n; i++) {
            if (dp[i] === null) continue;
            const [prev_rules, prev_output, prev_score] = dp[i];
            let matched = false;

            for (let j = i + 1; j <= Math.min(n, i + max_sub_length); j++) {
                const substr = text.slice(i, j);
                if (substr in this.myanmar_dict) {
                    matched = true;
                    const rules = this.myanmar_dict[substr];
                    for (let rule of rules) {
                        const new_rules = prev_rules.concat(rule);
                        const new_output = prev_output + rule.pronunciation;
                        const new_score = prev_score + rule.myanmar().length;
                        if (dp[j] === null || new_score > dp[j][2]) {
                            dp[j] = [new_rules, new_output, new_score];
                        }
                    }
                }
            }

            if (!matched) {
                const new_rules = prev_rules;
                const new_output = prev_output + text[i];
                const new_score = prev_score;
                if (dp[i + 1] === null || new_score >= dp[i + 1][2]) {
                    dp[i + 1] = [new_rules, new_output, new_score];
                }
            }
        }
        if (dp[n]) {
            const [best_rules, best_output, best_score] = dp[n];
            return best_output;
        } else {
            return "";
        }
    }
}

if (typeof module === 'object') {
    module.exports.MyanglishParser = MyanglishParser;
    module.exports.MyanmarParser = MyanmarParser;
    module.exports.CONSONANTS = CONSONANTS;
    module.exports.VOWELS = VOWELS;
    module.exports.RULES = RULES;
}
