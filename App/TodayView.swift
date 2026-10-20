import SwiftUI

struct TodayView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var preview = DailyLessonPlan()
    @State private var launch: Launch?
    @State private var notice: String?
    @State private var starting = false
    @State private var visible = false
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
        GeometryReader { geometry in
            let roomy = geometry.size.width >= 700 && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    heading(roomy: roomy)
                    if let notice {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.orange).accessibilityIdentifier("today-notice")
                    }
                    if workspace.phrasePreparing {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { ProgressView(); Text("Составляем фразы из знакомых слов…").font(.subheadline) }
                            Text("Используется выбранная модель из настроек.").font(.caption).foregroundStyle(TodayColors.secondary)
                            Button("Пока без новых фраз") { workspace.skipAutomaticPhrases() }.font(.subheadline)
                        }.accessibilityIdentifier("phrase-preparing")
                    } else if let error = workspace.phraseError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Фразы пока не готовы: " + error).font(.callout).foregroundStyle(TodayColors.secondary)
                            Button("Попробовать снова") { preparePhrases(retry: true) }.accessibilityIdentifier("phrase-retry")
                        }
                    }
                    lessonContent
                    if workspace.dailyLessonVaultReady { ExtraPracticeEntry(workspace: workspace) }
                    if available, active == nil, workspace.materials.completedLesson(on: clock) == nil, !preview.items.isEmpty {
                        selection
                    }
                    resources(roomy: roomy)
                    Spacer(minLength: 12)
                    if !typeSize.isAccessibilitySize { VStack(spacing: 6) {
                        Text("少しずつ、毎日。").font(.system(.title3, design: .serif)).foregroundStyle(Palette.accent)
                            .accessibilityHidden(true)
                        Text("Понемногу, каждый день.").font(.caption).foregroundStyle(TodayColors.secondary)
                    }.frame(maxWidth: .infinity).padding(.top, 4) }
                }
                .padding(.horizontal, roomy ? 36 : 20)
                .padding(.top, roomy ? 32 : 16).padding(.bottom, 28)
                .frame(maxWidth: 960)
                .frame(minHeight: geometry.size.height, alignment: .top)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background).accessibilityIdentifier("today-scroll")
        }
        .navigationTitle("Сегодня")
        .toolbarBackground(Palette.background, for: .navigationBar)
        .fullScreenCover(item: $launch) { value in
            DailyLessonStudyView(workspace: workspace, lessonID: value.id, context: value.context)
        }
        .onAppear { visible = true; refresh(); preparePhrases() }
        .onDisappear { visible = false; workspace.skipAutomaticPhrases() }
        .onChange(of: workspace.dailyLessonDuration) { _, _ in refresh() }
        .onChange(of: cards.cards) { _, _ in refresh(); preparePhrases() }
        .onChange(of: workspace.agent.running) { _, running in if !running { preparePhrases() } }
        .onChange(of: workspace.phrasePreparing) { _, running in if !running { refresh(); preparePhrases() } }
        .onChange(of: workspace.learningProfile.knownKana) { _, _ in preparePhrases() }
        .onChange(of: available) { _, _ in refresh(); preparePhrases() }
        .onChange(of: workspace.materials.state) { _, _ in refresh() }
        .onChange(of: workspace.materials.isBlocked) { _, _ in refresh() }
        .onChange(of: workspace.dailyLessonContext) { _, _ in launch = nil; preview = .init(); notice = nil; starting = false }
        .onChange(of: phase) { _, value in if value == .active { refresh(); preparePhrases() } }
        .onReceive(ticks) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh(); preparePhrases() }
    }


    private var empty: Bool {
        available && active == nil && workspace.materials.completedLesson(on: clock) == nil && preview.items.isEmpty
    }

    private func heading(roomy: Bool) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                if !typeSize.isAccessibilitySize {
                    Text(clock, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.caption.weight(.semibold)).textCase(.uppercase).tracking(1.2).foregroundStyle(Palette.accent)
                }
                Text("Время для японского")
                    .font(.system(typeSize.isAccessibilitySize ? .title2 : .largeTitle, design: .serif, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if !typeSize.isAccessibilitySize {
                    Text("Личное занятие из ваших записей.")
                        .font(.subheadline).foregroundStyle(TodayColors.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { TodayNotebookIllustration(size: roomy ? 144 : 94) }
        }
    }

    @ViewBuilder private var lessonContent: some View {
        if !workspace.dailyLessonVaultReady {
            TodayPanel {
                Label("Сначала откроем ваши записи", systemImage: "folder") .font(.title2.weight(.semibold))
                Text(workspace.error ?? "Выберите хранилище, чтобы собрать личное занятие.").foregroundStyle(TodayColors.secondary)
                Button("Открыть хранилище") { workspace.showFolderPicker = true }.buttonStyle(TodayPrimaryButtonStyle())
            }
        } else if !cards.isLoaded {
            TodayPanel { ProgressView("Загрузка карточек").frame(maxWidth: .infinity).padding(.vertical, 32) }
        } else if saving {
            TodayPanel { ProgressView("Сохранение ответа…").frame(maxWidth: .infinity).padding(.vertical, 32).accessibilityIdentifier("today-saving") }
        } else if !available {
            TodayPanel {
                Label("Давайте восстановим занятие", systemImage: "arrow.clockwise.circle").font(.title2.weight(.semibold))
                DailyLessonRecoveryControls(workspace: workspace, context: workspace.dailyLessonContext)
            }
        } else if let active {
            activeLesson(active)
        } else if let completed = workspace.materials.completedLesson(on: clock) {
            completedLesson(completed)
        } else if preview.items.isEmpty {
            emptyLesson
        } else {
            readyLesson
        }
    }

    private var emptyLesson: some View {
        TodayPanel(tinted: true) {
            if !typeSize.isAccessibilitySize {
                Label(cards.cards.isEmpty ? "ЧИСТЫЙ ЛИСТ" : "МОЖНО НЕ СПЕШИТЬ", systemImage: cards.cards.isEmpty ? "leaf" : "sun.max")
                    .font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(Palette.accent)
            }
            Text(typeSize.isAccessibilitySize ? (cards.cards.isEmpty ? "Ваша практика" : "На сегодня всё") : (cards.cards.isEmpty ? "Здесь начнётся\nваша практика" : "На сегодня\nвсё спокойно"))
                .font(.system(.title, design: .serif, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(typeSize.isAccessibilitySize
                 ? (cards.cards.isEmpty ? "Выберите запись, чтобы подготовить карточки для занятия." : "Повторения появятся позже. Пока можно позаниматься в библиотеке.")
                 : (cards.cards.isEmpty
                    ? "Выберите запись и подготовьте из неё карточки. Из сохранённых слов здесь сложится ваше личное занятие."
                    : "Повторения появятся, когда придёт время. А пока можно вернуться к записям или попрактиковаться в библиотеке."))
                .font(.body).foregroundStyle(TodayColors.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("today-empty")
            Button { dismiss() } label: {
                HStack { Text("Выбрать запись"); Spacer(); Image(systemName: "arrow.up.right") }
            }.buttonStyle(TodayPrimaryButtonStyle()).padding(.top, 8).accessibilityIdentifier("today-source")
        }
    }

    private var readyLesson: some View {
        TodayPanel {
            Label("ЛИЧНОЕ ЗАНЯТИЕ", systemImage: "sparkles").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(Palette.accent)
            Text("Ваша подборка готова") .font(.system(.title, design: .serif, weight: .medium))
            HStack {
                Label("\(workspace.dailyLessonDuration.rawValue) мин", systemImage: "clock")
                Text("·").accessibilityHidden(true)
                Text("Выбрано: \(preview.items.count)").accessibilityIdentifier("today-count")
            }.font(.subheadline).foregroundStyle(TodayColors.secondary)
            Divider().overlay(Palette.accent.opacity(0.08)).padding(.vertical, 2)
            Text("Сколько времени есть?").font(.subheadline.weight(.semibold))
            Picker("Время", selection: $workspace.dailyLessonDuration) {
                ForEach(DailyLessonDuration.allCases) { Text("\($0.rawValue) мин").tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("today-duration")
            Text(preview.items.count < workspace.dailyLessonDuration.capacity
                 ? "Материала меньше выбранного времени — занятие будет короче."
                 : "Около 30 секунд на выражение. Занимайтесь в своём темпе.")
                .font(.caption).foregroundStyle(TodayColors.secondary)
            Button(action: start) {
                HStack {
                    if starting { ProgressView().tint(.white) } else { Image(systemName: "play.fill") }
                    Text(starting ? "Готовим занятие…" : "Начать практику")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
            }.buttonStyle(TodayPrimaryButtonStyle()).disabled(starting || workspace.phrasePreparing).padding(.top, 8).accessibilityIdentifier("today-start")
        }
    }

    private func activeLesson(_ lesson: DailyLessonState) -> some View {
        TodayPanel(tinted: true) {
            Label("В ВАШЕМ ТЕМПЕ", systemImage: "bookmark").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(Palette.accent)
            Text("Продолжим с того же места")
                .font(.system(.title, design: .serif, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text("Пройдено: \(lesson.outcomes.count) из \(lesson.steps.count)")
                .font(.headline).accessibilityIdentifier("today-progress")
            ProgressView(value: Double(lesson.outcomes.count), total: Double(lesson.steps.count)).tint(Palette.accent)
                .accessibilityLabel("Прогресс занятия").padding(.vertical, 4)
            Text("Подборка и порядок сохранены. Незавершённый ввод можно повторить.")
                .font(.subheadline).foregroundStyle(TodayColors.secondary)
            Button { launch = .init(id: lesson.id, context: workspace.dailyLessonContext) } label: {
                HStack { Image(systemName: "play.fill"); Text("Продолжить занятие"); Spacer(); Image(systemName: "arrow.right") }
            }.buttonStyle(TodayPrimaryButtonStyle()).padding(.top, 8).accessibilityIdentifier("today-continue")
        }
    }

    private func completedLesson(_ completed: DailyLessonCompletion) -> some View {
        TodayPanel(tinted: true) {
            Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(Palette.accent).accessibilityHidden(true)
            Label("Занятие завершено", systemImage: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                .accessibilityIdentifier("today-complete")
            Text("Хорошая работа.\nНа сегодня — всё.").font(.system(.title, design: .serif, weight: .medium))
            Text("Оценено: \(completed.reviewed) · пропущено: \(completed.skipped)").font(.headline)
            Text("Следующее занятие появится в новый день. Для свободной практики всегда есть библиотека.")
                .font(.subheadline).foregroundStyle(TodayColors.secondary)
        }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("В этом занятии").font(.title3.weight(.semibold))
                Spacer()
                Text("\(preview.items.count)").font(.subheadline.monospacedDigit()).foregroundStyle(TodayColors.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(preview.items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 16) {
                        Text(String(format: "%02d", index + 1)).font(.caption.monospacedDigit()).foregroundStyle(Palette.accent)
                            .padding(.top, 6).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            FlashcardFieldContent(text: item.exercise.card.japanese, drawing: item.exercise.card.handwriting?.japanese, maxHeight: 60)
                                .font(.title3.weight(.medium))
                            Text(item.reason).font(.caption).foregroundStyle(TodayColors.secondary)
                            if let path = item.exercise.card.sourcePath {
                                Text("Из записи: \(path)").font(.caption2).foregroundStyle(TodayColors.secondary).lineLimit(2)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: item.exercise.card.reviewCount == 0 ? "sparkle" : "arrow.trianglehead.clockwise")
                            .font(.subheadline).foregroundStyle(Palette.accent).padding(.top, 4).accessibilityHidden(true)
                    }
                    .padding(20).accessibilityIdentifier("today-item-\(item.id)")
                    if index < preview.items.count - 1 { Divider().padding(.leading, 54) }
                }
            }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.accent.opacity(0.10)))
        }
    }

    private func resources(roomy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ваши материалы").font(.headline)
            let layout = roomy && !empty ? AnyLayout(HStackLayout(alignment: .top, spacing: 14)) : AnyLayout(VStackLayout(spacing: 14))
            layout {
                NavigationLink { FlashcardsView(workspace: workspace) } label: {
                    TodayResourceLabel(title: "Открыть библиотеку", subtitle: "Все карточки и свободная практика", symbol: "rectangle.stack")
                }.buttonStyle(.plain).accessibilityIdentifier("today-library")
                if !empty {
                    Button { dismiss() } label: {
                        TodayResourceLabel(title: "Выбрать запись", subtitle: "Найти слова для нового занятия", symbol: "square.and.pencil")
                    }.buttonStyle(.plain).accessibilityIdentifier("today-source")
                }
            }
        }
    }

    private func preparePhrases(retry: Bool = false) {
        guard visible, phase == .active else { return }
        Task { await workspace.prepareAutomaticPhrases(retry: retry) }
    }

    private func refresh() {
        clock = Date()
        guard available, active == nil, workspace.materials.completedLesson(on: clock) == nil else { preview = .init(); return }
        preview = DailyLessonPlanner.plan(cards: cards.cards, materials: materials,
            duration: workspace.dailyLessonDuration, now: Date(), calendar: .current)
    }

    private func start() {
        guard available, !starting, !workspace.phrasePreparing, !preview.items.isEmpty else { return }
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
