import SwiftUI
import StudyIntelligence

struct ExtraPracticeEntry: View {
    @Bindable var workspace: WorkspaceModel
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            Label(workspace.learning.state.session?.isComplete == false ? "Продолжить дополнительное занятие" : "Ещё попрактиковаться",
                  systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
        }
        .buttonStyle(.bordered).accessibilityIdentifier("extra-practice")
        .sheet(isPresented: $presented) { ExtraPracticeView(workspace: workspace, context: workspace.dailyLessonContext) }
    }
}

struct ExtraPracticeView: View {
    @Bindable var workspace: WorkspaceModel
    let context: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var preview: [LearningStep] = []
    @State private var revealed = false
    @State private var response = ""
    @State private var readingChoice: String?
    @State private var saving = false
    @State private var notice: String?
    @State private var generation: Task<Void, Never>?
    @State private var generationID = UUID()
    @State private var generating = false
    private var store: LearningStore { workspace.learning }
    private var current: Bool { workspace.dailyLessonVaultReady && workspace.dailyLessonContext == context }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Закрепим изученное").font(.largeTitle).fontDesign(.serif)
                    Text("Дополнительная практика не переносит сроки повторения карточек.").font(.callout).foregroundStyle(.secondary)
                    if let notice { Text(notice).foregroundStyle(.orange).accessibilityIdentifier("extra-error") }
                    if store.blocked {
                        Text(store.error ?? "Загрузка практики…").foregroundStyle(.orange)
                        Button("Загрузить сохранённую версию") { Task { await store.recover() } }
                    } else if let session = store.state.session, !session.isComplete, let step = session.current {
                        exercise(session, step)
                    } else {
                        if store.state.session?.isComplete == true {
                            Label("Занятие завершено", systemImage: "checkmark.circle").accessibilityIdentifier("extra-complete")
                        }
                        selection
                    }
                }.padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.background(Palette.background)
                .navigationTitle("Дополнительная практика").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
                .task { refresh() }
                .onChange(of: workspace.dailyLessonDuration) { _, _ in cancelGeneration(); refresh() }
                .onChange(of: workspace.dailyLessonContext) { _, _ in dismiss() }
                .onChange(of: workspace.agent.configuration) { _, _ in cancelGeneration(); refresh() }
                .onDisappear { cancelGeneration() }
                .onChange(of: store.state.session?.current?.id) { _, _ in revealed = false; response = ""; readingChoice = nil }
        }
    }
    private var selection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Время", selection: $workspace.dailyLessonDuration) {
                ForEach(DailyLessonDuration.allCases) { Text("\($0.rawValue) мин").tag($0) }
            }.pickerStyle(.segmented)
            if generating {
                ProgressView("Агент составляет упражнения…")
                Button("Отменить подготовку") { cancelGeneration() }.accessibilityIdentifier("extra-cancel-generation")
            } else {
                Button("Собрать занятие агентом") { generate() }
                    .buttonStyle(.borderedProminent).disabled(saving || workspace.agent.running)
                    .accessibilityIdentifier("extra-generate")
                Text("Используется модель из настроек. Перед началом вы увидите подборку.").font(.caption).foregroundStyle(.secondary)
            }
            if preview.isEmpty {
                Text("Пока нет изученных слов. Пройдите первое занятие или добавьте материалы в библиотеку.")
                CourseEntry(workspace: workspace)
            } else {
                Text("В подборке: \(preview.count)").font(.headline)
                ForEach(preview) { step in
                    HStack { Text(step.card.japanese); Spacer(); Text(step.reason).font(.caption).foregroundStyle(.secondary) }
                }
                Button("Начать дополнительное занятие") {
                    perform { try await store.start(preview, duration: workspace.dailyLessonDuration, ifCurrent: { current }) }
                }.buttonStyle(.borderedProminent).disabled(generating).accessibilityIdentifier("extra-start")
                Button("Готовые упражнения без генерации") { cancelGeneration(); refresh() }.buttonStyle(.bordered)
            }
        }.disabled(saving || !current || workspace.flashcards.isBlocked || workspace.materials.isBlocked)
    }
    private func exercise(_ session: LearningSession, _ step: LearningStep) -> some View {
        VStack(spacing: 18) {
            Text("\(session.answers.count + 1) из \(session.steps.count)").accessibilityIdentifier("extra-progress")
            ProgressView(value: Double(session.answers.count), total: Double(session.steps.count))
            if step.available(in: workspace.flashcards.cards), let reading = step.reading {
                Text("Прочитайте фрагмент").font(.caption)
                Text(reading.passage).font(.title).accessibilityIdentifier("extra-reading")
                Text(reading.question)
                if let readingChoice {
                    Label(readingChoice == reading.answer ? "Верно" : "Правильный ответ: " + reading.answer,
                          systemImage: readingChoice == reading.answer ? "checkmark.circle" : "arrow.counterclockwise")
                    Button("Далее") {
                        response = readingChoice
                        submit(session, step, readingChoice == reading.answer ? .remembered : .forgot)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("extra-reading-next")
                } else {
                    ForEach(Array(reading.choices.enumerated()), id: \.offset) { index, choice in
                        Button(choice) { readingChoice = choice }.buttonStyle(.bordered)
                            .accessibilityIdentifier("extra-reading-choice-\(index)")
                    }
                }
            } else if step.available(in: workspace.flashcards.cards) {
                Text(step.mode == .recognition ? "Вспомните значение" : "Напишите по-японски").font(.caption)
                FlashcardFieldContent(text: step.exercise.prompt, drawing: step.exercise.promptHandwriting).font(.largeTitle)
                    .accessibilityIdentifier("extra-prompt")
                if revealed {
                    Text(step.card.japanese).font(.title)
                    Text(step.card.reading)
                    Text(step.card.translation)
                    if !response.isEmpty { Text("Ваш ответ: " + response) }
                    ForEach([FlashcardRating.forgot, .hard, .remembered], id: \.rawValue) { rating in
                        Button(rating == .forgot ? "Не помню" : rating == .hard ? "Сложно" : "Помню") {
                            let actual: FlashcardRating = step.mode != .recognition && !response.isEmpty && !FlashcardAnswer.matches(response, card: step.card) ? .forgot : rating
                            submit(session, step, actual)
                        }.buttonStyle(.bordered).accessibilityIdentifier("extra-rate-" + rating.rawValue)
                    }
                } else {
                    if step.mode != .recognition {
                        TextField("Ответ по-японски", text: $response).textFieldStyle(.roundedBorder).accessibilityIdentifier("extra-response")
                    }
                    Button("Показать ответ") { revealed = true }.buttonStyle(.borderedProminent).accessibilityIdentifier("extra-reveal")
                }
            } else {
                Text("Карточка изменена или удалена. Пропустите старое упражнение.")
                Button("Пропустить") { submit(session, step, .forgot, skipped: true) }
            }
            if saving { ProgressView("Сохраняем ответ…") }
        }.frame(maxWidth: .infinity).disabled(saving || !current || workspace.flashcards.isBlocked)
    }
    private func submit(_ session: LearningSession, _ step: LearningStep, _ rating: FlashcardRating, skipped: Bool = false) {
        perform {
            try await store.answer(sessionID: session.id, stepID: step.id, rating: rating, response: response, skipped: skipped, ifCurrent: { current })
            refresh()
        }
    }
    private func refresh() {
        guard current else { return }
        preview = ExtraPracticePlanner.plan(cards: workspace.flashcards.cards, materials: workspace.materials.records,
                                             state: store.state, duration: workspace.dailyLessonDuration)
    }
    private func cancelGeneration() {
        generationID = UUID(); generation?.cancel(); generation = nil; generating = false
    }
    private func generate() {
        guard current, !generating, !saving, !workspace.agent.running else { return }
        refresh()
        let base = preview, cards = base.map(\.card), words = PracticeGeneration.words(cards, trained: store.state.course?.trained ?? [])
        guard words.count >= 2 else { notice = "Для новых фраз нужны хотя бы два изученных слова. Можно начать готовые упражнения."; return }
        let id = UUID(), configuration = workspace.agent.configuration, duration = workspace.dailyLessonDuration
        generationID = id; generating = true; notice = nil
        generation = Task { @MainActor in
            defer { if generationID == id { generating = false; generation = nil } }
            do {
                let phrases: [ComposedPhrase]
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--learning-fixture") {
                    let json = "[{\"wordIDs\":[\"\(words[0].id)\",\"\(words[1].id)\"],\"between\":[\"\"],\"translation\":\"Большой дом\",\"alternatives\":[\"Маленький дом\",\"Большой сад\",\"Маленький сад\"],\"explanation\":\"Из знакомых слов.\"}]"
                    phrases = try PhraseComposition.parse(json, words: words, kana: [], allowedParticles: [])
                } else {
                    phrases = try await workspace.agent.composePhrases(words: words, kana: workspace.learningProfile.knownKana,
                        allowedParticles: PracticeGeneration.particles(workspace.flashcards.cards))
                }
                #else
                phrases = try await workspace.agent.composePhrases(words: words, kana: workspace.learningProfile.knownKana,
                    allowedParticles: PracticeGeneration.particles(workspace.flashcards.cards))
                #endif
                try Task.checkCancellation()
                guard current, generationID == id, workspace.agent.configuration == configuration,
                      workspace.dailyLessonDuration == duration, base.allSatisfy({ $0.available(in: workspace.flashcards.cards) }) else { return }
                let generated = try PracticeGeneration.steps(phrases, cards: cards, kana: workspace.learningProfile.knownKana)
                guard !generated.isEmpty else { throw ModelConnectionError.message("Не удалось собрать подходящие упражнения. Попробуйте ещё раз или откройте готовые.") }
                preview = Array(((PracticeGeneration.reading(generated).map { [$0] } ?? []) + generated + base).prefix(duration.capacity))
            } catch is CancellationError { }
            catch { if current, generationID == id { notice = error.localizedDescription } }
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard current, !saving else { return }
        saving = true; notice = nil
        Task { @MainActor in
            do { try await operation() } catch { if current { notice = error.localizedDescription } }
            if current { saving = false }
        }
    }
}
