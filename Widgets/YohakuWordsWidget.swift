import SwiftUI
import WidgetKit

struct WordEntry: TimelineEntry {
    let date: Date
    let card: StudyWidgetCard?
}

struct WordsProvider: TimelineProvider {
    func placeholder(in context: Context) -> WordEntry { Self.sample }

    func getSnapshot(in context: Context, completion: @escaping (WordEntry) -> Void) {
        completion(context.isPreview ? Self.sample : WordEntry(date: Date(), card: StudyWidgetStorage.load().card(at: Date())))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WordEntry>) -> Void) {
        let snapshot = StudyWidgetStorage.load()
        let entries = StudyWidgetSnapshot.entryDates(from: Date()).map {
            WordEntry(date: $0, card: snapshot.card(at: $0))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static var sample: WordEntry {
        WordEntry(date: Date(), card: StudyWidgetCard(id: UUID(), japanese: "余白", reading: "よはく", translation: "свободное пространство"))
    }
}

struct WordWidgetView: View {
    let entry: WordEntry
    @Environment(\.widgetFamily) private var family
    private let accent = Color(red: 0.19, green: 0.42, blue: 0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Yohaku", systemImage: "rectangle.on.rectangle")
                    .font(.caption.weight(.semibold)).foregroundStyle(accent)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary)
            }
            if let card = entry.card {
                Spacer(minLength: 0)
                field(card.japanese, image: card.japaneseImage, height: family == .systemSmall ? 45 : 55)
                    .font(.system(size: family == .systemSmall ? 30 : 36, weight: .medium, design: .serif))
                if !card.reading.isEmpty || card.readingImage != nil {
                    field(card.reading, image: card.readingImage, height: 24)
                        .font(.caption).foregroundStyle(.secondary)
                }
                field(card.translation, image: card.translationImage, height: 35)
                    .font(.subheadline)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Text("Слова под рукой").font(.headline)
                Text("Добавьте карточки в Yohaku — здесь появится слово на каждый час.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .lineLimit(2)
        .minimumScaleFactor(0.65)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
        .widgetURL(StudyWidgetStorage.studyURL)
    }

    @ViewBuilder private func field(_ text: String, image data: Data?, height: CGFloat) -> some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: height, alignment: .leading)
                .padding(3).background(.white, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel(text.isEmpty ? "Рукописная карточка" : text)
        } else {
            Text(text)
        }
    }
}

@main struct YohakuWordsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StudyWidgetStorage.kind, provider: WordsProvider()) { entry in
            WordWidgetView(entry: entry)
        }
        .configurationDisplayName("Слово на час")
        .description("Слово, чтение и перевод из ваших карточек. Новое слово каждый час.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
