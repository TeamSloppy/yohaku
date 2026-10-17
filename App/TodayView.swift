import SwiftUI

struct TodayView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var preview = DailyLessonPlan()
    @State private var launch: Launch?
    @State private var notice: String?
    @State private var starting = false
    @State private var clock = Date()
    private let ticks = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private struct Launch: Identifiable {
        let id: UUID
        let context: UUID
    }
    private var cards: FlashcardStore { workspace.flashcards }
    private var materials: [StudyMaterialRecord]? { workspace.materials.isBlocked ? nil : workspace.materials.records }
    private var available: Bool { workspace.dailyLessonVaultReady && cards.isLoaded && !cards.isBlocked && cards.error == nil && !workspace.materials.isBlocked }
    private var saving: Bool { workspace.materials.state.lessonIntent != nil && workspace.materials.error == nil }
    private var active: DailyLessonState? { workspace.materials.lesson.flatMap { $0.isComplete ? nil : $0 } }

    var body: some View {
        List {
            if let notice { Text(notice).foregroundStyle(.orange).accessibilityIdentifier("today-notice") }
            if !workspace.dailyLessonVaultReady {
                Text(workspace.error ?? "Хранилище открывается или недоступно. Подборка появится после загрузки.")
                Button("Открыть хранилище") { workspace.showFolderPicker = true }
            } else if !cards.isLoaded {
                ProgressView("Загрузка карточек")
            } else if saving {
                ProgressView("Сохранение ответа…").accessibilityIdentifier("today-saving")
            } else if !available {
                Section("Занятие недоступно") {
                    DailyLessonRecoveryControls(workspace: workspace, context: workspace.dailyLessonContext)
                }
            } else if let active {
                Section("Сохранённое занятие") {
                    Text("Пройдено: \(active.outcomes.count) из \(active.steps.count)").accessibilityIdentifier("today-progress")
                    Button("Продолжить", systemImage: "play.fill") { launch = .init(id: active.id, context: workspace.dailyLessonContext) }
                        .accessibilityIdentifier("today-continue")
                    Text("Содержание и порядок сохранены. Незавершённый ввод можно повторить.").font(.caption)
                }
            } else if let completed = workspace.materials.completedLesson(on: clock) {
                Section("Сегодня завершено") {
                    Label("Занятие завершено", systemImage: "checkmark.circle").accessibilityIdentifier("today-complete")
                    Text("Оценено: \(completed.reviewed) · пропущено: \(completed.skipped)")
                    Text("Следующее занятие появится в новый день. Ручная практика доступна в библиотеке.").font(.caption)
                }
            } else {
                Section {
                    Picker("Время", selection: $workspace.dailyLessonDuration) {
                        ForEach(DailyLessonDuration.allCases) { Text("\($0.rawValue) мин").tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("today-duration")
                    Text("Около 30 секунд на выражение. Подборка может быть короче.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("Выбрано: \(preview.items.count)").accessibilityIdentifier("today-count")
                    Button("Начать практику", systemImage: "play.fill", action: start)
                        .disabled(preview.items.isEmpty || starting).accessibilityIdentifier("today-start")
                    if preview.items.isEmpty {
                        Text("Сейчас нет карточек для этой подборки. Будущие повторения появятся в своё время.")
                            .accessibilityIdentifier("today-empty")
                    } else if preview.items.count < workspace.dailyLessonDuration.capacity {
                        Text("Материала меньше выбранного времени — практика будет короче.").font(.caption)
                    }
                }
                Section("В подборке") {
                    ForEach(preview.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            FlashcardFieldContent(text: item.exercise.card.japanese, drawing: item.exercise.card.handwriting?.japanese, maxHeight: 60)
                            Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            if let path = item.exercise.card.sourcePath { Text("Из записи: \(path)").font(.caption2).foregroundStyle(.secondary) }
                        }.accessibilityIdentifier("today-item-\(item.id)")
                    }
                }
            }
            Section {
                NavigationLink("Открыть библиотеку") { FlashcardsView(workspace: workspace) }
                    .accessibilityIdentifier("today-library")
                Button("Выбрать запись") { dismiss() }.accessibilityIdentifier("today-source")
            }
        }
        .navigationTitle("Сегодня").background(Palette.background)
        .fullScreenCover(item: $launch) { value in
            DailyLessonStudyView(workspace: workspace, lessonID: value.id, context: value.context)
        }
        .onAppear { refresh() }
        .onChange(of: workspace.dailyLessonDuration) { _, _ in refresh() }
        .onChange(of: cards.cards) { _, _ in refresh() }
        .onChange(of: available) { _, _ in refresh() }
        .onChange(of: workspace.materials.state) { _, _ in refresh() }
        .onChange(of: workspace.materials.isBlocked) { _, _ in refresh() }
        .onChange(of: workspace.dailyLessonContext) { _, _ in launch = nil; preview = .init(); notice = nil; starting = false }
        .onChange(of: phase) { _, value in if value == .active { refresh() } }
        .onReceive(ticks) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
    }

    private func refresh() {
        clock = Date()
        guard available, active == nil, workspace.materials.completedLesson(on: clock) == nil else { preview = .init(); return }
        preview = DailyLessonPlanner.plan(cards: cards.cards, materials: materials,
            duration: workspace.dailyLessonDuration, now: Date(), calendar: .current)
    }

    private func start() {
        guard available, !starting, !preview.items.isEmpty else { return }
        let selected = preview, duration = workspace.dailyLessonDuration, context = workspace.dailyLessonContext
        starting = true; notice = nil
        Task { @MainActor in
            let current: @MainActor @Sendable () -> Bool = { workspace.dailyLessonContext == context && workspace.dailyLessonVaultReady }
            do {
                let lesson = try await workspace.materials.startLesson(selected, duration: duration, cards: cards, ifCurrent: current)
                guard current() else { return }
                launch = .init(id: lesson.id, context: context)
            } catch {
                guard current() else { return }
                notice = error.localizedDescription; refresh()
            }
            if current() { starting = false }
        }
    }
}
