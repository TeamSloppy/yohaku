import SwiftUI

struct CourseSessionView: View {
    @Bindable var workspace: WorkspaceModel
    let context: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var response = ""
    @State private var accepted: [[KanaPoint]] = []
    @State private var rejected: [KanaPoint] = []
    @State private var writingFailed = false
    @State private var feedback: String?
    @State private var resetID = UUID()
    @State private var busy = false
    @State private var notice: String?
    @State private var evaluation: FlashcardRating?
    @State private var readingRevealed = false
    private var session: LearningSession? { workspace.learning.state.courseSession }
    private var current: Bool { workspace.dailyLessonContext == context && workspace.dailyLessonVaultReady }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let session, let step = session.current, let task = step.courseTask {
                        Text("\(session.answers.count + 1) из \(session.steps.count)").accessibilityIdentifier("course-progress")
                        ProgressView(value: Double(session.answers.count), total: Double(session.steps.count))
                        activity(step, task, checkpoint: session.course?.checkpoint == true)
                            .disabled(busy || !current || workspace.learning.blocked)
                    } else if let session, session.isComplete {
                        Label("Занятие завершено", systemImage: "checkmark.circle").font(.title).accessibilityIdentifier("course-complete")
                        if let check = CourseCatalog.checkpoint(session, now: session.completedAt ?? Date()) {
                            Text(check.passed ? "Тема пройдена. Следующая открыта." : "Вернитесь к тренировке ошибок и повторите проверку.")
                            ForEach(CourseSkill.allCases, id: \.rawValue) { skill in
                                if let score = check.scores[skill] { Text("\(title(skill)): \(Int(score * 100))%") }
                            }
                        } else { Text("Продолжайте тему, затем пройдите проверку без подсказок.") }
                        Button("К программе") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                    if let notice { Text(notice).foregroundStyle(.orange) }
                    if workspace.learning.blocked {
                        Button("Загрузить сохранённую версию") { Task { guard current else { return }; await workspace.learning.recover() } }
                            .disabled(busy || !current)
                    }
                }.padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }.background(Palette.background)
                .navigationTitle(session?.course?.checkpoint == true ? "Проверка без подсказок" : "Урок")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
                .onChange(of: session?.current?.id) { _, _ in
                    response = ""; accepted = []; rejected = []; writingFailed = false; feedback = nil; evaluation = nil; readingRevealed = false; resetID = UUID()
                }
                .onChange(of: workspace.dailyLessonContext) { _, _ in dismiss() }
        }
    }
    @ViewBuilder private func activity(_ step: LearningStep, _ task: CourseTask, checkpoint: Bool) -> some View {
        switch task.phase {
        case .explanation:
            Text(step.card.japanese).font(.system(size: 64))
            Text(step.card.reading).font(.title)
            Text(step.card.translation)
            Text(task.glyph == nil ? "Прочитайте слово и запомните значение." : "Посмотрите на форму. Далее — обводка, затем письмо по памяти.")
            Button("Продолжить") { submit(step, .remembered) }.buttonStyle(.borderedProminent).accessibilityIdentifier("course-next")
        case .trace, .recall:
            if let glyph = task.glyph {
                Text(task.phase == .trace ? "Обведите знак" : "Напишите по памяти").font(.headline)
                Text(step.card.reading).font(.largeTitle).accessibilityIdentifier("course-writing-reading")
                if !step.card.note.isEmpty { Text(step.card.note).font(.caption) }
                KanaTracingBoard(glyph: glyph, accepted: accepted, rejected: rejected, resetID: resetID,
                    showsGuide: task.phase == .trace, spokenReading: step.card.reading) { points in
                    guard accepted.count < glyph.strokes.count else { return }
                    let result = KanaStrokeMatcher.evaluate(points, against: glyph.strokes[accepted.count])
                    if result == .accepted { accepted.append(points); rejected = [] }
                    else {
                        rejected = points
                        if checkpoint, !writingFailed { persistWritingFailure(step) }
                        writingFailed = true
                    }
                    feedback = checkpoint && result != .accepted ? "Штрих не принят. Можно закончить попытку или пропустить." : result.message
                }.frame(maxWidth: 400).frame(height: 320)
                Text(feedback ?? "Пишите пальцем или Apple Pencil").accessibilityIdentifier("course-writing-feedback")
                Button("Готово") { submit(step, checkpoint && writingFailed ? .forgot : .remembered) }
                    .buttonStyle(.borderedProminent).disabled(accepted.count != glyph.strokes.count).accessibilityIdentifier("course-writing-next")
                Button("Не помню") { submit(step, .forgot) }.accessibilityIdentifier("course-forgot")
            }
        case .recognition, .production:
            Text(task.phase == .recognition ? step.card.japanese : step.card.translation).font(.largeTitle).accessibilityIdentifier("course-prompt")
            Text(task.phase == .recognition ? (task.glyph?.alphabet == nil ? "Введите изученное чтение каной" : "Введите звучание в ромадзи") : "Напишите изученное выражение по-японски")
            TextField("Ответ", text: $response).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never)
                .autocorrectionDisabled().disabled(evaluation != nil).accessibilityIdentifier("course-response")
            if let evaluation {
                Text(evaluation == .remembered ? "Верно" : "Правильный ответ: " + (task.phase == .recognition ? step.card.reading : step.card.japanese))
                Button("Далее") { submit(step, evaluation) }.buttonStyle(.borderedProminent).accessibilityIdentifier("course-answer-next")
            } else { Button("Ответить") {
                let expected = task.phase == .recognition ? step.card.reading : step.card.japanese
                let answers = [expected] + (task.phase == .recognition ? task.readingAlternatives ?? [] : [])
                let rating: FlashcardRating = answers.contains { CourseAnswer.matches(response, expected: $0, reading: task.phase == .recognition) } ? .remembered : .forgot
                if checkpoint { submit(step, rating) } else { evaluation = rating }
            }.buttonStyle(.borderedProminent).disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("course-answer")
            }
            Button("Не помню") { submit(step, .forgot) }.accessibilityIdentifier("course-forgot")
        case .reading:
            Text(step.card.japanese).font(.title).accessibilityIdentifier("course-reading")
            if readingRevealed { Text(step.card.translation) }
            else { Button("Показать перевод") { readingRevealed = true }.accessibilityIdentifier("course-reading-translation") }
            Button("Прочитано") { submit(step, .remembered) }.buttonStyle(.borderedProminent).accessibilityIdentifier("course-reading-next")
        }
    }
    private func title(_ skill: CourseSkill) -> String {
        switch skill { case .reading: "Чтение"; case .writing: "Письмо"; case .usage: "Применение" }
    }
    private func persistWritingFailure(_ step: LearningStep) {
        guard let session else { return }
        busy = true
        Task { @MainActor in
            do { try await workspace.learning.flagCourseFailure(sessionID: session.id, stepID: step.id, ifCurrent: { current }) }
            catch { if current { notice = error.localizedDescription } }
            if current { busy = false }
        }
    }
    private func submit(_ step: LearningStep, _ rating: FlashcardRating) {
        guard current, !busy, let session else { return }
        busy = true; notice = nil
        Task { @MainActor in
            do { try await workspace.learning.answerCourse(sessionID: session.id, stepID: step.id, rating: rating, response: response, ifCurrent: { current }) }
            catch { if current { notice = error.localizedDescription } }
            if current { busy = false }
        }
    }
}
