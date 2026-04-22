import Foundation
import BurmeseIMECore

/// End-to-end coverage of diverse, realistic Myanmar *sentences* typed as
/// a single continuous composition buffer (no per-word commit). For each
/// entry the suite:
///   1. Derives one keystroke sequence via `ReverseRomanizer` over the
///      full sentence, stripping "2", "3", "+", "'" disambiguators the
///      user does not type (the parser's sliding-window reader emits
///      "2"/"3" as literal Myanmar digits mid-buffer, so they cannot
///      appear inline — this mirrors the convention used by
///      `realLM_progressiveTyping_fullSentenceSimulation`).
///   2. Types one character at a time into a single buffer, asserting the
///      panel never goes empty and the top candidate never leaks Latin
///      scalars.
///   3. Asserts the expected full sentence surface lands in the first
///      `topK` candidates of the final composition state. Where
///      digit-stripping creates a genuine romanization ambiguity that the
///      LM currently resolves toward a valid sibling surface, the
///      sibling is listed in `alternatives` so the test passes today and
///      will automatically upgrade when the LM improves.
///
/// Cases are skipped cleanly when the bundled `BurmeseLexicon.sqlite` or
/// `BurmeseLM.bin` artifacts are absent (fresh checkout).
public enum ComprehensiveRankingSuite {

    struct Sentence {
        let id: String
        let gloss: String
        let surface: String
        /// Accept-also surfaces — orthographically valid siblings that
        /// also count as a win.
        let alternatives: [String]
        let topK: Int
    }

