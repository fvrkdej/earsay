// TextPrep: turn any text into a list of sentences the voice can say safely.
//
// Why: the voice can hold only about 15 seconds of speech per go (its "KV cache").
// Text with no full stops (notes, bullets, headings) used to merge into one giant
// run-on that either crashed or got words dropped (15 Nov). So we:
// 1. Treat every line as its own sentence; add a full stop where one is missing.
// 2. Split long sentences (over 36 words) at the most natural point and join the
//    halves with "…", which on Deji's ear test (15 Nov) kept her voice carrying on
//    instead of dropping as if the sentence had ended.
// 3. If there's no natural point, split at a word boundary near the middle.
// The app then streams the sentences one by one.
import Foundation

public struct Sentence: Equatable {
    public let text: String
    /// Last sentence of a paragraph: the app adds a slightly longer pause after it.
    public let endsParagraph: Bool
    /// Last sentence of a line inside a paragraph (a list item): a short pause after it.
    public var endsLine: Bool = false
    /// Which paragraph of the original it came from (for the reader window).
    public var paragraph: Int = 0
}

public enum TextPrep {
    /// Sentences longer than this many words get split.
    public static let maxWords = 36
    /// Never leave a piece shorter than this when splitting at punctuation.
    static let minPiece = 6

    // A comma then one of these usually starts the main clause ("..., we will know").
    static let subjectWords: Set<String> = [
        "we", "they", "it", "i", "you", "he", "she", "this", "that", "these", "those", "there",
    ]
    static let joinWords: Set<String> = [
        "and", "but", "or", "so", "because", "which", "while", "although", "though",
        "yet", "where", "when", "whereas", "unless", "until", "since", "then", "if", "who",
    ]

    /// The main entry: text in, safe sentences out, in reading order.
    public static func sentences(from text: String) -> [Sentence] {
        document(from: text).sentences
    }

    /// The sentences to speak, plus the original paragraphs to show on screen (lightly
    /// tidied, but in the book's own words). Each sentence knows its paragraph.
    public static func document(from text: String) -> (sentences: [Sentence], paragraphs: [String]) {
        var out: [Sentence] = []
        var shown: [String] = []
        // Paragraphs are separated by blank lines; each line inside is its own unit.
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for paragraph in paragraphs {
            // Each line (a list item, a heading line) is grouped on its own and ends with a
            // short pause. Only a one-word line is merged into the next one (17 Nov: merging 3-word table rows ran them together),
            // because very short pieces make the voice fumble.
            var lines: [[String]] = []
            var tiny: [String] = []
            for rawLine in paragraph.components(separatedBy: "\n") {
                let cleaned = clean(stripBullet(rawLine.trimmingCharacters(in: .whitespaces)))
                guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                let line = withFullStop(cleaned)
                var pieces: [String] = []
                for s in splitSentences(line) { pieces += smooth(s) }
                if line.split(separator: " ").count <= 1 { tiny += pieces; continue }
                lines.append(groupShort(tiny + pieces))
                tiny = []
            }
            if !tiny.isEmpty {
                if lines.isEmpty { lines.append(groupShort(tiny)) }
                else { lines[lines.count - 1] = groupShort(lines[lines.count - 1] + tiny) }
            }
            guard !lines.isEmpty else { continue }
            for (li, pieces) in lines.enumerated() {
                for (i, p) in pieces.enumerated() {
                    let lastOfLine = i == pieces.count - 1
                    out.append(Sentence(text: p, endsParagraph: lastOfLine && li == lines.count - 1,
                                        endsLine: lastOfLine, paragraph: shown.count))
                }
            }
            shown.append(display(paragraph))
        }
        return (out, shown)
    }

    /// How `document` turns the lines of one paragraph into spoken lines: each entry is one spoken
    /// line, as the numbers of the paragraph's own lines it was made from. Lines with no letters
    /// or numbers are dropped, and a one-word line ("Audio:") is spoken together with the line
    /// after it. The on-screen highlight uses this to stay on the line being spoken.
    public static func lineGroups(_ paragraph: String) -> [[Int]] {
        var groups: [[Int]] = []
        var tiny: [Int] = []
        for (i, rawLine) in paragraph.components(separatedBy: "\n").enumerated() {
            let cleaned = clean(stripBullet(rawLine.trimmingCharacters(in: .whitespaces)))
            guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if withFullStop(cleaned).split(separator: " ").count <= 1 { tiny.append(i); continue }
            groups.append(tiny + [i])
            tiny = []
        }
        if !tiny.isEmpty {
            if groups.isEmpty { groups.append(tiny) } else { groups[groups.count - 1] += tiny }
        }
        return groups
    }

