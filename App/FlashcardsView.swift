import StudyIntelligence
import SwiftUI
import UniformTypeIdentifiers

private enum StudyLibrarySection: String, CaseIterable, Identifiable {
    case today = "Сегодня"
    case all = "Все"
    case mistakes = "Ошибки"
    var id: String { rawValue }
}

struct FlashcardsView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var editor: FlashcardDraft?
    @State private var showStudy = false
    @State private var showGenerator = false
    @State private var cardToDelete: Flashcard?
    @State private var section: StudyLibrarySection = .today

    private var store: FlashcardStore { workspace.flashcards }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.cards.isEmpty {
                ContentUnavailableView {
                    Label("Пока нечего изучать", systemImage: "rectangle.stack")
                } description: {
                    Text("Добавьте выражение из заметки, вручную или попросите помощника создать набор по теме.")
                } actions: {
                    HStack {
                        Button("Добавить выражение") { editor = FlashcardDraft() }
                            .buttonStyle(.borderedProminent)
                        Button("Создать по теме") { showGenerator = true }
                            .buttonStyle(.bordered)
                    }
                }
                .accessibilityIdentifier("flashcards-empty-state")
            } else {
                Picker("Раздел", selection: $section) {
                    ForEach(StudyLibrarySection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("study-library-section")
                Divider()
                libraryContent
            }
        }
        .background(Palette.background)
        .navigationTitle("Изучение")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editor) { value in
            FlashcardEditorSheet(editor: value, store: store)
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

            Button { editor = FlashcardDraft() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Добавить выражение")
            .accessibilityIdentifier("add-flashcard")

            Button { showStudy = true } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.dueCards.isEmpty)
            .accessibilityLabel("Начать практику")
            .accessibilityIdentifier("study-flashcards")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var regularHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Изучение").font(.title2.bold())
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
            Button { editor = FlashcardDraft() } label: {
                Label("Добавить", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("add-flashcard")
            Button { showStudy = true } label: {
                Label("Практика", systemImage: "play.fill")
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

    @ViewBuilder private var libraryContent: some View {
        switch section {
        case .today:
            List {
                Section {
                    Button { showStudy = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: store.dueCards.isEmpty ? "checkmark.circle.fill" : "play.circle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.dueCards.isEmpty ? "На сегодня всё" : "Начать практику").font(.headline)
                                Text(store.dueCards.isEmpty ? "Новые задания появятся по расписанию" : "\(taskCountText(store.dueCards.count)): узнавание, ввод и пропуски")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !store.dueCards.isEmpty { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.dueCards.isEmpty)
                }
                if !store.mistakeCards.isEmpty {
                    cardRows(Array(store.mistakeCards.prefix(5)), title: "Требуют внимания")
                }
                if !recentCards.isEmpty {
                    cardRows(recentCards, title: "Недавно добавлено")
                }
            }
            .listStyle(.insetGrouped)
        case .all:
            List { cardRows(store.cards.sorted { $0.createdAt > $1.createdAt }, title: "Все выражения · \(store.cards.count)") }
                .listStyle(.insetGrouped)
        case .mistakes:
            if store.mistakeCards.isEmpty {
                ContentUnavailableView("Ошибок пока нет", systemImage: "checkmark.seal", description: Text("Здесь появятся выражения, которые стоит повторить внимательнее."))
            } else {
                List { cardRows(store.mistakeCards, title: "Требуют внимания · \(store.mistakeCards.count)") }
                    .listStyle(.insetGrouped)
            }
        }
    }

    @ViewBuilder private func cardRows(_ cards: [Flashcard], title: String) -> some View {
        Section(title) {
            ForEach(cards) { card in
                Button { editor = FlashcardDraft(card: card) } label: {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(card.japanese).font(.title3.weight(.medium))
                            if !card.reading.isEmpty { Text(card.reading).font(.caption).foregroundStyle(.secondary) }
                            if card.pronunciationAudio != nil {
                                Label("Живая запись", systemImage: "waveform")
                                    .font(.caption2).foregroundStyle(Palette.accent)
                            }
                            if let sourcePath = card.sourcePath {
                                Label((sourcePath as NSString).lastPathComponent, systemImage: "doc.text")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(minWidth: 130, alignment: .leading)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(card.translation).foregroundStyle(.primary)
                            Text(dueText(card)).font(.caption).foregroundStyle(card.dueAt <= Date() ? Palette.accent : .secondary)
                            if card.failedReviews > 0 {
                                Text("Ошибок: \(card.failedReviews)").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .swipeActions { Button("Удалить", role: .destructive) { cardToDelete = card } }
                .contextMenu {
                    Button("Редактировать", systemImage: "pencil") { editor = FlashcardDraft(card: card) }
                    if card.sourcePath != nil {
                        Button("Открыть источник", systemImage: "arrow.up.right.square") { openSource(card) }
                    }
                    Button("Удалить", systemImage: "trash", role: .destructive) { cardToDelete = card }
                }
            }
        }
    }

    private func dueText(_ card: Flashcard) -> String {
        if card.dueAt <= Date() { return "Готова к повторению" }
        return "Следующее повторение " + card.dueAt.formatted(date: .abbreviated, time: .omitted)
    }

    private var recentCards: [Flashcard] {
        Array(store.cards.filter { !$0.hasMistakes }.sorted { $0.createdAt > $1.createdAt }.prefix(5))
    }

    private func taskCountText(_ count: Int) -> String {
        let modulo100 = count % 100
        let modulo10 = count % 10
        let noun = modulo100 >= 11 && modulo100 <= 14 ? "заданий" :
            modulo10 == 1 ? "задание" :
            (2...4).contains(modulo10) ? "задания" : "заданий"
        return "\(count) \(noun)"
    }

    private func openSource(_ card: Flashcard) {
        guard let path = card.sourcePath else { return }
        Task {
            await workspace.open(path, pageID: card.sourcePageID)
            dismiss()
        }
    }
}

struct FlashcardDraft: Identifiable {
    let id = UUID()
    var cardID = UUID()
    var japanese = ""
    var reading = ""
    var translation = ""
    var example = ""
    var note = ""
    var sourcePath: String?
    var sourcePageID: UUID?
    var sourceExcerpt: String?
    var pitchAccent = ""
    var pronunciationAudio: FlashcardAudio?
    var original: Flashcard?

    init(card: Flashcard? = nil, japanese: String = "", note: String = "", source: StudySource? = nil) {
        original = card
        cardID = card?.id ?? UUID()
        self.japanese = card?.japanese ?? japanese
        reading = card?.reading ?? ""
        translation = card?.translation ?? ""
        example = card?.example ?? ""
        self.note = card?.note ?? note
        sourcePath = card?.sourcePath ?? source?.path
        sourcePageID = card?.sourcePageID ?? source?.pageID
        sourceExcerpt = card?.sourceExcerpt ?? source?.excerpt
        pitchAccent = card?.pitchAccent ?? ""
        pronunciationAudio = card?.pronunciationAudio
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
        card.sourcePath = sourcePath
        card.sourcePageID = sourcePageID
        card.sourceExcerpt = sourceExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines)
        card.pitchAccent = pitchAccent.nilIfBlank
        card.pronunciationAudio = pronunciationAudio
        return card
    }
}

struct StudySource: Equatable, Sendable {
    var path: String
    var pageID: UUID?
    var excerpt: String?
}

struct FlashcardEditorSheet: View {
    @State var editor: FlashcardDraft
    let store: FlashcardStore
    @Environment(\.dismiss) private var dismiss
    @State private var showAudioImporter = false
    @State private var pendingAudioURL: URL?
    @State private var pendingAudioName: String?
    @State private var audioSource: FlashcardAudioSource = .sourceClip
    @State private var removeExistingAudio = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Лицевая сторона") {
                    TextField("Японское слово или фраза", text: $editor.japanese, axis: .vertical)
                        .accessibilityIdentifier("flashcard-japanese")
                    TextField("Чтение хираганой (необязательно)", text: $editor.reading)
                }
                Section("Произношение") {
                    TextField("Pitch accent, например 0 (平板)", text: $editor.pitchAccent)
                        .accessibilityIdentifier("flashcard-pitch-accent")
                    Picker("Тип записи", selection: $audioSource) {
                        ForEach(FlashcardAudioSource.allCases, id: \.self) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    Button {
                        showAudioImporter = true
                    } label: {
                        Label(pendingAudioName ?? currentAudioName ?? "Добавить аудиозапись", systemImage: "waveform.badge.plus")
                    }
                    .accessibilityIdentifier("import-pronunciation-audio")

                    if pendingAudioName != nil || currentAudioName != nil {
                        Button("Удалить запись", role: .destructive) {
                            pendingAudioURL = nil
                            pendingAudioName = nil
                            removeExistingAudio = true
                        }
                    }

                    PronunciationReferencesMenu(term: editor.japanese)
                        .disabled(editor.japanese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Text("Добавляйте фрагмент исходного материала или проверенную запись носителя. Синтетическая речь не используется как эталон.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Ответ") {
                    TextField("Перевод", text: $editor.translation, axis: .vertical)
                        .accessibilityIdentifier("flashcard-translation")
                    TextField("Пример (необязательно)", text: $editor.example, axis: .vertical)
                    TextField("Подсказка (необязательно)", text: $editor.note, axis: .vertical)
                }
                if let sourcePath = editor.sourcePath {
                    Section("Источник") {
                        Label(sourcePath, systemImage: "doc.text").font(.subheadline)
                        if let excerpt = editor.sourceExcerpt, !excerpt.isEmpty {
                            Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                        }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle(editor.original == nil ? "Добавить в изучение" : "Редактировать")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await saveCard() } }
                        .disabled(!editor.isValid || saving)
                        .accessibilityIdentifier("save-flashcard")
                }
            }
            .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio]) { result in
                do {
                    let url = try result.get()
                    pendingAudioURL = url
                    pendingAudioName = url.lastPathComponent
                    removeExistingAudio = false
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .onAppear {
                if let source = editor.pronunciationAudio?.source { audioSource = source }
            }
        }
    }

    private var currentAudioName: String? {
        removeExistingAudio ? nil : editor.pronunciationAudio?.fileName
    }

    private func saveCard() async {
        saving = true
        error = nil
        do {
            let previousAudio = editor.original?.pronunciationAudio
            if removeExistingAudio { editor.pronunciationAudio = nil }
            if let pendingAudioURL {
                editor.pronunciationAudio = try await store.importPronunciationAudio(from: pendingAudioURL, source: audioSource)
            } else if var audio = editor.pronunciationAudio {
                audio.source = audioSource
                editor.pronunciationAudio = audio
            }
            let card = editor.makeCard()
            if store.cards.contains(where: { $0.id == card.id }) { await store.update(card) }
            else { await store.add(card) }
            if let previousAudio, previousAudio.relativePath != card.pronunciationAudio?.relativePath {
                await store.deletePronunciationAudio(previousAudio)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
            saving = false
        }
    }
}

private struct FlashcardStudyView: View {
    @Bindable var store: FlashcardStore
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [FlashcardExercise] = []
    @State private var index = 0
    @State private var revealed = false
    @State private var response = ""
    @FocusState private var responseFocused: Bool

    private var exercise: FlashcardExercise? { queue.indices.contains(index) ? queue[index] : nil }

    var body: some View {
        NavigationStack {
            Group {
                if let exercise {
                    VStack(spacing: 24) {
                        ProgressView(value: Double(index + 1), total: Double(max(queue.count, 1)))
                            .accessibilityLabel("Прогресс повторения")
                        Spacer(minLength: 10)
                        VStack(spacing: 14) {
                            Label(exerciseTitle(exercise.mode), systemImage: exerciseIcon(exercise.mode))
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(exercise.prompt)
                                .font(.system(size: 46, weight: .medium, design: .rounded))
                                .multilineTextAlignment(.center)
                            if exercise.mode != .recognition && !revealed {
                                TextField("Введите ответ по-японски", text: $response, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.title3)
                                    .multilineTextAlignment(.center)
                                    .focused($responseFocused)
                                    .submitLabel(.done)
                                    .onSubmit { revealed = true }
                                    .accessibilityIdentifier("study-response")
                            }
                            if revealed {
                                Divider().padding(.vertical, 8)
                                Text(exercise.card.japanese).font(.title2).multilineTextAlignment(.center)
                                if !exercise.card.reading.isEmpty { Text(exercise.card.reading).font(.title3).foregroundStyle(.secondary) }
                                if let pitchAccent = exercise.card.pitchAccent, !pitchAccent.isEmpty {
                                    Label(pitchAccent, systemImage: "waveform.path")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Text(exercise.card.translation).font(.body).multilineTextAlignment(.center)
                                if exercise.mode != .recognition, !response.isEmpty {
                                    Label(answerMatches(response, exercise.expectedAnswer) ? "Ответ совпал" : "Сравните свой ответ с образцом",
                                          systemImage: answerMatches(response, exercise.expectedAnswer) ? "checkmark.circle.fill" : "arrow.left.arrow.right")
                                        .font(.callout).foregroundStyle(answerMatches(response, exercise.expectedAnswer) ? Palette.accent : .orange)
                                }
                                if !exercise.card.example.isEmpty { Text(exercise.card.example).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                                if !exercise.card.note.isEmpty { Label(exercise.card.note, systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary) }
                                if let excerpt = exercise.card.sourceExcerpt, !excerpt.isEmpty {
                                    Label(excerpt, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                                PronunciationPracticePanel(card: exercise.card, store: store)
                                PronunciationReferencesMenu(term: exercise.card.japanese)
                            }
                        }
                        .padding(32)
                        .frame(maxWidth: 620, minHeight: 330)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 24))
                        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
                        Spacer()
                        if revealed { ratingButtons(exercise.card) }
                        else {
                            Button(exercise.mode == .recognition ? "Показать ответ" : "Проверить") { revealed = true }
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
                        Text("Готово: \(cardCountText(queue.count))")
                    } actions: {
                        Button("Закрыть") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .background(Palette.background)
            .navigationTitle(exercise == nil ? "Готово" : "\(index + 1) из \(queue.count)")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .onAppear {
                if queue.isEmpty { queue = FlashcardPracticeQueue.exercises(for: store.dueCards) }
                responseFocused = exercise?.mode != .recognition
            }
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
                response = ""
                responseFocused = exercise?.mode != .recognition
            }
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .accessibilityIdentifier("rate-flashcard-\(title)")
    }

    private func exerciseTitle(_ mode: FlashcardExerciseMode) -> String {
        switch mode {
        case .recognition: "Вспомните значение"
        case .production: "Напишите по-японски"
        case .cloze: "Заполните пропуск"
        }
    }

    private func exerciseIcon(_ mode: FlashcardExerciseMode) -> String {
        switch mode {
        case .recognition: "eye"
        case .production: "keyboard"
        case .cloze: "text.badge.checkmark"
        }
    }

    private func answerMatches(_ answer: String, _ expected: String) -> Bool {
        answer.folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines) ==
        expected.folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func cardCountText(_ count: Int) -> String {
        let modulo100 = count % 100
        let modulo10 = count % 10
        let noun = modulo100 >= 11 && modulo100 <= 14 ? "карточек" :
            modulo10 == 1 ? "карточка" :
            (2...4).contains(modulo10) ? "карточки" : "карточек"
        return "\(count) \(noun)"
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