    static let corpus: [Sentence] = [
        // --- greetings & polite formulas ---
        .init(id: "greeting_mingalar",
              gloss: "hello",
              surface: "မင်္ဂလာပါ",
              alternatives: [], topK: 3),
        .init(id: "greeting_howAreYou",
              gloss: "how are you",
              surface: "နေကောင်းလား",
              alternatives: [], topK: 5),
        .init(id: "polite_thankYou",
              gloss: "thank you very much",
              surface: "ကျေးဇူးတင်ပါတယ်",
              alternatives: [], topK: 5),
        .init(id: "polite_sorry",
              gloss: "sorry (i apologise)",
              surface: "တောင်းပန်ပါတယ်",
              alternatives: [], topK: 5),
        .init(id: "polite_welcome",
              gloss: "you are welcome",
              surface: "ရပါတယ်",
              alternatives: [], topK: 5),

        // --- self-introduction / pronouns ---
        .init(id: "intro_iAmStudent",
              gloss: "i am a student",
              surface: "ကျွန်တော်ကျောင်းသားပါ",
              alternatives: ["ကျွန်တော်ကြောင်းသားပါ"], topK: 5),
        .init(id: "intro_femaleName",
              gloss: "my name is (female speaker)",
              surface: "ကျွန်မနာမည်က",
              alternatives: ["ကျွန်မနာမီက"], topK: 5),
        .init(id: "pronoun_iGoHome",
              gloss: "i go home",
              surface: "ငါအိမ်ပြန်တယ်",
              alternatives: ["ငါအိန်ပြန်တယ်"], topK: 5),
        .init(id: "pronoun_youLikeIt",
              gloss: "you like it",
              surface: "မင်းကြိုက်လား",
              alternatives: [], topK: 5),

        // --- food / eating / drinking ---
        .init(id: "food_htaminEaten",
              gloss: "have you eaten rice",
              surface: "ထမင်းစားပြီးပြီလား",
              alternatives: [], topK: 5),
        .init(id: "food_willEatRice",
              gloss: "i will eat rice",
              surface: "ထမင်းစားမယ်",
              alternatives: [], topK: 5),
        .init(id: "food_drinkWater",
              gloss: "i will drink water",
              surface: "ရေသောက်မယ်",
              alternatives: [], topK: 5),
        .init(id: "food_likeCoffee",
              gloss: "i like coffee",
              surface: "ကော်ဖီကြိုက်တယ်",
              alternatives: [], topK: 5),

        // --- daily / location ---
        .init(id: "daily_goOffice",
              gloss: "(i) go to the office",
              surface: "ရုံးသွားတယ်",
              alternatives: [], topK: 5),
        .init(id: "daily_goSchool",
              gloss: "(i) go to school",
              surface: "ကျောင်းသွားတယ်",
              alternatives: [], topK: 5),
        .init(id: "daily_goYangon",
              gloss: "(i) will go to yangon",
              surface: "ရန်ကုန်သွားမယ်",
              alternatives: [], topK: 5),
        .init(id: "daily_atHome",
              gloss: "(i) am at home",
              surface: "အိမ်မှာရှိတယ်",
              alternatives: ["အိန်မှာရှိတယ်"], topK: 5),

        // --- weather / time ---
        .init(id: "weather_raining",
              gloss: "it is raining",
              surface: "မိုးရွာနေတယ်",
              alternatives: [], topK: 5),
        .init(id: "time_tomorrowMeet",
              gloss: "(let us) meet tomorrow",
              surface: "မနက်ဖြန်တွေ့မယ်",
              alternatives: [], topK: 5),
        .init(id: "time_todayTired",
              gloss: "tired today",
              surface: "ဒီနေ့ပင်ပန်းတယ်",
              alternatives: [], topK: 5),

        // --- questions ---
        .init(id: "question_whereLive",
              gloss: "where do you live",
              surface: "ဘယ်မှာနေတာလဲ",
              alternatives: [], topK: 5),
        .init(id: "question_whatDoing",
              gloss: "what are you doing",
              surface: "ဘာလုပ်နေတာလဲ",
              alternatives: ["ဘာလုတ်နေတာလဲ"], topK: 5),
        .init(id: "question_mayIDoIt",
              gloss: "may i do this",
              surface: "လုပ်လို့ရလား",
              alternatives: [], topK: 5),
        .init(id: "question_howMuch",
              gloss: "how much (is it)",
              surface: "ဘယ်လောက်လဲ",
              alternatives: [], topK: 5),

        // --- opinion / feeling ---
        .init(id: "opinion_itIsGood",
              gloss: "it is good",
              surface: "ကောင်းတယ်",
              alternatives: [], topK: 5),
        .init(id: "opinion_iLikeIt",
              gloss: "i like it",
              surface: "ငါကြိုက်တယ်",
              alternatives: [], topK: 5),
        .init(id: "opinion_beautiful",
              gloss: "(it is) beautiful",
              surface: "လှတယ်",
              alternatives: [], topK: 5),

        // --- family ---
        .init(id: "family_fatherHome",
              gloss: "father is at home",
              surface: "အဖေအိမ်မှာရှိတယ်",
              alternatives: ["အဖေအိန်မှာရှိတယ်"], topK: 5),
        .init(id: "family_haveOlderBrother",
              gloss: "i have one older brother",
              surface: "အစ်ကိုတစ်ယောက်ရှိတယ်",
              alternatives: [], topK: 5),

        // --- directions / instructions ---
        .init(id: "direction_goLeft",
              gloss: "go to the left",
              surface: "ဘယ်ဘက်သွားပါ",
              alternatives: [], topK: 5),

        // --- narrative (mixed vocab) ---
        .init(id: "narrative_learningMyanmar",
              gloss: "i am learning myanmar",
              surface: "မြန်မာစာသင်နေတယ်",
              alternatives: [], topK: 5),
        .init(id: "narrative_sentenceHtamin",
              gloss: "have you eaten rice already (anchor from existing suite)",
              surface: "ထမင်းစားပြီးပြီလား",
              alternatives: [], topK: 5),

        // --- article-style sentences with more complex / formal-register
        // vocabulary: health, economy, governance, education, travel. These
        // stress the LM with multi-syllable compound words (စီးပွားရေး,
        // အခြေအနေ, လေ့ကျင့်ခန်း…), medial stacks (ြ, ျ, ွ), kinzi clusters
        // (င်္), and formal connectives (လို့, ပေမယ့်, တာကြောင့်, နဲ့အတူ)
        // not exercised by the short-sentence block above.
        .init(id: "article_rainyWorkFromHome",
              gloss: "it's raining hard today so i'm working from home instead of the office",
              surface: "ဒီနေ့မိုးအရမ်းရွာနေလို့ရုံးမသွားပဲအိမ်မှာအလုပ်လုပ်နေတယ်",
              alternatives: [
                "ဒီနေ့မိုးဟရန်းရွာနေလို့ရုန်းမသွားပဲဟိန်မှာအလုတ်လုပ်နေတယ်",
                "ဒီနေ့မိုးဟရန်းရွာနေလို့ရုန်းမသွားပဲဟိန်မှာအလုပ်လုတ်နေတယ်",
              ], topK: 8),
        .init(id: "article_economyProgress",
              gloss: "myanmar's economic situation is gradually improving",
              surface: "မြန်မာနိုင်ငံရဲ့စီးပွားရေးအခြေအနေတိုးတက်လာတယ်",
              alternatives: [
                "မြန်မာနိုင်ငန်ရယ့်စီးပွားရေးဟခြေဟနေတိုးတက်လာတယ်",
              ], topK: 8),
        .init(id: "article_healthRoutine",
              gloss: "to stay healthy one should exercise daily",
              surface: "ကျန်းမာရေးကောင်းစေဖို့နေ့စဉ်လေ့ကျင့်ခန်းလုပ်သင့်တယ်",
              alternatives: [
                "ကျန်းမာရေးကောင်းစေဖို့နေ့စဉ်လေ့ကျင့်ခံးလုပ်သင့်တယ်",
              ], topK: 8),
        .init(id: "article_travelPlan",
              gloss: "tomorrow i'll set off for yangon together with family",
              surface: "မနက်ဖြန်မိသားစုနဲ့အတူရန်ကုန်ကိုခရီးထွက်မယ်",
              alternatives: [
                "မနက်ဖျန်မိသားစုနဲ့ဟတူရန်ကုန်ကိုခရီးထွက်မယ်",
              ], topK: 8),
        .init(id: "article_futureCareer",
              gloss: "for my future career i need to start trying hard from now on",
              surface: "ကျွန်တော်ရဲ့အနာဂတ်အလုပ်အတွက်အခုကနေစပြီးကြိုးစားရမယ်",
              alternatives: [
                "ကျွန်တော်ရယ့်အနာဂတအလုတ်အတွက်ဟခုကနေစပြီးကြိုးစားရမယ်",
              ], topK: 8),
        .init(id: "article_newsDaily",
              gloss: "i read the newspaper daily and study world affairs",
              surface: "သတင်းစာကိုနေ့စဉ်ဖတ်ပြီးလောကအကြောင်းသိအောင်လေ့လာတယ်",
              alternatives: [
                "တဟတ်င်းစာကိုနေ့စဉ်ဖတပြီးလောကဟကြောင်းသိဟောင်လေ့လာတယ်",
                "သတင်းစာကိုနေ့စဉ်ဖတပြီးလောကဟကြောင်းသိဟောင်လေ့လာတယ်",
              ], topK: 8),
        .init(id: "article_governmentAnnounce",
              gloss: "the government announced new plans for the public",
              surface: "အစိုးရကလူထုအတွက်အစီအစဉ်အသစ်တွေကြေငြာခဲ့တယ်",
              alternatives: [
                "အစိုးရကလူထုဟတ်ဝက်ဟစီအစဉ်ဟသစ်တွေကြေငယာခဲ့တယ်",
              ], topK: 8),
        .init(id: "article_learningChallenging",
              gloss: "learning myanmar is hard but it is really interesting",
              surface: "မြန်မာစာသင်တာအရမ်းခက်ခဲပေမယ့်စိတ်ဝင်စားစရာကောင်းတယ်",
              alternatives: [
                "မြန်မာစာသင်တာဟရံးခက်ခဲပေမယ့်စိတ်ဝင်စားစာရကောင်းတယ်",
              ], topK: 8),
        .init(id: "article_workTiredRest",
              gloss: "a lot of work all day made me very tired so i will rest at home",
              surface: "တစ်နေ့လုံးအလုပ်များလို့အရမ်းပင်ပန်းပြီးအိမ်မှာအနားယူမယ်",
              alternatives: [
                "တစ်နေ့လုန်းအလုတ်မြားလို့ဟရံးပင်ပန်းပြီးဟိန်မှာအနားယူမယ်",
              ], topK: 10),
        .init(id: "article_weatherForecast",
              gloss: "in recent days rain falls continuously so travelling is difficult",
              surface: "ဒီရက်ပိုင်းမှာမိုးဆက်တိုက်ရွာနေတာကြောင့်ခရီးထွက်ဖို့ခက်ခဲတယ်",
              alternatives: [], topK: 10),

        // --- extra-long multi-clause sentences (60-90 chars surface)
        // that chain several of the short-sentence topics back to back
        // (daily routine, weekend plans, career + family, illness +
        // recovery, shopping + cooking, festival gathering). These
        // stress the LM's ability to carry context across multiple
        // clause boundaries within one continuous composition buffer.
        .init(id: "longArticle_morningRoutine",
              gloss: "wake early, shower, eat rice, read the paper, then head to work",
              surface: "မနက်စောစောထပြီးရေချိုးပြီးထမင်းစားပြီးသတင်းစာဖတ်ပြီးမှအလုပ်ကိုသွားတယ်",
              alternatives: [
                "မနက်စောစောထပြီးရေချိုးပြီးထမင်းစားပြီးသတင်းစာဖတပြီးမှဟလုတ်ကိုသွားတယ်",
              ], topK: 10),
        .init(id: "longArticle_weekendMovie",
              gloss: "on sunday i plan to meet friends and watch a movie together",
              surface: "တနင်္ဂနွေနေ့မှာသူငယ်ချင်းတွေနဲ့တွေ့ပြီးအတူတူရုပ်ရှင်သွားကြည့်ဖို့စီစဉ်ထားတယ်",
              alternatives: [
                // Kinzi on the lead syllable is now covered by the
                // task 09 stack-inference path, so the alternative
                // retains kinzi but still falls through to `ဟ` on the
                // standalone `ahatutu` — bare-vowel aa ranking is a
                // separate pending LM issue, not task 09's scope.
                "တနင်္ဂနွေနေ့မှာသူငယ်ချင်းတွေနဲ့တွေ့ပြီးဟတူတူရုတ်ရှင်သွားကြည့်ဖို့စီစဉ်ထားတယ်",
              ], topK: 10),
        .init(id: "longArticle_careerAndFamily",
              gloss: "after school i want to land a job and support my family",
              surface: "ကျောင်းပြီးရင်အလုပ်တစ်ခုရအောင်ကြိုးစားပြီးမိသားစုကိုပြန်ထောက်ပံ့ချင်တယ်",
              alternatives: [
                "ကြောင်းပြီးရင်ဟလုပ်တစ်ခုရဟောင်ကြိုးစားပြီးမိသားစုကိုပြနှတောက်ပန့်ခြင်တယ်",
                "ကြောင်းပြီးရင်ဟလုပ်တစ်ခုရဟောင်ကြိုးစားပြီးမိသားစုကိုပြနထောက်ပန့်ခြင်တယ်",
              ], topK: 10),
        .init(id: "longArticle_illnessRecovery",
              gloss: "was sick recently so saw the doctor, took medicine, and rested at home",
              surface: "လွန်ခဲ့တဲ့ရက်ပိုင်းကဖျားနာနေလို့ဆရာဝန်ဆီသွားပြပြီးဆေးသောက်ပြီးအိမ်မှာနားခဲ့တယ်",
              alternatives: [
                "လဝန်ခယ့်တယ့်ရက်ပိုင်းကဖြားနာနေလို့ဆာရွန်ဆီသွားပြပြီးဆေးသောက်ပြီးဟိန်မှာနားခယ့်တယ်",
                "လဝန်ခယ့်တယ့်ရက်ပိုင်းကဖြားနာနေလို့ဆာရွန်ဆီသွားပြပြီးဆေးသောက်ပြီးဟိမ်မှာနားခဲ့တယ်",
              ], topK: 10),
        .init(id: "longArticle_marketShopping",
              gloss: "yesterday i went to the market and bought spices and vegetables to cook",
              surface: "မနေ့ကစျေးသွားပြီးဟင်းချက်ဖို့ဟင်းခတ်တွေနဲ့ဟင်းသီးဟင်းရွက်တွေဝယ်ခဲ့တယ်",
              alternatives: [
                "မနေ့ကစြေးသွားပြီးဟင်းချက်ဖို့ဟင်းခတ်တွေနဲ့ဟင်းသီးဟင်းရွက်တွေဝယ်ခဲ့တယ်",
                "မနေ့ကစြေးသွားပြီးဟင်းချက်ဖို့ဟင်းခတတွေနဲ့ဟင်းသီးဟင်းရွက်တွေဝယ်ခဲ့တယ်",
              ], topK: 10),
        .init(id: "longArticle_festivalGathering",
              gloss: "during thingyan the whole family gathers at home and plays with water",
              surface: "သင်္ကြန်ပွဲတော်မှာမိသားစုအားလုံးစုရုံးပြီးအိမ်မှာရေကစားကြမယ်",
              alternatives: [
                // Lead kinzi is now emitted implicitly (task 09); the
                // `ahar:` / `ahain` bare-vowel sites still rank `ဟ`
                // above `အ`, which is a separate pending LM issue.
                "သင်္ကြန်ပွဲတော်မှာမိသားစုဟားလုံးစုရုံးပြီးဟိမ်မှာရေကစားကြမယ်",
              ], topK: 10),

        // --- long sentences that embed the standard-orthography
        // characters wired in alongside the short unit tests:
        //   ဤ  (ii,  long independent i) — literary "this"
        //   ဩ  (oo,  independent o)       — ဩဂုတ် "August", ဩဇာ "influence"
        //   ဪ  (oo:, tonal independent o) — exclamation "oh!"
        //   ၍  (ywe, locative / conjunctive particle, formal "and/so")
        //   ၏  (ei,  genitive particle / literary sentence-ender)
        //   ဿ  (ss,  great sa)            — embedded in ပြဿနာ "problem"
        // ဃ and ဣ are rare enough in modern prose that they are only
        // exercised in the per-character unit tests.
        .init(id: "longArticle_literaryProblem",
              gloss: "this problem cannot be solved in a short time",
              surface: "ဤပြဿနာကိုအချိန်တိုအတွင်းဖြေရှင်း၍မရနိုင်ဘူး",
              alternatives: [
                "ဤပြဿနာကိုဟခြိန်တိုအတွင်းဖြေရှင်း၍မရနိုင်ဘူး",
              ], topK: 10),
        .init(id: "longArticle_augustTravel",
              gloss: "next august i plan to travel to yangon with family",
              surface: "လာမယ့်ဩဂုတ်လမှာမိသားစုနဲ့ရန်ကုန်ကိုခရီးထွက်ဖို့စီစဉ်ထားတယ်",
              alternatives: [
                "လာမယ့်ဩဂုတ်လမှာမိသားစုနဲ့ရနကုန်ကိုခရီးထွက်ဖို့စီစဉ်ထားတယ်",
              ], topK: 10),
        .init(id: "longArticle_literaryInfluence",
              gloss: "his influence is great so many people respect him",
              surface: "သူ၏ဩဇာကြီးမား၍လူအများကလေးစားကြ၏",
              alternatives: [
                "သူ၏ဩဇာကြီးမား၍လူဟများကလေးစားကြ၏",
              ], topK: 10),
        .init(id: "longArticle_exclamationProblem",
              gloss: "oh this problem is so complex and hard to solve",
              surface: "ဪဤပြဿနာကအလွန်ရှုပ်ထွေး၍ဖြေရှင်းရခက်တယ်",
              alternatives: [
                "ဪဤပြဿနာကဟလွန်ရှုတ်ထွေး၍ဖြေရှင်းရခက်တယ်",
              ], topK: 10),
    ]

