import SwiftUI

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
    @State private var saving = false
    @State private var notice: String?
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
                .onChange(of: workspace.dailyLessonDuration) { _, _ in refresh() }
                .onChange(of: workspace.dailyLessonContext) { _, _ in dismiss() }
                .onChange(of: store.state.session?.current?.id) { _, _ in revealed = false; response = "" }
        }
    }
    private var selection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Время", selection: $workspace.dailyLessonDuration) {
                ForEach(DailyLessonDuration.allCases) { Text("\($0.rawValue) мин").tag($0) }
            }.pickerStyle(.segmented)
            if preview.isEmpty {
                Text("Пока нет изученных слов. Пройдите первое занятие или добавьте материалы в библиотеку.")
            } else {
                Text("В подборке: \(preview.count)").font(.headline)
                ForEach(preview) { step in
                    HStack { Text(step.card.japanese); Spacer(); Text(step.reason).font(.caption).foregroundStyle(.secondary) }
                }
                Button("Начать дополнительное занятие") {
                    perform { try await store.start(preview, duration: workspace.dailyLessonDuration, ifCurrent: { current }) }
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("extra-start")
                Button("Другая подборка") { refresh() }.buttonStyle(.bordered)
            }
        }.disabled(saving || !current || workspace.flashcards.isBlocked || workspace.materials.isBlocked)
    }
    private func exercise(_ session: LearningSession, _ step: LearningStep) -> some View {
        VStack(spacing: 18) {
            Text("\(session.answers.count + 1) из \(session.steps.count)").accessibilityIdentifier("extra-progress")
            ProgressView(value: Double(session.answers.count), total: Double(session.steps.count))
            if let card = workspace.flashcards.cards.first(where: { $0.id == step.card.id }), StudyMaterialFields(card) == StudyMaterialFields(step.card) {
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
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard current, !saving else { return }
        saving = true; notice = nil
        Task { @MainActor in
            do { try await operation() } catch { if current { notice = error.localizedDescription } }
            if current { saving = false }
        }
    }
}
