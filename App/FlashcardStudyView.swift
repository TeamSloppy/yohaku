import SwiftUI

struct FlashcardStudyView: View {
    @Bindable var store: FlashcardStore
    let mode: FlashcardPracticeMode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var session = FlashcardPracticeSession()
    @State private var started = false
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
                if let exercise {
                    VStack(spacing: 12) {
                        progress
                        cardDeck(exercise)
                            .padding(.horizontal, 24).padding(.top, 16)
                        ScrollView {
                            VStack(spacing: 20) {
                                if !revealed { responseInput(exercise) }
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
                    .safeAreaInset(edge: .bottom) { controls(exercise).padding(16).background(Palette.background) }
                } else {
                    completion
                }
            }
            .background(Palette.background)
            .safeAreaPadding(.bottom, handwritingTools.bottomInset)
            .navigationTitle(mode.title)
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
            FlashcardFieldContent(text: exercise.prompt, drawing: exercise.promptHandwriting, maxHeight: 130)
                .font(.system(size: 42, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("study-prompt")
            if revealed {
                Divider()
                if exercise.mode != .recognition {
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
                Button("Дальше", systemImage: "arrow.right") { submit(incorrectResponse ? .forgot : .remembered) }
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
        ContentUnavailableView {
            Label("Повторение завершено", systemImage: "checkmark.circle")
                .accessibilityIdentifier("study-complete")
        } description: {
            Text("Карточек: \(session.initialCount) · ответов: \(session.attemptCount)")
            Text(session.mistakes.isEmpty ? "Все карточки пройдены" : "Ещё требуют внимания: \(session.remainingMistakeCount). Они остаются к повторению.")
        } actions: {
            if !session.mistakes.isEmpty {
                Button("Повторить ошибки") { session.repeatMistakes(); prepareExercise() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("study-repeat-mistakes")
            }
            Button("Закрыть") { dismiss() }.buttonStyle(.bordered)
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
        guard !started else { return }
        started = true
        let candidates = store.dueCards.filter { mode == .cards || FlashcardQuiz.canPractice($0, vocabulary: store.cards) }
        var exercises = FlashcardPracticeQueue.exercises(for: candidates)
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
        responseFocused = false
        handwritingTools.hide()
        revealed = true
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
