import Foundation

extension CourseCatalog {
    static func kanjiItems(_ specs: [String], id: String, glyphs: [KanaGlyph]) throws -> [CourseItem] {
        try specs.map { spec in
            let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let glyph = glyphs.first(where: { $0.symbol == parts[0] }) else { throw CocoaError(.fileReadCorruptFile) }
            let readings = parts[1].split(separator: "/").map(String.init)
            return .init(id: id + "." + parts[0], japanese: parts[0], reading: readings[0], meaning: parts[2], glyph: glyph,
                         writingHint: parts[2], readingAlternatives: Array(readings.dropFirst()))
        }
    }
    static func firstKanji(_ glyphs: [KanaGlyph]) throws -> CourseModule {
        .init(id: "kanji.nature", title: "День, луна и природа", stage: "Кандзи",
            explanation: "Кандзи передают значение и имеют несколько чтений. Начните с существительных: 日 — день/солнце (ひ), 月 — луна (つき), 火 — огонь (ひ), 水 — вода (みず), 木 — дерево (き), 金 — золото/деньги (かね), 土 — земля (つち). В сложных словах чтение может меняться. В письме ориентируйтесь на значение рядом со звучанием.",
            items: try kanjiItems(["日|ひ/にち/じつ|День, солнце", "月|つき/げつ/がつ|Луна, месяц", "火|ひ/か|Огонь",
                "水|みず/すい|Вода", "木|き/もく/ぼく|Дерево", "金|かね/きん/こん|Золото, деньги", "土|つち/ど/と|Земля"],
                id: "kanji.nature", glyphs: glyphs))
    }
}
