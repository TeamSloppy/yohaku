import SwiftUI

enum FlashcardSharing {
    /// Share only the visible learning content, without vault paths or review history.
    static func text(for card: Flashcard) -> String? {
        let word = card.japanese.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = card.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !translation.isEmpty else { return nil }
        var lines = [word]
        append(card.reading, to: &lines)
        lines.append(translation)
        append(card.pitchAccent, label: "Pitch accent", to: &lines)
        append(card.example, label: "Пример", to: &lines)
        append(card.note, label: "Заметка", to: &lines)
        return lines.joined(separator: "\n\n")
    }

    private static func append(_ value: String?, label: String? = nil, to lines: inout [String]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        lines.append(label.map { "\($0): \(value)" } ?? value)
    }

    @MainActor static func image(for card: Flashcard) -> UIImage? {
        let renderer = ImageRenderer(content: FlashcardShareArtwork(card: card)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large))
        renderer.scale = 2
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

struct FlashcardShareSheet: View {
    let card: Flashcard
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var renderingFinished = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let image {
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .accessibilityLabel("Карточка для отправки")
                            .accessibilityIdentifier("flashcard-share-preview")
                    } else if renderingFinished {
                        ContentUnavailableView("Не удалось создать изображение", systemImage: "photo")
                    } else {
                        ProgressView("Готовим карточку…")
                    }
                    Text("Поделитесь изображением или текстом карточки.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 540).frame(maxWidth: .infinity)
                .padding(20)
            }
            .background(Palette.background)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if let image {
                        let sharedImage = Image(uiImage: image)
                        ShareLink(item: sharedImage, preview: SharePreview("Карточка Yohaku", image: sharedImage)) {
                            Label("Поделиться изображением", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("share-flashcard-image")
                    }
                    if let text = FlashcardSharing.text(for: card) {
                        ShareLink(item: text) {
                            Label("Поделиться текстом", systemImage: "text.alignleft")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("share-flashcard-text")
                    }
                }
                .padding(20).background(Palette.background)
            }
            .navigationTitle("Поделиться карточкой")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                        .accessibilityIdentifier("close-flashcard-share")
                }
            }
            .task {
                image = FlashcardSharing.image(for: card)
                renderingFinished = true
            }
        }
    }
}

private struct FlashcardShareArtwork: View {
    let card: Flashcard

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("余白  Yohaku").font(.headline)
                Spacer()
                Image(systemName: "rectangle.on.rectangle")
            }
            .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 16) {
                FlashcardFieldContent(text: card.japanese, drawing: card.handwriting?.japanese, maxHeight: 180)
                    .font(.system(size: 44, weight: .medium))
                if !card.reading.isEmpty || card.handwriting?.reading != nil {
                    FlashcardFieldContent(text: card.reading, drawing: card.handwriting?.reading, maxHeight: 100)
                        .font(.title2).foregroundStyle(.secondary)
                }
                Divider()
                FlashcardFieldContent(text: card.translation, drawing: card.handwriting?.translation, maxHeight: 160)
                    .font(.title.weight(.medium))
                if let pitch = card.pitchAccent, !pitch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Pitch accent: \(pitch)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            detail("Пример", text: card.example)
            detail("Заметка", text: card.note)
        }
        .foregroundStyle(.primary)
        .padding(36)
        .frame(width: 540, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.surface)
    }

    @ViewBuilder private func detail(_ title: String, text: String) -> some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                Text(text).font(.title3)
            }
        }
    }
}