    /// A paragraph as it should look in the reader: the original words, minus markdown marks.
    public static func display(_ paragraph: String) -> String {
        paragraph.components(separatedBy: "\n").map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            l = l.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"^[-*•‣◦▪]\s+"#, with: "•  ", options: .regularExpression)
            l = l.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            l = l.replacingOccurrences(of: #"(\*\*|__|`)"#, with: "", options: .regularExpression)
            return l
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// Old name kept for the probe: the same result joined back into one string.
    public static func smoothLongSentences(_ text: String) -> String {
        sentences(from: text).map(\.text).joined(separator: " ")
    }

    // MARK: - Cleaning: things the voice reads wrong
    //
    // Every rule here came from a transcript of what she actually said (15 Nov):
    // "$1,200" -> "twenty thousand dollars", "(2008)" -> "two hundred and eight",
    // "[2, 3]" -> "Three", emojis made her repeat a word, "NEVER" was spelled out
    // by an earlier rule, "@" was dropped, dates and phone numbers came out as noise.
    // MARK: Pronunciations the listener has taught her (Settings > Pronunciations)

    private static let sayAsLock = NSLock()
    nonisolated(unsafe) private static var _sayAs: [(word: String, say: String)] = []
    /// Say `word` as `say`: whole words or phrases, any capitals. Set from the app's settings;
    /// read while text is prepared off the main thread, hence the lock.
    public static var sayAs: [(word: String, say: String)] {
        get { sayAsLock.lock(); defer { sayAsLock.unlock() }; return _sayAs }
        set { sayAsLock.lock(); _sayAs = newValue; sayAsLock.unlock() }
    }
    /// Put in front of a word to have it read as written, ignoring `sayAs`. The "Before"
    /// button in Settings uses it so you can compare. Removed before she speaks.
    public static let asWritten = "\u{E000}"

    static func applySayAs(_ line: String) -> String {
        var t = line
        for (word, say) in sayAs where !word.isEmpty && !say.isEmpty {
            let pattern = "(?<![\\w\\x{E000}])" + NSRegularExpression.escapedPattern(for: word) + "(?!\\w)"
            t = t.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: say),
                                       options: [.regularExpression, .caseInsensitive])
        }
        return t.replacingOccurrences(of: asWritten, with: "")
    }

