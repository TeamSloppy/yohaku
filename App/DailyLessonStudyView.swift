import SwiftUI

struct DailyLessonStudyView: View {
    @Bindable var workspace: WorkspaceModel
    let lessonID: UUID
    let context: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = false
    @State private var response = ""
    @State private var phraseChoice: FlashcardQuizChoice?
    @State private var responseDrawing: Data?
    @State private var tools = FlashcardDrawingTools()
    @State private var submitting = false
    @State private var error: String?
    @FocusState private var responseFocused: Bool
    private var lesson: DailyLessonState? { workspace.materials.lesson.flatMap { $0.id == lessonID ? $0 : nil } }
    private var current: Bool { workspace.dailyLessonContext == context && workspace.dailyLessonVaultReady }
    private var saving: Bool { submitting || (workspace.materials.state.lessonIntent != nil && workspace.materials.error == nil) }
    private var blocked: Bool { workspace.materials.isBlocked || workspace.flashcards.isBlocked || workspace.flashcards.error != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let lesson, current {
                        if let step = lesson.current {
                            Text("\(lesson.outcomes.count + 1) из \(lesson.steps.count)").accessibilityIdentifier("daily-lesson-progress")
                            ProgressView(value: Double(lesson.outcomes.count), total: Double(lesson.steps.count))
                            question(step)
                            if let explanation = lesson.outcomes.last?.kind.lessonExplanation { Text(explanation).foregroundStyle(.orange).accessibilityIdentifier("daily-lesson-skipped") }
                            if saving { ProgressView("Сохранение ответа…").accessibilityIdentifier("daily-lesson-saving") }
                            else if blocked { DailyLessonRecoveryControls(workspace: workspace, context: context) }
                            else { controls(step) }
                        } else {
                            StudyCelebrationView(title: "Занятие завершено",
                                detail: "Оценено: \(lesson.outcomes.filter { $0.kind == .reviewed }.count) · пропущено: \(lesson.outcomes.filter { $0.kind != .reviewed }.count)")
                            ExtraPracticeEntry(workspace: workspace, identifier: "daily-extra-practice")
                            ForEach(lesson.outcomes, id: \.stepID) { outcome in
                                if let explanation = outcome.kind.lessonExplanation { Text(explanation).foregroundStyle(.secondary) }
                            }
                        }
                    } else { Text("Хранилище изменилось. Откройте сохранённое занятие заново.") }
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("daily-lesson-error") }
                }
                .frame(maxWidth: 620).frame(maxWidth: .infinity).padding(24)
            }
            .background(Palette.background).safeAreaPadding(.bottom, tools.bottomInset)
            .navigationTitle("Занятие").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { tools.hide(); dismiss() } } }
            .onChange(of: lesson?.current?.id) { _, _ in revealed = false; response = ""; phraseChoice = nil; responseDrawing = nil; error = nil; tools.hide() }
            .onChange(of: workspace.dailyLessonContext) { _, _ in tools.hide(); dismiss() }
            .onDisappear { tools.hide() }
        }
    }

    private func question(_ step: DailyLessonStep) -> some View {
        VStack(spacing: 16) {
            let quiz = step.card.phrasePractice?.question(for: step.card)
            Text(quiz != nil ? "Выберите перевод фразы" : step.mode == .recognition ? "Вспомните значение" : step.mode == .production ? "Напишите по-японски" : "Заполните пропуск")
                .font(.caption).foregroundStyle(.secondary)
            FlashcardFieldContent(text: step.exercise.prompt, drawing: step.exercise.promptHandwriting, maxHeight: 150)
                .font(.largeTitle).accessibilityIdentifier("study-prompt")
            Text(step.reason).font(.caption).foregroundStyle(.secondary)
            if revealed {
                if let quiz, let phraseChoice {
                    Label(quiz.isCorrect(phraseChoice) ? "Верно" : "Правильный ответ: " + quiz.correctAnswer,
                        systemImage: quiz.isCorrect(phraseChoice) ? "checkmark.circle" : "arrow.counterclockwise.circle")
                        .foregroundStyle(quiz.isCorrect(phraseChoice) ? Palette.accent : .orange).accessibilityIdentifier("phrase-feedback")
                    Text(step.card.phrasePractice!.words.map { $0.japanese + " — " + $0.translation }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if responseDrawing != nil || !response.isEmpty {
                    Text("Ваш ответ").font(.caption)
                    if let responseDrawing {
                        FlashcardFieldContent(text: "", drawing: responseDrawing, maxHeight: 90).accessibilityIdentifier("daily-lesson-own-ink")
                    } else { Text(response).accessibilityIdentifier("daily-lesson-own-response") }
                }
                if step.mode != .recognition, !response.isEmpty, !FlashcardAnswer.matches(response, card: step.card) {
                    Text("Ответ не совпал. Оценка: «Не помню».").font(.caption).foregroundStyle(.orange)
                }
                if quiz == nil { FlashcardFieldContent(text: step.card.japanese, drawing: step.card.handwriting?.japanese) }
                FlashcardFieldContent(text: step.card.reading, drawing: step.card.handwriting?.reading)
                if quiz == nil { FlashcardFieldContent(text: step.card.translation, drawing: step.card.handwriting?.translation) }
                if !step.card.example.isEmpty {
                    Text(step.source == nil ? "Пример" : "Придуманный пример").font(.caption)
                    Text(step.card.example)
                }
                if !step.card.note.isEmpty { Text(step.card.note) }
                if let source = step.source {
                    Text("Из записи: \(source.path)").font(.caption)
                    Text(source.origin?.label ?? "Цитата источника").font(.caption)
                    Text(source.quote).font(.caption)
                }
                else {
                    if let path = step.card.sourcePath { Text("Из записи: \(path)").font(.caption) }
                    if let excerpt = step.card.sourceExcerpt {
                        Text(step.card.sourceTextOrigin?.label ?? "Цитата источника").font(.caption)
                        Text(excerpt).font(.caption)
                    }
                }
            } else if let quiz {
                ForEach(Array(quiz.choices.enumerated()), id: \.element.id) { index, choice in
                    Button {
                        phraseChoice = choice; revealed = true
                        if quiz.isCorrect(choice) { StudyFeedback.shared.play(.correct) }
                    } label: {
                        HStack { Text(choice.text); Spacer(); Image(systemName: "circle") }.padding(14).frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(Palette.background, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("phrase-choice-\(index)")
                }
            } else if step.mode != .recognition {
                if step.card.handwriting?.japanese != nil {
                    FlashcardHandwritingField(title: "Напишите по памяти", identifier: "study-ink-response", drawing: $responseDrawing, tools: tools)
                } else {
                    TextField("Введите ответ по-японски", text: $response, axis: .vertical)
                        .focused($responseFocused).textFieldStyle(.roundedBorder).accessibilityIdentifier("study-response")
                }
            }
        }
        .multilineTextAlignment(.center).padding(20).frame(maxWidth: .infinity)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private func controls(_ step: DailyLessonStep) -> some View {
        if let quiz = step.card.phrasePractice?.question(for: step.card) {
            if let phraseChoice {
                Button("Далее") { submit(quiz.isCorrect(phraseChoice) ? .remembered : .forgot, step: step) }
                    .buttonStyle(.borderedProminent).disabled(submitting).accessibilityIdentifier("phrase-next")
            }
        } else if revealed {
            HStack {
                ratingButton(.forgot, title: "Не помню", step: step)
                ratingButton(.hard, title: "Сложно", step: step)
                ratingButton(.remembered, title: "Помню", step: step)
            }.disabled(submitting)
        } else {
            Button(step.mode == .recognition ? "Показать ответ" : "Проверить") { tools.hide(); responseFocused = false; revealed = true }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("reveal-flashcard")
        }
        Text("Одна итоговая оценка на карточку. Незавершённый ввод не сохраняется.").font(.caption).foregroundStyle(.secondary)
    }
    private func ratingButton(_ rating: FlashcardRating, title: String, step: DailyLessonStep) -> some View {
        Button(title) { submit(rating, step: step) }.buttonStyle(.bordered).accessibilityIdentifier("rate-flashcard-\(title)")
    }
    private func submit(_ rating: FlashcardRating, step: DailyLessonStep) {
        guard current, !submitting else { return }
        submitting = true; error = nil
        let actual: FlashcardRating = step.mode != .recognition && !response.isEmpty && !FlashcardAnswer.matches(response, card: step.card) ? .forgot : rating
        let answeredPhrase = phraseChoice != nil
        Task { @MainActor in
            let valid: @MainActor @Sendable () -> Bool = { workspace.dailyLessonContext == context && workspace.dailyLessonVaultReady }
            do {
                let saved = try await workspace.materials.submitLessonStep(lessonID: lessonID, stepID: step.id, rating: actual, cards: workspace.flashcards, ifCurrent: valid)
                if valid() {
                    if saved.isComplete { StudyFeedback.shared.play(.completion) }
                    else if actual == .remembered && !answeredPhrase && saved.outcomes.last?.kind == .reviewed { StudyFeedback.shared.play(.correct) }
                }
            }
            catch let failure { if valid() { error = failure.localizedDescription } }
            if valid() { submitting = false }
        }
    }
}

struct DailyLessonRecoveryControls: View {
    @Bindable var workspace: WorkspaceModel
    let context: UUID
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 12) {
            Text(error ?? workspace.flashcards.error ?? workspace.materials.error ?? "Загрузите сохранённые данные перед продолжением.")
                .foregroundStyle(.orange)
            Button("Загрузить сохранённую версию") { perform(skip: false) }.accessibilityIdentifier("today-recover")
            if workspace.materials.canSkipUnconfirmedLesson {
                Button("Продолжить без повторной оценки") { perform(skip: true) }.accessibilityIdentifier("lesson-skip-unconfirmed")
                Text("Эта оценка не будет применена повторно; шаг отметится как неподтверждённый.").font(.caption)
            }
        }.buttonStyle(.bordered).disabled(busy)
    }
    private func perform(skip: Bool) {
        let valid: @MainActor @Sendable () -> Bool = { workspace.dailyLessonContext == context && workspace.dailyLessonVaultReady }
        guard valid(), !busy,
              !(workspace.materials.state.lessonIntent != nil && workspace.materials.error == nil),
              !skip || workspace.materials.canSkipUnconfirmedLesson else { return }
        busy = true; error = nil
        Task { @MainActor in
            if skip, let lesson = workspace.materials.lesson, let step = lesson.current {
                do { try await workspace.materials.skipUnconfirmedLesson(lessonID: lesson.id, stepID: step.id, cards: workspace.flashcards, ifCurrent: valid) }
                catch let failure { if valid() { error = failure.localizedDescription } }
            } else { await workspace.recoverDailyLesson(context: context) }
            if valid() { busy = false }
        }
    }
}

private extension DailyLessonOutcome.Kind {
    var lessonExplanation: String? {
        switch self {
        case .reviewed: nil
        case .deleted: "Карточка удалена. Шаг пропущен без оценки."
        case .edited: "Карточка изменена. Шаг пропущен без оценки старого задания."
        case .unconfirmed: "Сохранение оценки не подтверждено. Повторная оценка не применялась."
        }
    }
}
