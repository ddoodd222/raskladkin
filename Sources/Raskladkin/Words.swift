import AppKit

enum Script { case latin, cyrillic, none }
enum Verdict { case keep, convert, unknown, neutral }

func isCyrillic(_ c: Character) -> Bool {
    guard let v = c.unicodeScalars.first?.value else { return false }
    return (0x0400...0x052F).contains(v)
}
func isLatin(_ c: Character) -> Bool { c.isASCII && c.isLetter }

func script(of s: String) -> Script {
    var cyr = 0, lat = 0
    for c in s {
        if isCyrillic(c) { cyr += 1 } else if isLatin(c) { lat += 1 }
    }
    if cyr == 0 && lat == 0 { return .none }
    return cyr >= lat ? .cyrillic : .latin
}

func direction(for s: Script) -> Direction? {
    switch s {
    case .latin: return .enToRu
    case .cyrillic: return .ruToEn
    case .none: return nil
    }
}

func lang(for s: Script) -> String? {
    switch s {
    case .latin: return "en"
    case .cyrillic: return "ru"
    case .none: return nil
    }
}

/// Решает, слово набрано в правильной раскладке или нет, через словари macOS.
final class Speller {
    private let checker = NSSpellChecker.shared
    let layouts: LayoutPair

    init(layouts: LayoutPair) {
        self.layouts = layouts
        _ = isWord("тест", lang: "ru") // прогрев словаря
    }

    func isWord(_ w: String, lang: String) -> Bool {
        guard !w.isEmpty else { return false }
        let r = checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }

    /// Слово без пунктуации по краям. Знак считается пунктуацией, только если он
    /// не буква и в этой раскладке, и в противоположной (иначе `\` — это ё, а `;` — ж).
    func core(_ token: String, _ dir: Direction) -> String {
        func isPunct(_ c: Character) -> Bool {
            !c.isLetter && !(layouts.convert(String(c), dir).first?.isLetter ?? false)
        }
        let trimmed = token.drop(while: isPunct)
        return String(String(trimmed.reversed()).drop(while: isPunct).reversed())
    }

    func verdict(_ token: String) -> Verdict {
        let sc = script(of: token)
        guard let dir = direction(for: sc) else { return .neutral }
        let core = self.core(token, dir)
        guard core.count >= 2 else { return .neutral }
        let converted = layouts.convert(token, dir)
        let backDir: Direction = dir == .enToRu ? .ruToEn : .enToRu
        let convCore = self.core(converted, backDir)
        let (langOrig, langConv) = dir == .enToRu ? ("en", "ru") : ("ru", "en")
        // Слово считается верным, только если оно целиком из букв своей раскладки.
        // Проверяем в нижнем регистре: иначе «Xnj» словарь принимает как имя собственное.
        let validOrig = core.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" } && isWord(core.lowercased(), lang: langOrig)
        let validConv = script(of: convCore) != sc && isWord(convCore.lowercased(), lang: langConv)
        switch (validOrig, validConv) {
        case (true, false):
            // Короткие английские «слова» (to, in, ok) слишком часто попадаются при наборе
            // русского в латинице, поэтому они не подтверждают раскладку, а просто не считаются.
            return core.count <= 3 && dir == .enToRu ? .unknown : .keep
        case (true, true):
            // pf/xnj/tot: словарь знает и английское, и русское слово. Короткое латинское слово,
            // которое в русской раскладке — обычное русское, почти всегда набрано не в той раскладке.
            return core.count <= 3 && dir == .enToRu ? .convert : .keep
        case (false, true): return .convert
        default: return .unknown
        }
    }

    /// Чинит произвольный текст пословно. Возвращает (новый текст, изменилось ли что-то).
    func fix(_ text: String) -> (String, Bool) {
        var tokens: [(text: String, isWord: Bool)] = []
        var cur = ""
        var curIsWord = false
        for c in text {
            let w = !c.isWhitespace
            if cur.isEmpty || w == curIsWord {
                cur.append(c)
                curIsWord = w
            } else {
                tokens.append((cur, curIsWord))
                cur = String(c)
                curIsWord = w
            }
        }
        if !cur.isEmpty { tokens.append((cur, curIsWord)) }

        let verdicts = tokens.map { $0.isWord ? verdict($0.text) : Verdict.neutral }
        let convertCount = verdicts.filter { $0 == .convert }.count
        let keepCount = verdicts.filter { $0 == .keep }.count
        let decided = convertCount + keepCount > 0
        let convertUndecided = !decided || convertCount >= keepCount

        var votes: [Direction: Int] = [:]
        for (i, t) in tokens.enumerated() where t.isWord && (verdicts[i] == .convert || !decided) {
            if let d = direction(for: script(of: t.text)) { votes[d, default: 0] += 1 }
        }
        let majority = votes.max { $0.value < $1.value }?.key

        var out = ""
        var changed = false
        for (i, t) in tokens.enumerated() {
            guard t.isWord else { out += t.text; continue }
            let v = verdicts[i]
            let doConvert = v == .convert || (v != .keep && convertUndecided)
            if doConvert, let d = direction(for: script(of: t.text)) ?? majority {
                let c = layouts.convert(t.text, d)
                if c != t.text { changed = true }
                out += c
            } else {
                out += t.text
            }
        }
        return (out, changed)
    }
}
