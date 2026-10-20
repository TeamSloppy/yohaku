import Foundation

extension CourseCatalog {
    static func katakana(_ glyphs: [KanaGlyph]) throws -> [CourseModule] {
        let words = [
            [], ["ケーキ|けーき|Торт", "ココア|ここあ|Какао"],
            ["アイス|あいす|Мороженое", "ソース|そーす|Соус", "スキー|すきー|Лыжи"],
            ["タクシー|たくしー|Такси", "テスト|てすと|Тест"],
            ["テニス|てにす|Теннис", "ネクタイ|ねくたい|Галстук", "ノート|のーと|Тетрадь"],
            ["ナイフ|ないふ|Нож", "コーヒー|こーひー|Кофе"],
            ["ハム|はむ|Ветчина", "メモ|めも|Заметка", "マスク|ますく|Маска"],
            ["タイヤ|たいや|Шина", "ユニーク|ゆにーく|Уникальный"],
            ["カメラ|かめら|Камера", "ホテル|ほてる|Отель"],
            ["ワイン|わいん|Вино", "レモン|れもん|Лимон"]
        ]
        var modules = (0..<10).map { row in
            let tuples = words[row].map { $0.split(separator: "|").map(String.init) }.map { ($0[0],$0[1],$0[2]) }
            return kanaModule(alphabet: .katakana, row: row, glyphs: glyphs, words: tuples)
        }
        guard let long = glyphs.first(where: { $0.symbol == "ー" }) else { throw CocoaError(.fileReadCorruptFile) }
        modules[0].items.append(.init(id: "katakana.long", japanese: "ー", reading: "long vowel", meaning: "Долгий гласный", glyph: long))
        modules[0].explanation += " Знак ー удлиняет предыдущий гласный. В проверке его название — long vowel."
        for (id, signs, examples) in [
            ("g","ガギグゲゴ",["ギター|ぎたー|Гитара", "ガス|がす|Газ"]),
            ("z","ザジズゼゾ",["チーズ|ちーず|Сыр", "ジーンズ|じーんず|Джинсы"]),
            ("d","ダヂヅデド",["ドア|どあ|Дверь", "カード|かーど|Карта"]),
            ("b","バビブベボ",["バナナ|ばなな|Банан", "ビル|びる|Здание"]),
            ("p","パピプペポ",["パン|ぱん|Хлеб", "ピアノ|ぴあの|Пианино"])
        ] {
            modules.append(try symbolModule(id: "katakana.voiced." + id, title: signs, stage: "Катакана", symbols: signs.map(String.init),
                explanation: "Озвончение работает как в хирагане: ゛ меняет согласный, ゜ даёт p. Различайте похожие знаки по направлению штрихов.", words: examples, glyphs: glyphs))
        }
        modules.append(try symbolModule(id: "katakana.small", title: "Маленькие ャ ュ ョ ッ", stage: "Катакана", symbols: ["ャ","ュ","ョ","ッ"],
            explanation: "Маленькая кана образует сочетание, маленькая ッ удваивает следующую согласную. Названия для проверки отдельных знаков: small ya / small yu / small yo / small tsu.", words: ["ベッド|べっど|Кровать", "カップ|かっぷ|Чашка"], glyphs: glyphs))
        for (id, signs, examples) in [
            ("ky",["キャ","キュ","キョ"],["キャリア|きゃりあ|Карьера", "キューブ|きゅーぶ|Куб"]),
            ("sh",["シャ","シュ","ショ"],["シャツ|しゃつ|Рубашка", "ショー|しょー|Шоу"]),
            ("ch",["チャ","チュ","チョ"],["チャンス|ちゃんす|Шанс", "チョコ|ちょこ|Шоколад"]),
            ("ny",["ニャ","ニュ","ニョ"],["ニュース|にゅーす|Новости", "ニュアンス|にゅあんす|Нюанс"]),
            ("hy",["ヒャ","ヒュ","ヒョ"],["ヒューマン|ひゅーまん|Человеческий"]),
            ("my",["ミャ","ミュ","ミョ"],["ミュージック|みゅーじっく|Музыка"]),
            ("ry",["リャ","リュ","リョ"],["リュック|りゅっく|Рюкзак"]),
            ("gy",["ギャ","ギュ","ギョ"],["ギャラリー|ぎゃらりー|Галерея", "ギョーザ|ぎょーざ|Гёдза"]),
            ("j",["ジャ","ジュ","ジョ"],["ジャム|じゃむ|Джем", "ジュース|じゅーす|Сок"]),
            ("by",["ビャ","ビュ","ビョ"],["インタビュー|いんたびゅー|Интервью"]),
            ("py",["ピャ","ピュ","ピョ"],["コンピューター|こんぴゅーたー|Компьютер"])
        ] {
            modules.append(try symbolModule(id: "katakana.combination." + id, title: signs.joined(separator: " "), stage: "Катакана", symbols: signs,
                explanation: "Большой знак и маленькая кана передают один слог. Сохраняйте маленький размер второго знака и долготу в словах.", words: examples, glyphs: glyphs))
        }
        modules.append(try symbolModule(id: "katakana.foreign.small", title: "Маленькие гласные и ヴ", stage: "Катакана", symbols: ["ァ","ィ","ゥ","ェ","ォ","ヴ"],
            explanation: "Маленькие гласные нужны для звуков заимствованных слов. Их названия в проверке: small a / small i / small u / small e / small o. ヴ читается vu.", words: [], glyphs: glyphs))
        for (id, signs, examples) in [
            ("f",["ファ","フィ","フェ","フォ"],["カフェ|かふぇ|Кафе", "フィルム|ふぃるむ|Плёнка", "フォーク|ふぉーく|Вилка"]),
            ("w",["ウィ","ウェ","ウォ"],["ウェブ|うぇぶ|Веб", "ウィーク|うぃーく|Неделя"]),
            ("tdi",["ティ","ディ"],["ティー|てぃー|Чай", "ディスク|でぃすく|Диск"]),
            ("tdu",["トゥ","ドゥ"],[]),
            ("she",["シェ","ジェ","チェ"],["シェフ|しぇふ|Шеф-повар", "ジェット|じぇっと|Реактивная струя", "チェス|ちぇす|Шахматы"]),
            ("v",["ヴァ","ヴィ","ヴェ","ヴォ"],["ヴァイオリン|ゔぁいおりん|Скрипка"])
        ] {
            modules.append(try symbolModule(id: "katakana.foreign." + id, title: signs.joined(separator: " "), stage: "Катакана", symbols: signs,
                explanation: "Сочетания с маленькими гласными передают иностранные звуки. Большой знак пишется первым, маленький — вторым.", words: examples, glyphs: glyphs))
        }
        return modules
    }
}