    static func clean(_ line: String) -> String {
        var t = applySayAs(line)
        func sub(_ pattern: String, _ with: String) {
            t = t.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        func map(_ pattern: String, _ f: ([String]) -> String) {
            t = replace(t, pattern, f)
        }
        sub(#"^#{1,6}\s+"#, "")                          // markdown headings
        sub(#"^>\s?"#, "")                               // quote marks
        sub(#"^\|\s*|\s*\|$"#, "")                        // table rows: drop the outer pipes
        sub(#"\[([^\]]+)\]\([^)]*\)"#, "$1")             // markdown links [text](url) -> text
        sub(#"https?://\S+|www\.\S+"#, "")               // bare links: skip
        sub(#"\[\d+(\s*,\s*\d+)*\]"#, "")                // citation marks [1] [2, 3]
        sub(#"[\p{Extended_Pictographic}\x{FE0F}\x{200D}\x{20E3}]"#, "")   // emojis
        sub(#"[*_`]+(?=\S)|(?<=\S)[*_`]+"#, "")          // emphasis and code marks
        sub(#"\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b"#, "")  // commit hashes: skip

        // People and places on the internet.
        map(#"([\w.+-]+)@([\w-]+(?:\.[\w-]+)+)"#) { $0[1] + " at " + $0[2].replacingOccurrences(of: ".", with: " dot ") }
        sub(#"(?<!\w)@(\w+)"#, "at $1")                  // @handle
        map(#"(?<!\w)#(\d+)"#) { m in                    // #1137 -> "number eleven thirty seven"
            let d = m[1]
            guard d.count == 4, let hi = Int(d.prefix(2)), let lo = Int(d.suffix(2)), hi >= 10 else { return "number " + d }
            return "number " + twoDigits(hi) + " " + (lo == 0 ? "hundred" : lo < 10 ? "oh " + ones[lo] : twoDigits(lo))
        }
        sub(#"(?<!\w)#([A-Za-z]\w*)"#, "hashtag $1")     // #buildinpublic
        map(#"\b([A-Za-z][\w-]*)\.(ai|io|com|co|uk|net|org|app|dev|so|ng)\b"#) {
            $0[1] + " dot " + (["ai", "io", "uk", "ng"].contains($0[2]) ? $0[2].uppercased() : $0[2])
        }
        sub(#"(?<![\w/])\.env\b"#, "dot env")

        // Numbers that aren't plain amounts.
        sub(#"\s*(≈|~)\s*(?=[\d£$€₦])"#, " about ")
        sub(#"(?<![\w\d])-(?=[£$€₦]?\d)"#, "minus ")       // -£2,500, -5°C
        map(#"\+?\d[\d ]{8,}\d"#) { m in                  // phone numbers: digit by digit
            let digits = m[0].filter(\.isNumber).count
            guard digits >= 9 else { return m[0] }
            return m[0].split(separator: " ").map { group in
                group.map { $0 == "+" ? "plus" : digitWord($0) }.joined(separator: " ")
            }.joined(separator: ", ")
        }
        map(#"\b\d{7,}\b"#) { $0[0].map(digitWord).joined(separator: " ") }
        map(#"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#) { m in   // 15/11/2026 (UK order) -> the fifteenth of November 2026
            guard let d = Int(m[1]), let mo = Int(m[2]), (1...31).contains(d), (1...12).contains(mo) else { return m[0] }
            return "the " + ordinal(d) + " of " + months[mo - 1] + " " + m[3]
        }
        map(#"\b(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?(?=\s+\d)"#) { monthNames[$0[1]] ?? $0[0] }
        map(#"(?<=\d )(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\b\.?"#) { monthNames[$0[1]] ?? $0[0] }
        map(#"([£$€₦])\s?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?(?:\s?(k|K|m|M|bn|million|billion)\b)?"#) { money($0) }
        map(#"\bN(\d{1,3}(?:,\d{3})+)\b"#) { m in        // N250,000 = naira
            let n = Int(m[1].replacingOccurrences(of: ",", with: ""))!
            return numberWords(n) + " naira"
        }
        sub(#"\bv(\d+(?:\.\d+)+)\b"#, "version $1")
        map(#"\bversion (\d+(?:\.\d+)+)"#) { "version " + $0[1].replacingOccurrences(of: ".", with: " point ") }
        sub(#"(\d{4})\s*[–—-]\s*(\d{4})"#, "$1 to $2")   // 2008–2012
        sub(#"(?<![\d.,/:-])\b(\d{1,3}(?:\.\d+)?)\s?[–-]\s?(\d{1,3}(?:\.\d+)?)\b(?![\d/:-])"#, "$1 to $2")   // 2-3 hours

        // Units after a number.
        map(#"(?<=\d)\s?(GB|MB|TB|KB|GHz|ms|km|kg|cm|mm|mph|kph|km/h)(?![\w/])"#) {
            " " + ([
                "GB": "gigabytes", "MB": "megabytes", "TB": "terabytes", "KB": "kilobytes", "GHz": "gigahertz",
                "ms": "milliseconds", "km": "kilometres", "kg": "kilograms", "cm": "centimetres",
                "mm": "millimetres", "mph": "miles per hour", "kph": "kilometres per hour", "km/h": "kilometres per hour",
            ][$0[1]] ?? $0[1])
        }

        // Scores and ratios: "7:3" -> "7 to 3" (real times like 14:30 have two-digit minutes).
        sub(#"(?<![\d:])\b(\d{1,2}):(\d)\b(?![\d:])"#, "$1 to $2")

        // Symbols.
        sub(#"\s*(→|->|=>|⇒)\s*"#, " to ")
        sub(#"\s*(←|<-)\s*"#, " from ")
        sub(#"\s*≥\s*"#, " at least ")
        sub(#"\s*≤\s*"#, " at most ")
        sub(#"\s+=\s+"#, " equals ")
        sub(#"\s*&\s*"#, " and ")
        sub(#"\s*\|\s*"#, ", ")
        sub(#"(?<=\d)\s?[x×]\s?(?=\d)"#, " by ")       // 1920x1080

        // Roman numerals after a title word: "Chapter IV" -> "Chapter four",
        // "World War II" -> "World War two", "Louis XIV" -> "Louis the fourteenth".
        map(#"\b(Chapter|Part|Book|Volume|Vol\.?|Act|Phase|Section|Season|Episode|Article|Schedule|Level|Stage|War|Rocky|Fast)\s+([IVX]{1,6})\b"#) { m in
            guard let n = roman(m[2]) else { return m[0] }
            return m[1] + " " + numberWords(n)
        }
        map(#"\b(Louis|Henry|Charles|Elizabeth|George|Edward|William|James|Richard|John|Pope|Pius|Leo|Benedict|Gregory|Napoleon|Philip|Mary|Victoria|Peter|Alexander|Frederick|Ramses|Super Bowl)\s+([IVXL]{1,6})\b"#) { m in
            guard let n = roman(m[2]) else { return m[0] }
            return m[0].hasPrefix("Super Bowl") ? m[1] + " " + numberWords(n) : m[1] + " the " + ordinal(n)
        }

        sub(#"\b1/2 a\b"#, "half a")                         // "1/2 a cup" -> "half a cup"
        // Fractions: "1/2" -> "a half", "3/4" -> "three quarters". Leave 24/7 and dates alone.
        map(#"(?<![\d/])\b([1-9])/([2-9]|10)\b(?!/)"#) { m in
            let n = Int(m[1])!, d = Int(m[2])!
            if n == 1 { return ["", "", "a half", "a third", "a quarter", "a fifth", "a sixth", "a seventh", "an eighth", "a ninth", "a tenth"][d] }
            let names = ["", "", "halves", "thirds", "quarters", "fifths", "sixths", "sevenths", "eighths", "ninths", "tenths"]
            return n < d ? numberWords(n) + " " + names[d] : m[0]
        }

        // Shorthand.
        sub(#"\bSt\.(?=\s+[A-Z])"#, "Saint")
        sub(#"(?<=[A-Z][a-z]{1,20} )St\.?(?=[\s,.;:!?]|$)"#, "Street")
        sub(#"\bDr\.?(?=\s+[A-Z])"#, "Doctor")
        sub(#"\bMr\.(?=\s+([A-Z]|and\b|&))"#, "Mister")
        sub(#"\bMrs\.(?=\s+([A-Z]|and\b|&))"#, "Missus")
        sub(#"(?<=\d)x\b"#, " times")                     // 10x, 1.5x
        sub(#"\bQ([1-4])\b"#, "Q $1")
        sub(#"(?i)\bw/o\b"#, "without")
        sub(#"(?i)\bw/(?=\s)"#, "with")
        sub(#"(?i)\bi\.e\.,?"#, "that is,")
        sub(#"(?i)\be\.g\.,?"#, "for example,")
        sub(#"(?i)\bapprox\.?(?=\s)"#, "approximately")
        sub(#"(?i)\bvs\.?(?=\s)"#, "versus")
        sub(#"(?i)\betc\b"#, "etcetera")
        sub(#"\band/or\b"#, "and or")
        sub(#"(?<![\w/~.])([A-Z]{2,5})/([A-Z]{2,5})(?![\w/])"#, "$1, $2")         // UI/UX
        sub(#"(?<![\w/~.])([A-Za-z]{2,})/([A-Za-z]{2,})(?![\w/])"#, "$1 or $2")   // client/tenant

        // "read" is spelled the same for "reed" (now) and "red" (past); the voice guesses and
        // often guesses wrong (17 Nov). Decide from the words around it and spell it as it sounds.
        // Past: after have/had/was/been... ("have read", "was read aloud"), or before
        // yesterday/last/ago. Present: after to/will/can/do... ("to read", "can't read"), and at
        // the start of a sentence ("Read the rules"). Anything else is left to the voice.
        t = sayRead(t)

        // Words she says wrong; add more here.
        sub(#"(?i)\bn8n\b"#, "en eight en")
        sub(#"\bJSON\b"#, "Jason")
        sub(#"\bSaaS\b"#, "sass")
        sub(#"\bOK\b"#, "okay")

        // Cadence (Deji picked sample C, 16 Nov): a dash is a carrying-on pause "…",
        // colons and semicolons are a comma. Number ranges were turned into "to" above,
        // and hyphenated words (well-known) are left alone.
        sub(#"(?<!\d)\s*(—|–|--)\s*(?!\d)"#, "… ")
        sub(#"\s+-\s+"#, "… ")
        sub(#";(?=\s|$)"#, ",")
        sub(#"(?<!\d):(?=\s|$)"#, ",")
        sub(#"^(…\s*)+"#, "")
        sub(#"…\s*[,…]+"#, "…")

        // Brackets get the same carrying-on pause as a dash, before and after (17 Nov: commas
        // made her run straight through "(a screenshot helps)").
        t = bracketPauses(t)
        sub(#"([.!?])\s*…\s*"#, "$1 ")                      // "do it? (Pass or Fail)" -> "do it? Pass or Fail"
        sub(#"…\s*([.!?,;:])"#, "$1")                       // "(helps)." -> "helps."
        sub(#"…\s*…"#, "…")
        sub(#",\s*…"#, "…")
        sub(#",\s*,"#, ",")
        sub(#"([.!?…])\s*,"#, "$1")                        // "do it? (Pass or Fail)" -> "do it? Pass or Fail"
        sub(#",\s*([.!?…:;])"#, "$1")
        sub(#"\s+([.,!?;:])"#, "$1")
        sub(#"\s{2,}"#, " ")
        t = spellYears(t)
        t = sayCapitals(t)
        t = t.trimmingCharacters(in: .whitespaces)
        while let last = t.last, last == "," { t.removeLast() }
        return t
    }

    // A bracket becomes a "…" pause before and after, the dash pause Deji picked (cadence C).
    // Near the start of a sentence (fewer than 5 words before it) the piece before would be too
    // short to stand alone, so it becomes commas instead ("A robot, the AI agent, was asked").
    // At the end of a line there's no trailing pause.
    static func bracketPauses(_ text: String) -> String {
        var t = text
        while let r = t.range(of: #"\s*\(([^()]*)\)"#, options: .regularExpression) {
            let inner = t[r].trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
            let before = t[..<r.lowerBound]
            let sentenceStart = before.range(of: #"[.!?…]\s"#, options: [.regularExpression, .backwards])?.upperBound ?? before.startIndex
            let wordsBefore = before[sentenceStart...].split(separator: " ").count
            let atEnd = t[r.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
            let out: String
            if atEnd { out = (wordsBefore < 5 ? ", " : "… ") + inner + "." }
            else if wordsBefore < 5 { out = ", " + inner + ", " }
            else { out = "… " + inner + "… " }
            t.replaceSubrange(r, with: out)
        }
        return t
    }

    static func sayRead(_ text: String) -> String {
        var t = text
        func swap(_ pattern: String, _ sound: String) {
            t = replace(t, pattern) { m in
                let word = m[m.count - 1]
                let said = word.first!.isUppercase ? sound.prefix(1).uppercased() + sound.dropFirst() : sound
                return String(m[0].dropLast(word.count)) + said
            }
        }
        let past = #"\b(?i:have|has|had|having|'ve|'d|been|was|were|is|are|be|being|got|get|gets|getting|gotten|already|once|never|ever|recently|just)(?:\s+(?i:not|never|already|just|recently|once|all|it|this|that|them|him|her|you|me|us|those|these))*\s+(read)\b"#
        let present = #"\b(?i:to|will|'ll|can|could|would|should|must|may|might|shall|do|does|did|don't|doesn't|didn't|cannot|can't|won't|wouldn't|couldn't|shouldn't|let's|please|i'll|you'll|we'll|they'll)\s+(?:(?i:not|also|just|always|never|first|then|still|really|actually)\s+)?(read)\b"#
        // Present runs first so "could just read" stays reed; past would take "just read" (18 Nov).
        swap(present, "reed")
        swap(past, "red")
        swap(#"\b(read)(?=\s+(?:it\s+|this\s+|that\s+|them\s+)?(?i:yesterday|last|ago|earlier|before|once|years|months|weeks|days)\b)"#, "red")
        swap(#"\b(read)(?=\s+(?:(?i:it|this|that|them|books|a\s+lot)\s+)?(?i:every|each|daily|often|always|usually|sometimes|most)\b)"#, "reed")
        swap(#"\b(Read)(?=\s+Aloud\b)"#, "reed")
        swap(#"^(Read)\b"#, "reed")
        swap(#"(?<=[.!?:]\s)(Read)\b"#, "reed")
        return t
    }

    // Run a regex and build each replacement from its groups (group 0 = whole match).
    static func replace(_ text: String, _ pattern: String, _ f: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result = (result as NSString).replacingCharacters(in: m.range, with: f(groups))
        }
        return result
    }

    static let ones = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                       "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                       "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    static func twoDigits(_ n: Int) -> String {
        n < 20 ? ones[n] : tens[n / 10] + (n % 10 == 0 ? "" : " " + ones[n % 10])
    }
    static func digitWord(_ c: Character) -> String {
        guard let d = Int(String(c)) else { return String(c) }
        return d == 0 ? "zero" : ones[d]
    }

    // "XIV" -> 14. Only well-formed numerals up to 89.
    static func roman(_ s: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50]
        var total = 0, prev = 0
        for c in s.reversed() {
            guard let v = values[c] else { return nil }
            total += v < prev ? -v : v
            prev = max(prev, v)
        }
        let canonical = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"]
        let tensR = ["", "X", "XX", "XXX", "XL", "L", "LX", "LXX", "LXXX"]
        guard total > 0, total < 90, tensR[total / 10] + canonical[total % 10] == s else { return nil }
        return total
    }

    static let months = ["January", "February", "March", "April", "May", "June", "July",
                         "August", "September", "October", "November", "December"]
    static let monthNames: [String: String] = [
        "Jan": "January", "Feb": "February", "Mar": "March", "Apr": "April", "Jun": "June",
        "Jul": "July", "Aug": "August", "Sep": "September", "Sept": "September",
        "Oct": "October", "Nov": "November", "Dec": "December",
    ]

    // £1,200 -> "one thousand two hundred pounds"; £15k -> "fifteen thousand pounds";
    // £1.2m -> "one point two million pounds"; £3.50 -> "three pounds fifty".
    static func money(_ m: [String]) -> String {
        let (symbol, whole, cents, scale) = (m[1], m[2].replacingOccurrences(of: ",", with: ""), m[3], m[4].lowercased())
        guard let n = Int(whole) else { return m[0] }
        let plural = ["£": "pounds", "$": "dollars", "€": "euros", "₦": "naira"][symbol] ?? ""
        let single = ["£": "pound", "$": "dollar", "€": "euro", "₦": "naira"][symbol] ?? ""
        let scaleWord = ["k": "thousand", "m": "million", "million": "million", "bn": "billion", "billion": "billion"][scale]
        if let scaleWord {
            let amount = cents.isEmpty ? numberWords(n) : numberWords(n) + " point " + cents.map(digitWord).joined(separator: " ")
            return amount + " " + scaleWord + " " + plural
        }
        var out = numberWords(n) + " " + (n == 1 ? single : plural)
        if let c = Int(cents.count == 1 ? cents + "0" : cents), c > 0 { out += " " + numberWords(c) }
        return out
    }

    static func numberWords(_ n: Int) -> String {
        if n == 0 { return "zero" }
        if n < 100 { return twoDigits(n) }
        if n < 1000 {
            let r = n % 100
            return ones[n / 100] + " hundred" + (r == 0 ? "" : " and " + twoDigits(r))
        }
        for (div, name) in [(1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand")] where n >= div {
            let r = n % div
            return numberWords(n / div) + " " + name + (r == 0 ? "" : (r < 100 ? " and " : " ") + numberWords(r))
        }
        return String(n)
    }

    static func ordinal(_ n: Int) -> String {
        let special = [1: "first", 2: "second", 3: "third", 5: "fifth", 8: "eighth", 9: "ninth", 12: "twelfth",
                       20: "twentieth", 30: "thirtieth"]
        if let s = special[n] { return s }
        if n < 20 { return ones[n] + "th" }
        let unit = n % 10
        return unit == 0 ? tens[n / 10] + "th" : tens[n / 10] + " " + ordinal(unit)
    }

    // Say years the way people do: 2008 -> "two thousand eight", 2011 -> "twenty eleven".
    static func spellYears(_ text: String) -> String {
        replace(text, #"(?<![\d£$€.,:])\b(19|20)(\d\d)\b(?![\d.,:]\d|\s?%)"#) { m in
            let century = m[1], rest = Int(m[2])!
            if century == "20" && rest < 10 { return rest == 0 ? "two thousand" : "two thousand " + ones[rest] }
            let first = century == "19" ? "nineteen" : "twenty"
            return first + " " + (rest == 0 ? "hundred" : rest < 10 ? "oh " + ones[rest] : twoDigits(rest))
        }
    }

    // Capitals: real words shouted in caps (NEVER, DONE, IMPORTANT) are said as words;
    // abbreviations (VPS, MCU, API) are spelled letter by letter. Real words are checked
    // against the Mac's English word list. Two-letter ones are always spelled (AI, UK, US).
    static let englishWords: Set<String> = {
        guard let all = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(all.split(separator: "\n").map { $0.lowercased() })
    }()
    static let sayAsWord: Set<String> = ["NASA", "UEFA", "FIFA", "NATO", "OPEC", "ASAP", "SIM", "PIN", "GIF", "LOL", "COVID", "QWERTY", "IDEO", "UNESCO", "UNICEF", "NAFTA", "SARS", "AIDS", "LASER", "RADAR", "SCUBA"]
    static func sayCapitals(_ text: String) -> String {
        // A heading in capitals ("HOW CHINA ESCAPED THE POVERTY TRAP"): three or more capital
        // words in a row are ordinary words, not abbreviations. Read each as a word; only
        // short ones that aren't words (UK, AI, USA) are still spelled.
        let headed = replace(text, #"\b[A-Z][A-Z'’]*(?:[\s,:;&-]+[A-Z][A-Z'’]*){2,}\b"#) { m in
            replace(m[0], #"[A-Z][A-Z'’]*"#) { w in
                let word = w[0]
                if sayAsWord.contains(word) { return word.prefix(1) + word.dropFirst().lowercased() }
                if smallWords.contains(word) || isEnglish(word) { return word.lowercased() }
                let hasVowel = word.rangeOfCharacter(from: CharacterSet(charactersIn: "AEIOUY")) != nil
                if word.count >= 4 && hasVowel { return word.prefix(1) + word.dropFirst().lowercased() } // a name
                return word.count == 1 ? word : word.map(String.init).joined(separator: " ")
            }
        }
        return replace(headed, #"\b[A-Z]{2,}\b"#) { m in
            let word = m[0]
            if sayAsWord.contains(word) { return word.prefix(1) + word.dropFirst().lowercased() }
            if word.count >= 3, isEnglish(word) { return word.lowercased() }
            if word.count >= 7 { return word.lowercased() }     // too long to be an abbreviation
            return word.map(String.init).joined(separator: " ")
        }
    }

    static let smallWords: Set<String> = ["OF", "IN", "TO", "AT", "AN", "IS", "IT", "ON", "BY", "MY", "WE",
                                          "HE", "ME", "NO", "SO", "UP", "OR", "AS", "BE", "DO", "GO", "IF", "US", "A", "I"]

    /// Is this an English word? The Mac's word list has only base forms ("escape", not
    /// "escaped"), so also try taking common endings off.
    static func isEnglish(_ word: String) -> Bool {
        let w = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if englishWords.contains(w) { return true }
        let base = w.hasSuffix("'s") ? String(w.dropLast(2)) : w
        if englishWords.contains(base) { return true }
        let endings: [(String, [String])] = [
            ("ies", ["y"]), ("ied", ["y"]), ("ing", ["", "e"]), ("ed", ["", "e"]), ("es", ["", "e"]),
            ("s", [""]), ("ly", [""]), ("er", ["", "e"]), ("ers", ["", "e"]), ("est", ["", "e"]),
            ("ment", [""]), ("ness", [""]), ("ation", ["e", ""]), ("ity", ["", "e"]), ("al", [""]),
        ]
        for (end, adds) in endings where base.hasSuffix(end) && base.count > end.count + 2 {
            var stem = String(base.dropLast(end.count))
            for add in adds where englishWords.contains(stem + add) { return true }
            // doubled consonant: "trapped" -> "trap", "running" -> "run"
            if let last = stem.last, stem.dropLast().last == last {
                stem.removeLast()
                if englishWords.contains(stem) { return true }
            }
        }
        return false
    }

    // Very short pieces (list items like "Thor, 2011.") make the voice fumble: give it a
    // few at a time so it has context, up to about 24 words per group.
    static func groupShort(_ pieces: [String]) -> [String] {
        var out: [String] = []
        for p in pieces {
            let words = p.split(separator: " ").count
            // A piece ending in "…" (a dash or bracket pause) keeps its own breath, so the pause
            // is really heard (17 Nov: glued into one breath, she skated over it).
            // Only when both sides are long enough: very short pieces make her stumble ("a a
            // robot") and leave choppy gaps, so a short aside stays in one breath.
            let pauseBreak = (out.last?.hasSuffix("…") ?? false)
                && (out.last?.split(separator: " ").count ?? 0) >= 5 && words >= 3
            if let last = out.last, !pauseBreak, words <= 10,
               last.split(separator: " ").count + words <= 24,
               last.split(separator: " ").count <= 20 {
                out[out.count - 1] = last + " " + p
            } else {
                out.append(p)
            }
        }
        return out
    }

    // "- item", "• item", "* item", "1. item", "2) item" -> "item"
    static func stripBullet(_ line: String) -> String {
        line.replacingOccurrences(of: #"^([-•*‣◦▪]|\d{1,3}[.)])\s+"#, with: "", options: .regularExpression)
    }

    // Make sure a line ends like a sentence, so it never merges with the next line.
    static func withFullStop(_ line: String) -> String {
        guard let last = line.last else { return line }
        if ".!?…".contains(last) { return line }
        if "\"')]”’".contains(last) { return line }            // ends in a quote or bracket: leave it
        let core = ",;:—–-".contains(last) ? String(line.dropLast()) : line
        // Judge only the unfinished end: "Did it work? Pass or Fail" ends "Pass or Fail".
        var tail = core
        if let end = core.range(of: #"[.!?…]["”’')\]]*\s"#, options: [.regularExpression, .backwards]) {
            tail = String(core[end.upperBound...])
        }
        return core + (looksLikeQuestion(tail) ? "?" : ".")
    }

    // "Who owns the photos" -> read as a question, so her voice rises.
    static let questionStarts: Set<String> = [
        "who", "what", "when", "where", "why", "how", "which", "do", "does", "did", "is", "are",
        "was", "were", "can", "could", "should", "would", "will", "shall", "have", "has", "may",
    ]
    // "What is a rubric" is a question; "What this exercise is" and "What you hand in" are
    // headings. After what/who/how..., the next word has to be a verb like is/do/can.
    static let whWords: Set<String> = ["who", "what", "when", "where", "why", "how", "which"]
    static let askVerbs: Set<String> = [
        "is", "are", "was", "were", "do", "does", "did", "can", "could", "should", "would", "will",
        "shall", "have", "has", "had", "may", "might", "must", "isn't", "aren't", "don't", "doesn't",
        "didn't", "can't", "won't", "makes", "happens", "happened", "goes", "went", "comes", "about",
        "if", "else", "much", "many", "long", "often", "far",
    ]
    static func looksLikeQuestion(_ line: String) -> Bool {
        let words = line.split(separator: " ").map { $0.lowercased().replacingOccurrences(of: "’", with: "'") }
        guard let first = words.first else { return false }
        if ["what's", "who's", "how's", "where's", "when's", "why's"].contains(first) { return true }
        guard questionStarts.contains(first) else { return false }
        guard whWords.contains(first) else { return true }
        guard words.count > 1 else { return true }
        let second = words[1].trimmingCharacters(in: .punctuationCharacters)
        if first == "who", second.hasSuffix("s") { return true }          // "Who owns the photos"
        return askVerbs.contains(second) || second.hasSuffix("'s") || second.hasSuffix("'re")
    }

    // Split a line into sentences after . ! ? or … followed by a space.
    static func splitSentences(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(line)
        for (i, c) in chars.enumerated() {
            current.append(c)
            if ".!?…".contains(c), i + 1 < chars.count, chars[i + 1] == " ",
               !(c == "." && endsWithAbbreviation(current)) {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    // "Vol." "Dr." "e.g." are not the end of a sentence.
    static let abbreviations: Set<String> = [
        "vol", "dr", "mr", "mrs", "ms", "st", "no", "vs", "etc", "e.g", "i.e", "approx", "dept",
        "fig", "inc", "ltd", "co", "jr", "sr", "prof", "mt", "ft", "est", "ref", "p", "pp",
    ]
    static func endsWithAbbreviation(_ text: String) -> Bool {
        guard let last = text.split(separator: " ").last else { return false }
        let word = last.dropLast().lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(\"'"))
        return abbreviations.contains(word)
    }

    // Too long? Split at the best point and repeat on each half. Returns the pieces.
    static func smooth(_ sentence: String) -> [String] {
        var words = sentence.split(separator: " ").map(String.init)
        guard words.count > maxWords else { return [sentence] }
        let cut = bestCut(words) ?? wordCut(words)

        // Dash on its own ("this — that"): drop it, put … on the word before.
        if cut + 1 < words.count, ["—", "–", "-"].contains(words[cut + 1]) {
            words.remove(at: cut + 1)
        }
        var w = words[cut]
        while let last = w.last, ",;:—–-".contains(last) { w.removeLast() }
        words[cut] = w + "…"

        let first = words[...cut].joined(separator: " ")
        let second = words[(cut + 1)...].joined(separator: " ")
        return smooth(first) + smooth(second)
    }

    // Score every punctuation split point; the best is a strong break near the middle.
    static func bestCut(_ words: [String]) -> Int? {
        let n = words.count
        var best: (index: Int, score: Double)?
        for i in (minPiece - 1)..<(n - minPiece) {
            let word = words[i]
            let next = words[i + 1].lowercased().trimmingCharacters(in: .punctuationCharacters)
            var strength: Double
            if word.hasSuffix(";") || word.hasSuffix(":") || word.hasSuffix("—") || word.hasSuffix("–")
                || ["—", "–", "-"].contains(words[i + 1]) {
                strength = 3            // a strong break a writer chose
            } else if word.hasSuffix(",") && subjectWords.contains(next) {
                strength = 2.5          // ", we will ..." usually starts the main clause
            } else if word.hasSuffix(",") && joinWords.contains(next) {
                // ", and ..." starts a new clause, unless it ends a list ("A, B, and C"):
                // another comma in the few words before means we are inside a list.
                let recent = words[max(0, i - 5)..<i]
                strength = recent.contains { $0.hasSuffix(",") } ? 0.8 : 2
            } else if word.hasSuffix(",") {
                strength = 1            // plain comma, might be inside a list
            } else {
                continue
            }
            let distanceFromMiddle = abs(Double(i + 1) - Double(n) / 2) / Double(n)
            let score = strength - 4 * distanceFromMiddle
            if best == nil || score > best!.score { best = (i, score) }
        }
        return best?.index
    }

    // No punctuation to split at: cut before a joining word near the middle if there
    // is one ("... moving out | and the inbox ..."), else right at the middle.
    static func wordCut(_ words: [String]) -> Int {
        let mid = words.count / 2
        for offset in 0...(words.count / 4) {
            for i in [mid + offset, mid - offset] where i > 0 && i < words.count - 1 {
                if joinWords.contains(words[i + 1].lowercased()) { return i }
            }
        }
        return mid - 1
    }
}