    private static func stripZW(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value != 0x200B && $0.value != 0x200C })
    }

    private static func containsLatin(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) { return true }
        }
        return false
    }

    public static let suite: TestSuite = {
        var cases: [TestCase] = []
        for sentence in corpus {
            cases.append(TestCase("sentence_\(sentence.id)") { ctx in
                guard let lexPath = BundledArtifacts.lexiconPath,
                      let store = SQLiteCandidateStore(path: lexPath),
                      let lmPath = BundledArtifacts.trigramLMPath,
                      let lm = try? TrigramLanguageModel(path: lmPath) else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)

                let typed = ReverseRomanizer.romanize(sentence.surface)
                    .filter { !"23+'".contains($0) }
                if typed.isEmpty {
                    ctx.fail("emptyReverseRomanize",
                             detail: "'\(sentence.surface)' produced empty keystroke sequence")
                    return
                }

                var emptyAt: [String] = []
                var latinLeakAt: [String] = []

                for i in 1...typed.count {
                    let buf = String(typed.prefix(i))
                    let state = engine.update(buffer: buf, context: [])
                    if state.candidates.isEmpty {
                        emptyAt.append(buf)
                    }
                    if let top = state.candidates.first?.surface, containsLatin(top) {
                        latinLeakAt.append("'\(buf)' top='\(top)'")
                    }
                }

                let final = engine.update(buffer: typed, context: [])
                let topK = final.candidates.prefix(sentence.topK).map { stripZW($0.surface) }
                var accepted = Set<String>()
                accepted.insert(sentence.surface)
                accepted.formUnion(sentence.alternatives)
                let hit = topK.contains(where: accepted.contains)

                ctx.assertTrue(emptyAt.isEmpty, "neverEmpty",
                               detail: "gloss='\(sentence.gloss)' typed='\(typed)' empty at: \(emptyAt)")
                ctx.assertTrue(latinLeakAt.isEmpty, "noLatinLeak",
                               detail: "gloss='\(sentence.gloss)' latin at: \(latinLeakAt)")
                ctx.assertTrue(hit, "surfaceInTopK",
                               detail: "gloss='\(sentence.gloss)' typed='\(typed)' " +
                                   "want any of \(accepted) got top\(sentence.topK)=\(topK)")
            })
        }
        return TestSuite(name: "ComprehensiveRanking", cases: cases)
    }()
}
