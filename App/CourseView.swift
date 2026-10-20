import SwiftUI

struct CourseEntry: View {
    @Bindable var workspace: WorkspaceModel
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Label("Курс японского", systemImage: "stairs") }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("open-course")
            .sheet(isPresented: $presented) { CourseView(workspace: workspace, context: workspace.dailyLessonContext) }
    }
}

struct CourseView: View {
    @Bindable var workspace: WorkspaceModel
    let context: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var modules: [CourseModule] = []
    @State private var notice: String?
    @State private var launch = false
    @State private var busy = false
    @State private var daily = false
    private var progress: CourseProgress { workspace.learning.state.course ?? .init() }
    private var current: Bool { workspace.dailyLessonContext == context && workspace.dailyLessonVaultReady }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Хирагана → катакана → кандзи и база N5").font(.headline)
                    Text("Новая тема открывается после проверки: минимум 80% по каждому навыку. Закрепление в другой день отмечается отдельно.")
                    if let last = modules.last { Text("Сейчас доступны: \(last.stage), до темы «\(last.title)». Программа расширяется по готовым ступеням.").font(.caption) }
                    Picker("Время урока", selection: $workspace.dailyLessonDuration) {
                        ForEach(DailyLessonDuration.allCases) { Text("\($0.rawValue) мин").tag($0) }
                    }
                }
                if let notice { Text(notice).foregroundStyle(.orange).accessibilityIdentifier("course-error") }
                if workspace.learning.blocked {
                    Text(workspace.learning.error ?? "Прогресс недоступен")
                    Button("Загрузить сохранённую версию") { Task { await workspace.learning.recover() } }
                } else {
                    if workspace.materials.lesson?.isComplete == false || (workspace.materials.completedLesson() == nil && !reviewPlan.items.isEmpty) {
                        Section("Повторение изученного") {
                            Text("Сначала закрепите слова по расписанию, затем продолжайте новую тему.")
                            Button("Повторить по расписанию") { startReview() }.accessibilityIdentifier("course-scheduled-review")
                        }
                    }
                    if workspace.learning.state.courseSession?.isComplete == false {
                        Button("Продолжить урок") { launch = true }.accessibilityIdentifier("course-resume")
                    }
                    ForEach(modules) { module in
                        Section(module.stage + " · " + module.title) {
                            let unlocked = CourseCatalog.unlocked(module.id, modules: modules, progress: progress)
                            if progress.completed.contains(module.id) {
                                Label(progress.reinforced(module.id) ? "Закреплено в разные дни" : "Проверка пройдена", systemImage: "checkmark.circle")
                            }
                            Text(module.explanation)
                            if unlocked {
                                Button("Учить тему") { start(module, checkpoint: false) }.accessibilityIdentifier("course-learn-" + module.id)
                                Button(progress.completed.contains(module.id) ? "Проверить закрепление" : "Проверить знания / пропустить знакомое") {
                                    start(module, checkpoint: true)
                                }.accessibilityIdentifier("course-check-" + module.id)
                            } else { Label("Сначала завершите предыдущую тему", systemImage: "lock") }
                        }.disabled(busy || !current || workspace.learning.blocked)
                    }
                }
            }.navigationTitle("Курс японского")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
                .fullScreenCover(isPresented: $launch) { CourseSessionView(workspace: workspace, context: context) }
                .fullScreenCover(isPresented: $daily) {
                    if let lesson = workspace.materials.lesson { DailyLessonStudyView(workspace: workspace, lessonID: lesson.id, context: context) }
                }
                .task { do { modules = try CourseCatalog.load() } catch { notice = error.localizedDescription } }
                .onChange(of: workspace.dailyLessonContext) { _, _ in dismiss() }
        }
    }
    private var reviewPlan: DailyLessonPlan {
        let cards = workspace.flashcards.cards.filter { $0.courseItemID.map(progress.trained.contains) == true }
        return DailyLessonPlanner.plan(cards: cards, materials: workspace.materials.records,
            duration: workspace.dailyLessonDuration, now: Date(), calendar: .current)
    }
    private func startReview() {
        guard current, !busy, !workspace.materials.isBlocked else { return }
        busy = true
        Task { @MainActor in
            defer { if current { busy = false } }
            do {
                _ = try await workspace.materials.startLesson(reviewPlan, duration: workspace.dailyLessonDuration,
                    cards: workspace.flashcards, ifCurrent: { current })
                if current { daily = true }
            } catch { if current { notice = error.localizedDescription } }
        }
    }
    private func start(_ module: CourseModule, checkpoint: Bool) {
        guard current, !busy else { return }
        if workspace.learning.state.courseSession?.isComplete == false { launch = true; return }
        busy = true; notice = nil
        Task { @MainActor in
            defer { if current { busy = false } }
            do {
                let valid: @MainActor () -> Bool = { current }
                guard !workspace.flashcards.isBlocked, workspace.flashcards.error == nil,
                      await workspace.flashcards.addCourseCards(module.items.map(\.card), ifCurrent: valid) else { throw StudyImportError.unavailable }
                try await workspace.learning.startCourse(module, checkpoint: checkpoint, duration: workspace.dailyLessonDuration,
                    modules: modules, ifCurrent: valid)
                if current { launch = true }
            } catch { if current { notice = error.localizedDescription } }
        }
    }
}
