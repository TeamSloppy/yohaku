import StudyIntelligence
import SwiftUI

struct FlashcardsView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var editor: FlashcardEditor?
    @State private var showStudy = false
    @State private var showGenerator = false
    @State private var cardToDelete: Flashcard?

    private var store: FlashcardStore { workspace.flashcards }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.cards.isEmpty {
                ContentUnavailableView {
                    Label("Пока нет карточек", systemImage: "rectangle.stack")
                } description: {
                    Text("Добавьте японское слово вручную или попросите помощника создать набор по теме.")
                } actions: {
                    HStack {
                        Button("Добавить карточку") { editor = FlashcardEditor() }
                            .buttonStyle(.borderedProminent)
                        Button("Создать по теме") { showGenerator = true }
                            .buttonStyle(.bordered)
                    }
                }
                .accessibilityIdentifier("flashcards-empty-state")
            } else {
                cardList
            }
        }
        .background(Palette.background)
        .navigationTitle("Карточки")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editor) { value in
            FlashcardEditorSheet(editor: value) { card in
                Task {
                    if store.cards.contains(where: { $0.id == card.id }) { await store.update(card) }
                    else { await store.add(card) }
                }
            }
        }
        .sheet(isPresented: $showGenerator) {
            FlashcardGeneratorSheet(workspace: workspace)
        }
        .fullScreenCover(isPresented: $showStudy) {
            FlashcardStudyView(store: store)
        }
        .confirmationDialog(
            "Удалить карточку?",
            isPresented: Binding(get: { cardToDelete != nil }, set: { if !$0 { cardToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let id = cardToDelete?.id { Task { await store.delete(id: id) } }
                cardToDelete = nil
            }
            Button("Отмена", role: .cancel) { cardToDelete = nil }
        } message: {
            Text(cardToDelete?.japanese ?? "")
        }
    }

    private var header: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactHeader
            } else {
                regularHeader
            }
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            Text(reviewStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button { showGenerator = true } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Создать с помощником")
            .accessibilityIdentifier("generate-flashcards")

            Button { editor = FlashcardEditor() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Добавить карточку")
            .accessibilityIdentifier("add-flashcard")

            Button { showStudy = true } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.dueCards.isEmpty)
            .accessibilityLabel("Повторять карточки")
            .accessibilityIdentifier("study-flashcards")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var regularHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Карточки").font(.title2.bold())
                Text(reviewStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { showGenerator = true } label: {
                Label("Создать с помощником", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("generate-flashcards")
            Button { editor = FlashcardEditor() } label: {
                Label("Добавить", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("add-flashcard")
            Button { showStudy = true } label: {
                Label("Повторять", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.dueCards.isEmpty)
            .accessibilityIdentifier("study-flashcards")
        }
        .padding(20)
    }

    private var reviewStatus: String {
        store.dueCards.isEmpty ? "На сегодня всё повторено" : "К повторению: \(store.dueCards.count)"
    }

    private var cardList: some View {
        List {
            if !store.dueCards.isEmpty {
                Section {
                    Button { showStudy = true } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(Palette.accent)
                            VStack(alignment: .leading) {
                                Text("Начать повторение").font(.headline)
                                Text("\(store.dueCards.count) карточек готовы сейчас").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Все карточки · \(store.cards.count)") {
                ForEach(store.cards.sorted { $0.createdAt > $1.createdAt }) { card in
                    Button { editor = FlashcardEditor(card: card) } label: {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(card.japanese).font(.title3.weight(.medium))
                                if !card.reading.isEmpty { Text(card.reading).font(.caption).foregroundStyle(.secondary) }
                            }
                            .frame(minWidth: 130, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(card.translation).foregroundStyle(.primary)
                                Text(dueText(card)).font(.caption).foregroundStyle(card.dueAt <= Date() ? Palette.accent : .secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Удалить", role: .destructive) { cardToDelete = card }
                    }
                    .contextMenu {
                        Button("Редактировать", systemImage: "pencil") { editor = FlashcardEditor(card: card) }
                        Button("Удалить", systemImage: "trash", role: .destructive) { cardToDelete = card }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func dueText(_ card: Flashcard) -> String {
        if card.dueAt <= Date() { return "Готова к повторению" }
        return "Следующее повторение " + card.dueAt.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct FlashcardEditor: Identifiable {
    let id = UUID()
    var cardID = UUID()
    var japanese = ""
    var reading = ""
    var translation = ""
    var example = ""
    var note = ""
    var original: Flashcard?

    init(card: Flashcard? = nil) {
        original = card
        cardID = card?.id ?? UUID()
        japanese = card?.japanese ?? ""
        reading = card?.reading ?? ""
        translation = card?.translation ?? ""
        example = card?.example ?? ""
        note = card?.note ?? ""
    }

    var isValid: Bool {
        !japanese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func makeCard() -> Flashcard {
        var card = original ?? Flashcard(id: cardID, japanese: japanese, translation: translation)
        card.japanese = japanese.trimmingCharacters(in: .whitespacesAndNewlines)
        card.reading = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        card.translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        card.example = example.trimmingCharacters(in: .whitespacesAndNewlines)
        card.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return card
    }
}

private struct FlashcardEditorSheet: View {
    @State var editor: FlashcardEditor
    let save: (Flashcard) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Лицевая сторона") {
                    TextField("Японское слово или фраза", text: $editor.japanese, axis: .vertical)
                        .accessibilityIdentifier("flashcard-japanese")
                    TextField("Чтение хираганой (необязательно)", text: $editor.reading)
                }
                Section("Ответ") {
                    TextField("Перевод", text: $editor.translation, axis: .vertical)
                        .accessibilityIdentifier("flashcard-translation")
                    TextField("Пример (необязательно)", text: $editor.example, axis: .vertical)
                    TextField("Подсказка (необязательно)", text: $editor.note, axis: .vertical)
                }
            }
            .navigationTitle(editor.original == nil ? "Новая карточка" : "Редактировать")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save(editor.makeCard()); dismiss() }
                        .disabled(!editor.isValid)
                        .accessibilityIdentifier("save-flashcard")
                }
            }
        }
    }
}

private struct FlashcardStudyView: View {
    @Bindable var store: FlashcardStore
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [Flashcard] = []
    @State private var index = 0
    @State private var revealed = false

    private var card: Flashcard? { queue.indices.contains(index) ? queue[index] : nil }

    var body: some View {
        NavigationStack {
            Group {
                if let card {
                    VStack(spacing: 24) {
                        ProgressView(value: Double(index), total: Double(max(queue.count, 1)))
                            .accessibilityLabel("Прогресс повторения")
                        Spacer(minLength: 10)
                        VStack(spacing: 14) {
                            Text(card.japanese)
                                .font(.system(size: 46, weight: .medium, design: .rounded))
                                .multilineTextAlignment(.center)
                            if !card.reading.isEmpty { Text(card.reading).font(.title3).foregroundStyle(.secondary) }
                            if revealed {
                                Divider().padding(.vertical, 8)
                                Text(card.translation).font(.title2).multilineTextAlignment(.center)
                                if !card.example.isEmpty { Text(card.example).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                                if !card.note.isEmpty { Label(card.note, systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(32)
                        .frame(maxWidth: 620, minHeight: 330)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 24))
                        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
                        Spacer()
                        if revealed { ratingButtons(card) }
                        else {
                            Button("Показать ответ") { revealed = true }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .accessibilityIdentifier("reveal-flashcard")
                        }
                    }
                    .padding(24)
                } else {
                    ContentUnavailableView {
                        Label("Повторение завершено", systemImage: "checkmark.circle")
                    } description: {
                        Text("Готово: \(queue.count) карточек")
                    } actions: {
                        Button("Закрыть") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .background(Palette.background)
            .navigationTitle(card == nil ? "Готово" : "\(index + 1) из \(queue.count)")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .onAppear { if queue.isEmpty { queue = store.dueCards } }
        }
    }

    private func ratingButtons(_ card: Flashcard) -> some View {
        HStack(spacing: 12) {
            ratingButton("Не помню", icon: "arrow.counterclockwise", tint: .red, rating: .forgot, card: card)
            ratingButton("Сложно", icon: "tortoise", tint: .orange, rating: .hard, card: card)
            ratingButton("Помню", icon: "checkmark", tint: Palette.accent, rating: .remembered, card: card)
        }
    }

    private func ratingButton(_ title: String, icon: String, tint: Color, rating: FlashcardRating, card: Flashcard) -> some View {
        Button {
            Task {
                await store.review(id: card.id, rating: rating)
                index += 1
                revealed = false
            }
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .accessibilityIdentifier("rate-flashcard-\(title)")
    }
}

private struct FlashcardGeneratorSheet: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var count = 10
    @State private var generated: [GeneratedFlashcard] = []
    @State private var selected = Set<Int>()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Тема") {
                    TextField("Например: еда в ресторане", text: $topic, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("flashcard-topic")
                    Stepper("Количество: \(count)", value: $count, in: 3...20)
                    Button {
                        Task { await generate() }
                    } label: {
                        if workspace.agent.running { ProgressView().frame(maxWidth: .infinity) }
                        else { Label("Создать карточки", systemImage: "sparkles").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.agent.running)
                    .accessibilityIdentifier("request-flashcards")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                if !generated.isEmpty {
                    Section("Предпросмотр · выбрано \(selected.count)") {
                        ForEach(generated.indices, id: \.self) { index in
                            Button {
                                if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: selected.contains(index) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(index) ? Palette.accent : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(generated[index].japanese).font(.headline)
                                        if !generated[index].reading.isEmpty { Text(generated[index].reading).font(.caption).foregroundStyle(.secondary) }
                                        Text(generated[index].translation).foregroundStyle(.primary)
                                        if !generated[index].example.isEmpty { Text(generated[index].example).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Карточки по теме")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { workspace.agent.cancel(); dismiss() } }
                if !generated.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Добавить (\(selected.count))") {
                            let cards = generated.indices.filter(selected.contains).map { value in
                                let card = generated[value]
                                return Flashcard(japanese: card.japanese, reading: card.reading, translation: card.translation, example: card.example, note: card.note)
                            }
                            Task { await workspace.flashcards.add(cards); dismiss() }
                        }
                        .disabled(selected.isEmpty)
                        .accessibilityIdentifier("save-generated-flashcards")
                    }
                }
            }
        }
    }

    private func generate() async {
        error = nil
        do {
            generated = try await workspace.agent.generateFlashcards(topic: topic, count: count)
            selected = Set(generated.indices)
        } catch is CancellationError {
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
