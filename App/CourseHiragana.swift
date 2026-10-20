import Foundation

enum CourseTemplates {
    private struct File: Decodable { var revision: String; var glyphs: [KanaGlyph] }
    static func load() throws -> [KanaGlyph] {
        guard let url = Bundle.main.url(forResource: "CourseTemplates", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard file.revision == "70a0b7ae0c18ceb5cb358274b029cce0234a43bc",
              Set(file.glyphs.map(\.symbol)).count == file.glyphs.count,
              file.glyphs.allSatisfy({ !$0.strokes.isEmpty && $0.strokes.allSatisfy { stroke in
                  stroke.count >= 2 && stroke.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }
              } }) else { throw CocoaError(.fileReadCorruptFile) }
        return file.glyphs
    }
}

extension CourseCatalog {
    static func vocabulary(_ specs: [String]) -> [CourseItem] {
        specs.map { spec in
            let fields = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            precondition(fields.count == 3, "Course vocabulary must contain word|reading|meaning")
            return .init(id: "word:" + fields[0], japanese: fields[0], reading: fields[1], meaning: fields[2])
        }
    }
    static func symbolModule(id: String, title: String, stage: String, symbols: [String], explanation: String,
                             words: [String], glyphs: [KanaGlyph]) throws -> CourseModule {
        let items = try symbols.map { symbol -> CourseItem in
            guard let glyph = glyphs.first(where: { $0.symbol == symbol }) else { throw CocoaError(.fileReadCorruptFile) }
            let hint = ["ぢ", "づ", "ヂ", "ヅ"].contains(symbol) ? "Озвончённый знак ряда t" : ""
            return .init(id: id + "." + symbol, japanese: symbol, reading: glyph.reading.replacingOccurrences(of: "-", with: " "),
                         meaning: "Звучание: " + glyph.reading, glyph: glyph, writingHint: hint)
        }
        return .init(id: id, title: title, stage: stage, explanation: explanation, items: items + vocabulary(words))
    }
    static func hiragana(_ glyphs: [KanaGlyph]) throws -> [CourseModule] {
        let words = [
            ["あい|あい|Любовь", "いい|いい|Хороший", "いえ|いえ|Дом"],
            ["かお|かお|Лицо", "かき|かき|Хурма", "こえ|こえ|Голос"],
            ["すし|すし|Суши", "あさ|あさ|Утро", "そこ|そこ|Там"],
            ["つき|つき|Луна", "くつ|くつ|Обувь", "した|した|Низ"],
            ["いぬ|いぬ|Собака", "ねこ|ねこ|Кошка", "なつ|なつ|Лето"],
            ["はな|はな|Цветок", "ひと|ひと|Человек", "ふね|ふね|Корабль"],
            ["みみ|みみ|Уши", "うみ|うみ|Море", "まえ|まえ|Перед"],
            ["ゆき|ゆき|Снег", "やま|やま|Гора", "ゆめ|ゆめ|Сон"],
            ["よる|よる|Ночь", "そら|そら|Небо", "くるま|くるま|Автомобиль"],
            ["ほん|ほん|Книга", "かわ|かわ|Река", "わたし|わたし|Я"]
        ]
        var modules = (0..<10).map { row in
            let tuples = words[row].map { $0.split(separator: "|").map(String.init) }.map { ($0[0],$0[1],$0[2]) }
            return kanaModule(alphabet: .hiragana, row: row, glyphs: glyphs, words: tuples)
        }
        for (id, signs, examples) in [
            ("g", "がぎぐげご", ["かぎ|かぎ|Ключ", "かがみ|かがみ|Зеркало"]),
            ("z", "ざじずぜぞ", ["みず|みず|Вода", "かぜ|かぜ|Ветер"]),
            ("d", "だぢづでど", ["でんわ|でんわ|Телефон", "はなぢ|はなぢ|Носовое кровотечение", "つづく|つづく|Продолжаться"]),
            ("b", "ばびぶべぼ", ["かばん|かばん|Сумка", "ぶた|ぶた|Свинья"]),
            ("p", "ぱぴぷぺぽ", ["ぴかぴか|ぴかぴか|Сверкающий", "ぽかぽか|ぽかぽか|Приятно тёплый"])
        ] {
            modules.append(try symbolModule(id: "hiragana.voiced." + id, title: String(signs), stage: "Хирагана",
                symbols: signs.map(String.init), explanation: "Две черты ゛ меняют согласный; кружок ゜ превращает h в p. じ и ぢ читаются ji, ず и づ — zu; их написание запоминайте в словах.", words: examples, glyphs: glyphs))
        }
        modules.append(try symbolModule(id: "hiragana.small", title: "Маленькие ゃ ゅ ょ っ", stage: "Хирагана",
            symbols: ["ゃ", "ゅ", "ょ", "っ"], explanation: "Маленькие ゃ ゅ ょ соединяются с предыдущим знаком. Маленькая っ обозначает паузу перед удвоенной согласной: きって (kitte). В ответе к отдельному маленькому знаку используйте small ya / small yu / small yo / small tsu.",
            words: ["きって|きって|Почтовая марка", "がっこう|がっこう|Школа"], glyphs: glyphs))
        for (id, signs, examples) in [
            ("ky", ["きゃ","きゅ","きょ"], ["きゃく|きゃく|Гость", "きょう|きょう|Сегодня"]),
            ("sh", ["しゃ","しゅ","しょ"], ["しゃしん|しゃしん|Фотография", "しゅみ|しゅみ|Хобби"]),
            ("ch", ["ちゃ","ちゅ","ちょ"], ["おちゃ|おちゃ|Чай", "ちょっと|ちょっと|Немного"]),
            ("ny", ["にゃ","にゅ","にょ"], ["にゅうがく|にゅうがく|Поступление в учебное заведение"]),
            ("hy", ["ひゃ","ひゅ","ひょ"], ["ひゃく|ひゃく|Сто", "ひょう|ひょう|Таблица"]),
            ("my", ["みゃ","みゅ","みょ"], ["みゃく|みゃく|Пульс", "みょうじ|みょうじ|Фамилия"]),
            ("ry", ["りゃ","りゅ","りょ"], ["りょうり|りょうり|Готовка", "りょこう|りょこう|Поездка"]),
            ("gy", ["ぎゃ","ぎゅ","ぎょ"], ["ぎゃく|ぎゃく|Обратный", "ぎゅうにゅう|ぎゅうにゅう|Молоко"]),
            ("j", ["じゃ","じゅ","じょ"], ["じゃま|じゃま|Помеха", "じゅう|じゅう|Десять"]),
            ("by", ["びゃ","びゅ","びょ"], ["びょういん|びょういん|Больница"]),
            ("py", ["ぴゃ","ぴゅ","ぴょ"], ["ぴょんぴょん|ぴょんぴょん|Подпрыгивая"])
        ] {
            modules.append(try symbolModule(id: "hiragana.combination." + id, title: signs.joined(separator: " "), stage: "Хирагана",
                symbols: signs, explanation: "Большой знак и маленькая кана образуют один слог: не вставляйте между ними дополнительный гласный. В прописи сначала пишется большой знак, затем маленький.", words: examples, glyphs: glyphs))
        }
        modules.append(.init(id: "hiragana.long", title: "Долгие гласные", stage: "Хирагана",
            explanation: "Долгота меняет слово. В おばあさん звук a длинный; в おじいさん длинный i. Сочетания おう и えい часто произносятся как долгие o и e. Сохраняйте написание слова при вводе чтения.",
            items: vocabulary(["おばあさん|おばあさん|Бабушка", "おじいさん|おじいさん|Дедушка", "おねえさん|おねえさん|Старшая сестра", "せんせい|せんせい|Учитель"])))
        return modules
    }
}
