import StudyCore
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
    @State private var practiceMode: FlashcardPracticeMode = .cards
    @State private var showGenerator = false
    @State private var showReminderSettings = false
    @State private var cardToDelete: Flashcard?
    @State private var cardToShare: Flashcard?
    @State private var section: StudyLibrarySection = .today
    @State private var tracingAlphabet: KanaAlphabet?

    private var store: FlashcardStore { workspace.flashcards }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            kanaAssignments
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
                practiceModePicker
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
        .sheet(item: $cardToShare) { card in
            FlashcardShareSheet(card: card)
        }
        .onChange(of: StudyCompanion.shared.openLibraryRequest) { _, _ in
            showReminderSettings = false
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Напоминания и виджет", systemImage: "bell") { showReminderSettings = true }
                    .accessibilityIdentifier("study-reminder-settings")
            }
        }
        .sheet(isPresented: $showReminderSettings) { StudyReminderSettings() }
        .sheet(isPresented: $showGenerator) {
            FlashcardGeneratorSheet(workspace: workspace)
        }
        .fullScreenCover(isPresented: $showStudy) {
            FlashcardStudyView(store: store, mode: practiceMode)
        }
        .fullScreenCover(item: $tracingAlphabet) { alphabet in
            KanaTracingView(alphabet: alphabet)
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

    private var kanaAssignments: some View {
        HStack(spacing: 12) {
            ForEach(KanaAlphabet.allCases) { alphabet in
                Button { tracingAlphabet = alphabet } label: {
                    HStack(spacing: 10) {
                        Text(alphabet.example).font(.title2).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alphabet.title).font(.subheadline.weight(.semibold))
                            Text("Пропись · 46 знаков").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Пропись \(alphabet.title)")
                .accessibilityIdentifier("trace-\(alphabet.rawValue)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            .disabled(practiceCards.isEmpty)
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
            .disabled(practiceCards.isEmpty)
            .accessibilityIdentifier("study-flashcards")
        }
        .padding(20)
    }

    private var practiceCards: [Flashcard] {
        store.dueCards.filter { practiceMode == .cards || FlashcardQuiz.canPractice($0, vocabulary: store.cards) }
    }

    private var reviewStatus: String {
        if practiceMode == .quiz, practiceCards.isEmpty, !store.dueCards.isEmpty {
            return "Нет подходящих карточек для quiz"
        }
        return practiceCards.isEmpty ? "На сегодня всё повторено" : "К повторению: \(practiceCards.count)"
    }

    private var practiceModePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Режим практики", selection: $practiceMode) {
                ForEach(FlashcardPracticeMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("study-practice-mode")
            Text(practiceMode == .cards
                 ? "Вспоминайте ответ и оценивайте карточку свайпом."
                 : "Выберите перевод. Для quiz нужны слова с текстом и хотя бы два разных перевода.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    @ViewBuilder private var libraryContent: some View {
        switch section {
        case .today:
            List {
                Section {
                    Button { showStudy = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: practiceCards.isEmpty ? "checkmark.circle.fill" : "play.circle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(practiceCards.isEmpty ? reviewStatus : "Начать практику").font(.headline)
                                Text(practiceCards.isEmpty ? (practiceMode == .quiz ? "Добавьте слова с текстом и разными переводами или выберите режим карточек" : "Новые задания появятся по расписанию") : "До 20 карточек за круг · ошибки повторим ещё раз")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !practiceCards.isEmpty { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(practiceCards.isEmpty)
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
                            FlashcardFieldContent(text: card.japanese, drawing: card.handwriting?.japanese, maxHeight: 64)
                                .font(.title3.weight(.medium))
                            if !card.reading.isEmpty || card.handwriting?.reading != nil {
                                FlashcardFieldContent(text: card.reading, drawing: card.handwriting?.reading, maxHeight: 40)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
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
                            FlashcardFieldContent(text: card.translation, drawing: card.handwriting?.translation, maxHeight: 64)
                                .foregroundStyle(.primary)
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
                .accessibilityIdentifier("flashcard-row-\(card.id)")
                .swipeActions { Button("Удалить", role: .destructive) { cardToDelete = card } }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button("Поделиться", systemImage: "square.and.arrow.up") { cardToShare = card }
                        .tint(Palette.accent)
                }
                .contextMenu {
                    Button("Поделиться", systemImage: "square.and.arrow.up") { cardToShare = card }
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
    var handwriting = FlashcardHandwriting()
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
        handwriting = card?.handwriting ?? FlashcardHandwriting()
    }

    var isValid: Bool {
        (!japanese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || handwriting.japanese != nil) &&
        (!translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || handwriting.translation != nil)
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
        card.handwriting = handwriting.isEmpty ? nil : handwriting
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
    @State private var handwritingInput = false
    @State private var handwritingTools = FlashcardDrawingTools()
    @State private var cardToShare: Flashcard?
    @AppStorage("flashcard-handwriting-paper") private var handwritingPaper: PaperPattern = .japanese

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Ввод", selection: $handwritingInput) {
                        Text("От руки").tag(true)
                        Text("Клавиатура").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("flashcard-input-mode")
                    if handwritingInput {
                        Picker("Разлиновка", selection: $handwritingPaper) {
                            Text("Кана и кандзи").tag(PaperPattern.japanese)
                            Text("Линии").tag(PaperPattern.lines)
                            Text("Без разлиновки").tag(PaperPattern.plain)
                        }
                        .accessibilityIdentifier("flashcard-paper-pattern")
                    }
                } footer: {
                    Text("После сохранения карточка сразу попадёт в общий пул изучения.")
                }
                Section("Словарная карточка") {
                    if handwritingInput {
                        FlashcardHandwritingField(title: "Иероглиф или слово", identifier: "flashcard-ink-japanese", drawing: $editor.handwriting.japanese, tools: handwritingTools, pattern: handwritingPaper)
                        FlashcardHandwritingField(title: "Транскрипция", identifier: "flashcard-ink-reading", drawing: $editor.handwriting.reading, tools: handwritingTools, pattern: handwritingPaper)
                        FlashcardHandwritingField(title: "Перевод", identifier: "flashcard-ink-translation", drawing: $editor.handwriting.translation, tools: handwritingTools, pattern: .lines)
                        Text("Пишите Apple Pencil или пальцем. Слово и перевод обязательны.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("Иероглиф, слово или фраза", text: $editor.japanese, axis: .vertical)
                            .accessibilityIdentifier("flashcard-japanese")
                        TextField("Транскрипция / чтение", text: $editor.reading)
                            .accessibilityIdentifier("flashcard-reading")
                        TextField("Перевод", text: $editor.translation, axis: .vertical)
                            .accessibilityIdentifier("flashcard-translation")
                    }
                }
                Section("Дополнительно") {
                    TextField("Пример (необязательно)", text: $editor.example, axis: .vertical)
                    TextField("Подсказка (необязательно)", text: $editor.note, axis: .vertical)
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
            .safeAreaPadding(.bottom, handwritingTools.bottomInset)
            .onChange(of: handwritingInput) { _, handwriting in
                if !handwriting { handwritingTools.hide() }
            }
            .onDisappear { handwritingTools.hide() }
            .disabled(saving)
            .navigationTitle(editor.original == nil ? "Добавить в изучение" : "Редактировать")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(saving)
                        .accessibilityIdentifier("cancel-flashcard-editor")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Поделиться", systemImage: "square.and.arrow.up") {
                        handwritingTools.hide()
                        cardToShare = editor.makeCard()
                    }
                    .disabled(!editor.isValid || saving)
                    .accessibilityIdentifier("share-flashcard")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await saveCard() } }
                        .disabled(!editor.isValid || saving)
                        .accessibilityIdentifier("save-flashcard")
                }
            }
            .sheet(item: $cardToShare) { card in FlashcardShareSheet(card: card) }
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
                handwritingInput = !editor.handwriting.isEmpty || (editor.original == nil && editor.japanese.isEmpty)
                if let source = editor.pronunciationAudio?.source { audioSource = source }
            }
            .interactiveDismissDisabled(saving)
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
            let saved: Bool
            if store.cards.contains(where: { $0.id == card.id }) { saved = await store.update(card) }
            else { saved = await store.add(card) }
            guard saved else {
                error = store.error
                saving = false
                return
            }
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
