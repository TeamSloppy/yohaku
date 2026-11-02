import SwiftUI

struct FlashcardStudyView: View {
    @Bindable var store: FlashcardStore
    let mode: FlashcardPracticeMode
    var suppliedExercises: [FlashcardExercise]? = nil
    var suppliedMaterials: () -> [StudyMaterialRecord]? = { nil }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var session = FlashcardPracticeSession()
    @State private var started = false
    @State private var browsing: FlashcardBrowseSession?
    @State private var selectedExercises: [FlashcardExercise]?
    @State private var promptStyle: FlashcardStudyPrompt = .mixed
    @State private var revealed = false
    @State private var response = ""
    @State private var responseDrawing: Data?
    @State private var handwritingTools = FlashcardDrawingTools()
    @State private var quiz: FlashcardQuizQuestion?
    @State private var selectedChoice: FlashcardQuizChoice?
    @State private var dragOffset = CGSize.zero
    @State private var submitting = false
    @State private var saveError: String?
    @State private var cardToShare: Flashcard?
    @FocusState private var responseFocused: Bool

    private var exercise: FlashcardExercise? { session.current }
    private var canSwipe: Bool { mode == .cards && revealed && !submitting }
    private var incorrectResponse: Bool {
        guard let exercise else { return false }
        if let selectedChoice, let quiz { return !quiz.isCorrect(selectedChoice) }
        return exercise.mode != .recognition && !response.isEmpty &&
            !FlashcardAnswer.matches(response, card: exercise.card)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !started, suppliedExercises == nil {
                    FlashcardStudySetupView(store: store, mode: mode) { exercises, browse, prompt in
                        selectedExercises = exercises
                        promptStyle = prompt
                        started = true
                        if browse { browsing = FlashcardBrowseSession(exercises: exercises) }
                        else { startRound() }
                    }
                } else if let browsing {
                    FlashcardBrowseView(session: browsing) { self.browsing = nil; startRound() }
                } else if let exercise {
                    VStack(spacing: 12) {
                        progress
                        if !responseFocused {
                            cardDeck(exercise)
                                .padding(.horizontal, 24).padding(.top, 16)
                        }
                        ScrollView {
                            VStack(spacing: 20) {
                                if responseFocused { cardDeck(exercise) }
                                if !revealed, exercise.card.handwriting?.japanese != nil { responseInput(exercise) }
                                if mode == .quiz, let quiz { quizChoices(quiz) }
                                if revealed { details(exercise.card) }
                            }
                            .id("\(exercise.id)-\(session.round)")
                            .frame(maxWidth: 620)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24).padding(.vertical, 16)
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 12) {
                            if !revealed, exercise.card.handwriting?.japanese == nil { responseInput(exercise) }
                            controls(exercise)
                        }
                            .frame(maxWidth: 620).frame(maxWidth: .infinity)
                            .padding(.horizontal, 24).padding(.vertical, 12)
                            .background(Palette.background)
                    }
                } else {
                    completion
                }
            }
            .background(Palette.background)
            .safeAreaPadding(.bottom, handwritingTools.bottomInset)
            .navigationTitle(!started ? String(localized: "Настроить практику")
                             : browsing != nil ? String(localized: "Знакомство со словами") : mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if revealed, let exercise {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Поделиться", systemImage: "square.and.arrow.up") {
                            handwritingTools.hide()
                            cardToShare = exercise.card
                        }
                        .disabled(submitting)
                        .accessibilityIdentifier("share-study-flashcard")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { handwritingTools.hide(); dismiss() }
                        .disabled(submitting)
                        .accessibilityIdentifier("close-study")
                }
            }
            .sheet(item: $cardToShare) { card in FlashcardShareSheet(card: card) }
            .onAppear { start() }
            .onDisappear { handwritingTools.hide() }
            .alert("Не удалось сохранить ответ", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
    }

    private var progress: some View {
        VStack(spacing: 8) {
            HStack {
                Text(session.round == 1 ? "Основной круг" : "Повтор ошибок · круг \(session.round)")
                    .accessibilityIdentifier("study-round")
                Spacer()
                Text("\(session.index + 1) из \(session.queue.count)")
            }
            .font(.subheadline).foregroundStyle(.secondary)
            ProgressView(value: Double(session.index), total: Double(max(session.queue.count, 1)))
                .accessibilityLabel("Прогресс повторения")
            Text("Слов в сессии: \(session.initialCount) · ответов: \(session.attemptCount)")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("study-session-counts")
        }
        .padding(.horizontal, 24).padding(.top, 12)
    }

    private func cardDeck(_ exercise: FlashcardExercise) -> some View {
        ZStack {
            if session.index + 1 < session.queue.count || !session.mistakes.isEmpty {
                RoundedRectangle(cornerRadius: 26).fill(Palette.surface.opacity(0.6))
                    .padding(.horizontal, 16).offset(y: 12)
                RoundedRectangle(cornerRadius: 26).fill(Palette.surface.opacity(0.8))
                    .padding(.horizontal, 8).offset(y: 6)
            }
            cardFace(exercise)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 280)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 26))
                .overlay(alignment: .topTrailing) {
                    if let rating = FlashcardSwipe.rating(x: dragOffset.width, y: dragOffset.height) {
                        Text(ratingTitle(rating)).font(.headline)
                            .padding(12).background(ratingTint(rating).opacity(0.15), in: Capsule())
                            .foregroundStyle(ratingTint(rating)).padding(12)
                    }
                }
                .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
                .rotationEffect(.degrees(reduceMotion ? 0 : Double(dragOffset.width / 24)))
                .offset(reduceMotion ? .zero : dragOffset)
                .contentShape(RoundedRectangle(cornerRadius: 26))
                .highPriorityGesture(swipeGesture, including: canSwipe ? .all : .none)
        }
        .padding(.bottom, 12)
    }

    private func cardFace(_ exercise: FlashcardExercise) -> some View {
        VStack(spacing: 16) {
            Label(exerciseTitle(exercise.mode), systemImage: mode == .quiz ? "list.bullet" : exerciseIcon(exercise.mode))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            FlashcardFieldContent(text: promptStyle.text(for: exercise),
                                  drawing: promptStyle == .kana ? nil : exercise.promptHandwriting, maxHeight: 130)
                .font(.system(size: 42, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("study-prompt")
            if revealed {
                Divider()
                if exercise.mode != .recognition || (promptStyle == .kana && exercise.card.japanese != promptStyle.text(for: exercise)) {
                    FlashcardFieldContent(text: exercise.card.japanese, drawing: exercise.card.handwriting?.japanese, maxHeight: 100)
                        .font(.title2)
                }
                FlashcardFieldContent(text: exercise.card.reading, drawing: exercise.card.handwriting?.reading, maxHeight: 60)
                    .font(.title3).foregroundStyle(.secondary)
                FlashcardFieldContent(text: exercise.card.translation, drawing: exercise.card.handwriting?.translation, maxHeight: 90)
                    .font(.title3)
                if incorrectResponse {
                    Label("Ошибка · повторим ещё раз", systemImage: "arrow.counterclockwise")
                        .font(.callout).foregroundStyle(.orange)
                        .accessibilityIdentifier("study-answer-incorrect")
                } else if selectedChoice != nil || !response.isEmpty {
                    Label("Ответ совпал", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(Palette.accent)
                }
            }
            if mode == .cards {
                Text(revealed ? "← Не помню     ↑ Сложно     Помню →" : "Вспомните ответ, затем откройте карточку")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder private func responseInput(_ exercise: FlashcardExercise) -> some View {
        if mode == .cards, exercise.mode != .recognition {
            if exercise.card.handwriting?.japanese != nil {
                FlashcardHandwritingField(title: "Напишите по памяти", identifier: "study-ink-response", drawing: $responseDrawing, tools: handwritingTools)
            } else {
                TextField("Введите ответ по-японски", text: $response, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder).font(.title3)
                    .multilineTextAlignment(.center).focused($responseFocused)
                    .submitLabel(.done).onSubmit { reveal() }
                    .accessibilityIdentifier("study-response")
            }
        }
    }

    private func quizChoices(_ quiz: FlashcardQuizQuestion) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(quiz.choices.enumerated()), id: \.element.id) { index, choice in
                Button {
                    guard !revealed, !submitting else { return }
                    selectedChoice = choice
                    reveal()
                } label: {
                    HStack {
                        Text(choice.text).multilineTextAlignment(.leading)
                        Spacer()
                        if revealed, quiz.isCorrect(choice) { Image(systemName: "checkmark.circle.fill") }
                        else if revealed, choice == selectedChoice { Image(systemName: "xmark.circle.fill") }
                    }
                    .padding(14).frame(maxWidth: .infinity, minHeight: 48)
                    .background(choiceTint(choice, quiz: quiz).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(choiceTint(choice, quiz: quiz).opacity(0.4)))
                }
                .buttonStyle(.plain).foregroundStyle(choiceTint(choice, quiz: quiz))
                .disabled(revealed || submitting)
                .accessibilityIdentifier("quiz-choice-\(index)")
            }
        }
    }

    private func choiceTint(_ choice: FlashcardQuizChoice, quiz: FlashcardQuizQuestion) -> Color {
        guard revealed else { return .primary }
        if quiz.isCorrect(choice) { return Palette.accent }
        return choice == selectedChoice ? .red : .secondary
    }

    private func details(_ card: Flashcard) -> some View {
        DisclosureGroup("Пример, заметки и произношение") {
            VStack(spacing: 14) {
                if responseDrawing != nil {
                    Text("Ваш ответ").font(.caption).foregroundStyle(.secondary)
                    FlashcardFieldContent(text: "", drawing: responseDrawing, maxHeight: 70)
                }
                if !card.example.isEmpty { Text(card.example) }
                if !card.note.isEmpty { Label(card.note, systemImage: "lightbulb") }
                if let excerpt = card.sourceExcerpt, !excerpt.isEmpty {
                    if let origin = card.sourceTextOrigin { Text(origin.label).font(.caption2) }
                    Label(excerpt, systemImage: "doc.text").font(.caption)
                    if let region = card.sourceRegion { Text(studyRegionDescription(region)).font(.caption2) }
                }
                if let pitch = card.pitchAccent, !pitch.isEmpty { Label(pitch, systemImage: "waveform.path") }
                if !card.japanese.isEmpty {
                    PronunciationPracticePanel(card: card, store: store)
                    PronunciationReferencesMenu(term: card.japanese)
                }
            }
            .padding(.top, 12).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    @ViewBuilder private func controls(_ exercise: FlashcardExercise) -> some View {
        if revealed {
            if mode == .quiz {
                Button { submit(incorrectResponse ? .forgot : .remembered) } label: {
                    Label("Дальше", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("quiz-next")
                    .disabled(submitting)
            } else {
                HStack(spacing: 8) {
                    ratingButton(.forgot, icon: "arrow.left")
                    ratingButton(.hard, icon: "arrow.up")
                    ratingButton(.remembered, icon: "arrow.right")
                }
                .disabled(submitting)
            }
        } else if mode == .cards {
            Button(exercise.mode == .recognition ? "Показать ответ" : "Проверить") { reveal() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("reveal-flashcard")
        } else {
            Text("Выберите перевод").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func ratingButton(_ rating: FlashcardRating, icon: String) -> some View {
        Button { submit(rating) } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                Text(ratingTitle(rating)).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered).tint(ratingTint(rating))
        .accessibilityIdentifier("rate-flashcard-\(ratingTitle(rating))")
    }

    private var completion: some View {
        ScrollView {
            VStack(spacing: 24) {
                StudyCelebrationView(title: "Повторение завершено", detail: "Карточек: \(session.initialCount) · ответов: \(session.attemptCount)")
                Text(session.mistakes.isEmpty ? "Все карточки пройдены" : "Ещё требуют внимания: \(session.remainingMistakeCount). Они остаются к повторению.")
                    .foregroundStyle(.secondary)
                if !session.mistakes.isEmpty {
                    Button("Повторить ошибки") { session.repeatMistakes(); prepareExercise() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("study-repeat-mistakes")
                }
                if selectedExercises != nil || !practiceCandidates.isEmpty {
                    Button("Продолжить практику") { startRound() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("study-continue")
                }
                if suppliedExercises == nil {
                    Button("Выбрать другие слова") {
                        session = FlashcardPracticeSession()
                        selectedExercises = nil
                        started = false
                        prepareExercise()
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("study-reconfigure")
                }
                Button("Закрыть") { dismiss() }.buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center).padding(24)
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
            .onChanged { value in
                guard canSwipe else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard canSwipe else { return }
                if let rating = FlashcardSwipe.rating(x: value.translation.width, y: value.translation.height) {
                    submit(rating)
                } else { withAnimation(.spring()) { dragOffset = .zero } }
            }
    }

    private func start() {
        guard !started, suppliedExercises != nil else { return }
        started = true
        startRound(supplied: suppliedExercises)
    }

    private var practiceCandidates: [Flashcard] {
        store.cards.filter { mode == .cards || FlashcardQuiz.canPractice($0, vocabulary: store.cards) }
    }

    private func startRound(supplied: [FlashcardExercise]? = nil) {
        let now = Date()
        let candidates = practiceCandidates
        let due = candidates.filter { $0.dueAt <= now }
        var exercises: [FlashcardExercise]
        if let selectedExercises {
            // Keep the chosen IDs and order, even after reviews make "new" cards familiar.
            let current = Dictionary(store.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            exercises = selectedExercises.compactMap { selected in
                guard let card = current[selected.id],
                      promptStyle != .kana || FlashcardStudyPrompt.kana(for: card) != nil,
                      mode != .quiz || FlashcardQuiz.canPractice(card, vocabulary: store.cards) else { return nil }
                return promptStyle.exercise(for: card)
            }
        } else {
            exercises = supplied.map { DailyLessonPlanner.resolve($0, cards: store.cards, materials: suppliedMaterials(), now: now) }
                ?? FlashcardPracticeQueue.exercises(for: due.isEmpty ? candidates : due, now: now,
                    limit: candidates.count, includeFuture: due.isEmpty)
        }
        if mode == .quiz { exercises = exercises.map { FlashcardExercise(card: $0.card, mode: .recognition) } }
        session = FlashcardPracticeSession(exercises: exercises)
        prepareExercise()
    }

    private func prepareExercise() {
        revealed = false
        response = ""
        responseDrawing = nil
        selectedChoice = nil
        quiz = mode == .quiz ? exercise.flatMap { FlashcardQuiz.question(for: $0.card, vocabulary: store.cards) } : nil
        responseFocused = false
        // Input gets focus when tapped; showing a new card never opens a keyboard over it.
        dragOffset = .zero
    }

    private func reveal() {
        guard !revealed else { return }
        responseFocused = false
        handwritingTools.hide()
        revealed = true
        if !incorrectResponse && (selectedChoice != nil || !response.isEmpty) {
            StudyFeedback.shared.play(.correct)
        }
    }

    private func submit(_ requestedRating: FlashcardRating) {
        guard revealed, !submitting, let exercise else { return }
        submitting = true
        let rating: FlashcardRating = incorrectResponse ? .forgot : requestedRating
        Task { @MainActor in
            guard await store.review(id: exercise.id, rating: rating),
                  let updated = store.cards.first(where: { $0.id == exercise.id }) else {
                saveError = store.error ?? "Карточка больше недоступна. Закройте практику и откройте её снова."
                submitting = false
                withAnimation(.spring()) { dragOffset = .zero }
                return
            }
            if reduceMotion || mode == .quiz {
                advance(updated, rating: rating)
            } else {
                withAnimation(.easeIn(duration: 0.18), completionCriteria: .logicallyComplete) {
                    switch requestedRating {
                    case .forgot: dragOffset = CGSize(width: -800, height: 0)
                    case .hard: dragOffset = CGSize(width: 0, height: -1000)
                    case .remembered: dragOffset = CGSize(width: 800, height: 0)
                    }
                } completion: { advance(updated, rating: rating) }
            }
        }
    }

    private func advance(_ card: Flashcard, rating: FlashcardRating) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            session.record(card, rating: rating)
            if session.current == nil && session.initialCount > 0 { StudyFeedback.shared.play(.completion) }
            else if mode == .cards && rating == .remembered && response.isEmpty { StudyFeedback.shared.play(.correct) }
            prepareExercise()
            submitting = false
        }
    }

    private func ratingTitle(_ rating: FlashcardRating) -> String {
        switch rating { case .forgot: "Не помню"; case .hard: "Сложно"; case .remembered: "Помню" }
    }

    private func ratingTint(_ rating: FlashcardRating) -> Color {
        switch rating { case .forgot: .red; case .hard: .orange; case .remembered: Palette.accent }
    }

    private func exerciseTitle(_ exerciseMode: FlashcardExerciseMode) -> String {
        if mode == .quiz { return "Выберите перевод" }
        switch exerciseMode {
        case .recognition: return "Вспомните значение"
        case .production: return "Напишите по-японски"
        case .cloze: return "Заполните пропуск"
        }
    }

    private func exerciseIcon(_ mode: FlashcardExerciseMode) -> String {
        switch mode { case .recognition: "eye"; case .production: "keyboard"; case .cloze: "text.badge.checkmark" }
    }
}

private struct FlashcardStudySetupView: View {
    let store: FlashcardStore
    let mode: FlashcardPracticeMode
    let onStart: ([FlashcardExercise], Bool, FlashcardStudyPrompt) -> Void
    @State private var scope: FlashcardStudyScope = .new
    @State private var useRange = false
    @State private var first = "1"
    @State private var last = ""
    @State private var browseFirst = true
    @State private var prompt: FlashcardStudyPrompt = .kana
    @State private var initialized = false

    private var eligible: [Flashcard] {
        store.cards.filter { mode == .cards || FlashcardQuiz.canPractice($0, vocabulary: store.cards) }
    }
    private var selection: FlashcardStudySelection {
        FlashcardStudySelection(scope: scope, first: useRange ? Int(first) ?? 0 : 1,
                                last: useRange ? Int(last) ?? 0 : nil)
    }
    private var candidates: [Flashcard] { selection.candidates(in: eligible) }
    private var selected: [Flashcard] { selection.cards(in: eligible) }
    private var missingKana: Int { selected.filter { FlashcardStudyPrompt.kana(for: $0) == nil }.count }
    private var canStart: Bool {
        !store.isBlocked && !selected.isEmpty && (mode == .quiz || prompt != .kana || missingKana == 0)
    }

    var body: some View {
        Form {
            Section {
                Picker("Какие слова", selection: $scope) {
                    ForEach(FlashcardStudyScope.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("study-word-scope")
                Text("Новые — слова, на которые вы ещё не отвечали. Просмотр карточек не меняет прогресс.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Выбрать весь список", isOn: Binding(get: { !useRange }, set: { useRange = !$0 }))
                    .accessibilityIdentifier("study-entire-list")
                if useRange {
                    rangeField("От слова", text: $first, identifier: "study-range-first")
                    rangeField("До слова включительно", text: $last, identifier: "study-range-last")
                }
                Text("Доступно слов: \(candidates.count)")
                    .accessibilityIdentifier("study-available-count")
                if useRange, selected.isEmpty, !candidates.isEmpty {
                    Text("Укажите диапазон от 1 до \(candidates.count). Конец не должен быть раньше начала.")
                        .foregroundStyle(.red).accessibilityIdentifier("study-range-error")
                }
                if candidates.isEmpty {
                    Text("В этом списке нет слов. Выберите другой список или добавьте карточки.")
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Объём занятия") } footer: {
                Text("Номера идут по порядку добавления внутри выбранного списка. Лимита в 20 слов нет.")
            }
            if mode == .cards {
                Section("Как заниматься") {
                    Picker("Начало занятия", selection: $browseFirst) {
                        Text("Сначала карточки").tag(true)
                        Text("Сразу проверка").tag(false)
                    }
                    .accessibilityIdentifier("study-workflow")
                    Picker("В проверке", selection: $prompt) {
                        ForEach(FlashcardStudyPrompt.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("study-prompt-style")
                    Text(prompt == .mixed
                         ? "Чередование слова, перевода и пропуска в примере."
                         : "Вспомните значение. Чтение, перевод и примеры появятся только после «Показать ответ».")
                        .font(.caption).foregroundStyle(.secondary)
                    if prompt == .kana, missingKana > 0 {
                        Text("Без записи каной: \(missingKana). Добавьте чтение каной в карточки или выберите «Слово».")
                            .font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("study-missing-kana")
                    }
                }
            }
            Section("Выбранные слова") {
                if let card = selected.first {
                    boundary(card, number: useRange ? Int(first) ?? 1 : 1)
                }
                if selected.count > 1, let card = selected.last {
                    boundary(card, number: useRange ? Int(last) ?? selected.count : selected.count)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Text("Слов в сессии: \(selected.count)").font(.headline)
                    .accessibilityIdentifier("study-selected-count")
                Button(mode == .cards && browseFirst ? "Начать с карточек" : "Начать проверку") {
                    guard canStart else { return }
                    let style: FlashcardStudyPrompt = mode == .quiz ? .word : prompt
                    onStart(selected.map { style.exercise(for: $0) }, mode == .cards && browseFirst, style)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!canStart).accessibilityIdentifier("study-start-selection")
            }
            .frame(maxWidth: .infinity).padding().background(Palette.background)
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if !eligible.contains(where: { $0.reviewCount == 0 }) { scope = .all }
            if missingKana > 0 { prompt = .word }
        }
        .onChange(of: scope) { _, _ in first = "1"; last = String(candidates.count) }
        .onChange(of: useRange) { _, enabled in
            if enabled { first = "1"; last = String(candidates.count) }
        }
    }

    private func rangeField(_ title: LocalizedStringKey, text: Binding<String>, identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("Номер", text: text)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                .frame(maxWidth: 100).accessibilityLabel(title).accessibilityIdentifier(identifier)
        }
    }

    private func boundary(_ card: Flashcard, number: Int) -> some View {
        HStack {
            Text("№ \(number)").font(.caption).foregroundStyle(.secondary)
            FlashcardFieldContent(text: card.japanese, drawing: card.handwriting?.japanese, maxHeight: 36)
            Spacer()
            FlashcardFieldContent(text: card.translation, drawing: card.handwriting?.translation, maxHeight: 36)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FlashcardBrowseView: View {
    @State var session: FlashcardBrowseSession
    let onPractice: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Карточка \(session.index + 1) из \(session.exercises.count)")
                .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("study-browse-progress")
            ScrollView {
                if let card = session.current?.card {
                    VStack(spacing: 20) {
                        FlashcardFieldContent(text: card.japanese, drawing: card.handwriting?.japanese, maxHeight: 150)
                            .font(.largeTitle).accessibilityIdentifier("study-browse-word")
                        FlashcardFieldContent(text: card.reading, drawing: card.handwriting?.reading, maxHeight: 90)
                            .font(.title3).foregroundStyle(.secondary)
                        Divider()
                        FlashcardFieldContent(text: card.translation, drawing: card.handwriting?.translation, maxHeight: 150)
                            .font(.title2).accessibilityIdentifier("study-browse-translation")
                        if !card.example.isEmpty { Text(card.example) }
                        if !card.note.isEmpty { Text(card.note).foregroundStyle(.secondary) }
                    }
                    .multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, minHeight: 300)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 26))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                        guard abs(value.translation.width) > 60,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        session.move(value.translation.width < 0 ? 1 : -1)
                    })
                }
            }
            Text("Листайте в обе стороны. Просмотр не меняет прогресс изучения.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 620).frame(maxWidth: .infinity).padding(24)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                HStack {
                    Button("Назад", systemImage: "arrow.left") { session.move(-1) }
                        .disabled(!session.canGoBack).accessibilityIdentifier("study-browse-back")
                    Spacer()
                    Button("Дальше", systemImage: "arrow.right") { session.move(1) }
                        .disabled(!session.canGoForward).accessibilityIdentifier("study-browse-next")
                }
                .buttonStyle(.bordered)
                Button("Перейти к проверке", action: onPractice)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("study-browse-practice")
            }
            .frame(maxWidth: 620).frame(maxWidth: .infinity).padding(24).background(Palette.background)
        }
    }
}
