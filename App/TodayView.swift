import SwiftUI

struct TodayView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var preview = DailyLessonPlan()
    @State private var launch: Launch?
    @State private var notice: String?
    private let ticks = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private struct Launch: Identifiable {
        let id = UUID()
        let exercises: [FlashcardExercise]
    }
    private var cards: FlashcardStore { workspace.flashcards }
    private var materials: [StudyMaterialRecord]? { workspace.materials.isBlocked ? nil : workspace.materials.records }
    private var available: Bool { workspace.dailyLessonVaultReady && cards.isLoaded && !cards.isBlocked && cards.error == nil }

    var body: some View {
        List {
            Section {
                Picker("Время", selection: $workspace.dailyLessonDuration) {
                    ForEach(DailyLessonDuration.allCases) { Text("\($0.rawValue) мин").tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("today-duration")
                Text("Около 30 секунд на выражение. Подборка может быть короче; повтор ошибок займёт дополнительное время.")
                    .font(.caption).foregroundStyle(.secondary)
                if let notice { Text(notice).foregroundStyle(.orange).accessibilityIdentifier("today-notice") }
            }
            if !workspace.dailyLessonVaultReady {
                Text(workspace.error ?? "Хранилище открывается или недоступно. Подборка появится после загрузки.")
                Button("Открыть хранилище") { workspace.showFolderPicker = true }
            } else if !cards.isLoaded {
                ProgressView("Загрузка карточек")
            } else if !available {
                Section("Карточки недоступны") {
                    Text(cards.error ?? "Сначала восстановите сохранённую библиотеку.")
                    Button("Загрузить сохранённую версию") { Task { _ = await cards.recoverSavedVersion(); refresh() } }
                        .accessibilityIdentifier("today-recover")
                }
            } else {
                Section {
                    Text("Выбрано: \(preview.items.count)").accessibilityIdentifier("today-count")
                    Button("Начать практику", systemImage: "play.fill", action: start)
                        .disabled(preview.items.isEmpty).accessibilityIdentifier("today-start")
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
                if workspace.materials.isBlocked {
                    Text("Предложения из записей недоступны. Откройте библиотеку для восстановления; обычные карточки доступны.").font(.caption)
                }
            }
        }
        .navigationTitle("Сегодня").background(Palette.background)
        .fullScreenCover(item: $launch) { value in
            FlashcardStudyView(store: cards, mode: .cards, suppliedExercises: value.exercises,
                               suppliedMaterials: { materials })
        }
        .onAppear { refresh() }
        .onChange(of: workspace.dailyLessonDuration) { _, _ in refresh() }
        .onChange(of: cards.cards) { _, _ in refresh() }
        .onChange(of: available) { _, _ in refresh() }
        .onChange(of: workspace.materials.state) { _, _ in refresh() }
        .onChange(of: workspace.materials.isBlocked) { _, _ in refresh() }
        .onChange(of: workspace.dailyLessonContext) { _, _ in launch = nil; preview = .init(); notice = nil }
        .onChange(of: phase) { _, value in if value == .active { refresh() } }
        .onReceive(ticks) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
    }

    private func refresh() {
        guard workspace.dailyLessonVaultReady else { preview = .init(); return }
        preview = DailyLessonPlanner.plan(cards: cards.cards, materials: materials,
            duration: workspace.dailyLessonDuration, now: Date(), calendar: .current)
    }

    private func start() {
        let resolved = DailyLessonPlanner.resolve(preview.exercises, cards: cards.cards, materials: materials, now: Date())
        guard available, resolved == preview.exercises else {
            refresh(); notice = "Подборка изменилась. Проверьте её и нажмите «Начать» ещё раз."; return
        }
        guard !resolved.isEmpty else { return }
        notice = nil; launch = Launch(exercises: resolved)
    }
}
