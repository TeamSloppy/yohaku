import Foundation
import Observation
import PencilKit
import StudyCanvas
import StudyCore
import StudyIntelligence
import UIKit

struct DocumentTab: Codable, Identifiable, Equatable {
    var path: String
    var pageID: UUID?
    var position = CanvasPosition()
    var cursor = 0
    var pagePositions: [String: CanvasPosition]?
    var id: String { path }
}

@MainActor @Observable final class WorkspaceModel {
    nonisolated static let iCloudContainerIdentifier = "iCloud.team.sloppy.yohaku"

    var store: VaultStore?
    var root: URL?
    var entries: [VaultEntry] = []
    var tabs: [DocumentTab] = []
    var activePath: String?
    var secondaryPath: String?
    var sessions: [String: DocumentSession] = [:]
    var error: String?
    var busy = false
    var showAgent = false
    var pendingContext: SourceContext?
    var sourceNavigation: SourceNavigationRequest?
    var chatPath: String?
    var showSettings = false
    var showFolderPicker = false
    var isUsingICloud = false
    var query = ""
    var searchResults: [VaultEntry] = []
    var knowledgeResults: [KnowledgeSearchHit] = []
    var knowledgeCoverage: KnowledgeSearchCoverage?
    var knowledgeSearchError: String?
    var knowledgeSearching = false
    var knowledgeNextCursor: String?
    var backlinks: [VaultEntry] = []
    let agent = AgentSession()
    var dailyLessonDuration: DailyLessonDuration = .standard
    private(set) var dailyLessonContext = UUID()
    private(set) var dailyLessonVaultReady = false
    let flashcards: FlashcardStore
    let materials: StudyMaterialStore
    init(writer: any StudyFileWriting & StudyStateFileWriting = StudyFileWriter()) {
        flashcards = FlashcardStore(writer: writer) { await StudyCompanion.shared.updateCards($0) }
        materials = StudyMaterialStore(writer: writer)
    }
    private var accessURL: URL?
    private var presenter: VaultPresenter?
    private var starting = false
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var refreshing = false
    private var vaultID: String?
    private var studyEpoch = UUID()
    private var studyRun = UUID()
    private var studyTask: Task<Void, Never>?
    private(set) var markdownStudyMaterials: [StudyMaterialRecord] = []
    private var transcriptionInvalidation: Task<Bool, Never>?
    private var inFlightStudyMaterialIDs: Set<UUID> = []
    private(set) var markdownStudyCards: [SourceGeneratedFlashcard] = []
    private(set) var markdownStudyRunning = false
    var markdownStudyError: String?
    private(set) var canvasStudyRecognition: CanvasTranscription?

    func prepareMarkdownStudy(_ session: DocumentSession) async throws -> StudySourceSnapshot {
        let epoch = studyEpoch, path = session.path
        await session.save()
        guard epoch == studyEpoch, let vaultID, let store, sessions[path] === session,
              !session.isDirty, session.error == nil, session.conflictPath == nil else { throw StudyError.staleRevision }
        let loaded = try await store.load(path)
        guard epoch == studyEpoch, loaded.content.id == session.content.id,
              loaded.content.contentRevision == session.content.contentRevision, !session.isDirty else { throw StudyError.staleRevision }
        return try StudySourceSnapshot(vaultID: vaultID, epoch: epoch, path: path, content: loaded.content, configuration: agent.configuration)
    }
    func prepareCanvasStudy(_ session: DocumentSession, pageID: UUID, region: Rect?) async throws -> StudySourceSnapshot {
        let epoch = studyEpoch, path = session.path, configuration = agent.configuration
        await session.save(); try Task.checkCancellation()
        guard epoch == studyEpoch, let vaultID, let store, sessions[path] === session,
              !session.isDirty, session.error == nil, session.conflictPath == nil else { throw StudyError.staleRevision }
        let loaded = try await store.load(path); try Task.checkCancellation()
        guard epoch == studyEpoch, configuration == agent.configuration, loaded.content.id == session.content.id,
              loaded.content.contentRevision == session.content.contentRevision, !session.isDirty else { throw StudyError.staleRevision }
        let crop = try StudySourceSnapshot.canvasRegion(loaded.content, pageID: pageID, region: region)
        let frozen = DocumentSession(path: path, loaded: loaded, store: store)
        for object in loaded.content.pages.first(where: { $0.id == pageID })!.objects where object.kind == .image && object.frame.intersects(crop) {
            guard UIImage(data: try await frozen.asset(object.content)) != nil else { throw StudyError.modelUnavailable("Изображение в выбранной области недоступно или повреждено.") }
            try Task.checkCancellation()
        }
        let image = try await CanvasRenderer.image(session: frozen, pageID: pageID, region: crop.cgRect)
        guard let pixels = image.cgImage, (1...2048).contains(pixels.width), (1...2048).contains(pixels.height),
              let data = image.pngData(), data.count <= 8 * 1024 * 1024 else {
            throw StudyError.modelUnavailable("Изображение слишком велико. Выберите меньшую область.")
        }
        let source = try StudySourceSnapshot(vaultID: vaultID, epoch: epoch, path: path, content: loaded.content,
            configuration: configuration, pageID: pageID, region: crop, image: data)
        try await validateStudySource(source)
        return source
    }
    func recognizeCanvasStudy(_ source: StudySourceSnapshot,
        recognize: (@MainActor (StudySourceSnapshot) async throws -> CanvasTranscription)? = nil) {
        guard studyTask == nil, !agent.running else { markdownStudyError = "Дождитесь завершения текущего ответа."; return }
        let run = UUID(); studyRun = run; markdownStudyRunning = true; markdownStudyCards = []; markdownStudyError = nil; canvasStudyRecognition = nil
        studyTask = Task {
            defer { studyTask = nil; markdownStudyRunning = false }
            do {
                try await validateStudySource(source); try AgentSession.validateVision(source.configuration)
                let recognized: CanvasTranscription
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--canvas-study-fixture") {
                    recognized = try CanvasTranscription.parse(#"{"text":"猫は","unclear":true}"#)
                } else if let recognize { recognized = try await recognize(source) }
                else { recognized = try await agent.recognizeCanvas(source) }
                #else
                recognized = try await agent.recognizeCanvas(source)
                #endif
                try await validateStudySource(source)
                guard studyRun == run else { return }
                canvasStudyRecognition = recognized
            } catch {
                if studyRun == run, !(error is CancellationError) { markdownStudyError = error.localizedDescription }
            }
        }
    }
    private func currentStudySource(_ source: StudySourceSnapshot) -> Bool {
        guard source.epoch == studyEpoch, source.vaultID == vaultID, source.configuration == agent.configuration,
              let session = sessions[source.path], session.path == source.path,
              !session.isDirty, session.error == nil, session.conflictPath == nil else { return false }
        return session.content.id == source.documentID && session.content.contentRevision == source.contentRevision
    }
    private func validateStudySource(_ source: StudySourceSnapshot) async throws {
        guard currentStudySource(source), let store else { throw StudyError.staleRevision }
        let loaded = try await store.load(source.path, rejectConflicts: true)
        try Task.checkCancellation()
        guard currentStudySource(source), loaded.content.id == source.documentID,
              loaded.content.contentRevision == source.contentRevision else { throw StudyError.staleRevision }
    }
    func cancelMarkdownStudy() {
        studyRun = UUID(); studyTask?.cancel(); markdownStudyMaterials = []; markdownStudyCards = []; markdownStudyError = nil; canvasStudyRecognition = nil
    }
    func generateMarkdownStudy(_ source: StudySourceSnapshot,
        generate: (@MainActor (StudySourceSnapshot) async throws -> [SourceGeneratedFlashcard])? = nil) {
        guard studyTask == nil, !agent.running else { markdownStudyError = "Дождитесь завершения текущего ответа."; return }
        guard source.image == nil || source.transcriptionConfirmed else { markdownStudyError = "Сначала подтвердите расшифровку."; return }
        let run = UUID(); studyRun = run; markdownStudyRunning = true; markdownStudyCards = []; markdownStudyError = nil
        studyTask = Task {
            defer { studyTask = nil; markdownStudyRunning = false; inFlightStudyMaterialIDs = [] }
            do {
                try await validateStudySource(source)
                let cards: [SourceGeneratedFlashcard]
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--markdown-study-fixture") || ProcessInfo.processInfo.arguments.contains("--canvas-study-fixture") {
                    cards = try MaterialGenerationService.parse(#"{"cards":[{"japanese":"猫","reading":"ねこ","translation":"кошка","example":"猫がいます。","note":"Существительное","sourceID":"excerpt","quote":"猫はかわいい。"}]}"#, source: source)
                } else if let generate { cards = try await generate(source) }
                else { cards = try await agent.generateSourceFlashcards(source) }
                #else
                cards = try await agent.generateSourceFlashcards(source)
                #endif
                try await validateStudySource(source)
                guard studyRun == run else { return }
                let validated = try MaterialGenerationService.validate(cards, source: source)
                let records = validated.map { item in
                    StudyMaterialRecord(fields: StudyMaterialFields(Flashcard(japanese: item.japanese, reading: item.reading,
                        translation: item.translation, example: item.example, note: item.note)),
                        source: .init(vaultID: source.vaultID, documentID: source.documentID, contentRevision: source.contentRevision,
                            path: source.path, pageID: source.pageID, region: source.region, excerpt: source.excerpt,
                            quote: item.quote, origin: source.image == nil ? nil : .confirmedTranscription))
                }
                _ = await transcriptionInvalidation?.value
                inFlightStudyMaterialIDs = Set(records.map(\.id))
                for old in materials.records where old.disposition == .pending && records.contains(where: { $0.fields.fingerprint == old.fields.fingerprint }) {
                    inFlightStudyMaterialIDs.insert(old.id)
                }
                let saved = try await materials.save(records, existingCards: flashcards.cards, ifCurrent: { self.studyRun == run && self.currentStudySource(source) })
                try await validateStudySource(source)
                guard studyRun == run else { return }
                markdownStudyMaterials = saved
                markdownStudyCards = validated.filter { item in saved.contains { $0.fields.fingerprint == StudyMaterialFields(Flashcard(japanese: item.japanese, reading: item.reading, translation: item.translation, example: item.example, note: item.note)).fingerprint } }
                if saved.isEmpty { markdownStudyError = "Эти материалы уже добавлены или отклонены." }
            } catch {
                if studyRun == run, !(error is CancellationError) { markdownStudyError = error.localizedDescription }
            }
        }
    }
    func invalidateStudyTranscription(_ source: StudySourceSnapshot? = nil, text: String? = nil) {
        var ids = Set(markdownStudyMaterials.map(\.id)).union(inFlightStudyMaterialIDs)
        if let source, source.image != nil {
            ids.formUnion(materials.records.filter { $0.disposition == .pending && $0.source.vaultID == source.vaultID &&
                $0.source.documentID == source.documentID && $0.source.pageID == source.pageID && $0.source.region == source.region &&
                $0.source.excerpt != text }.map(\.id))
        }
        materials.markSuperseded(ids); cancelMarkdownStudy()
        guard !ids.isEmpty else { return }
        transcriptionInvalidation = Task { await materials.supersede(ids) }
    }
    func acceptMarkdownStudy(_ source: StudySourceSnapshot, selected: Set<Int>) async -> Bool {
        let rows = markdownStudyMaterials
        guard source.epoch == studyEpoch, !selected.isEmpty, selected.allSatisfy(rows.indices.contains) else { return false }
        return await acceptStudyMaterials(Set(selected.map { rows[$0].id }))
    }
    func acceptStudyMaterials(_ ids: Set<UUID>) async -> Bool {
        guard !ids.isEmpty else { return false }
        let epoch = studyEpoch
        for id in ids {
            guard epoch == studyEpoch else { return false }
            if !(await materials.accept(id, cards: flashcards, validate: { try await self.validateSavedStudySource($0, epoch: epoch) })) {
                if epoch == studyEpoch { markdownStudyError = materials.error; await refreshStudyMaterials() }
                return false
            }
        }
        return true
    }
    private func validateSavedStudySource(_ source: StudyMaterialSource, epoch: UUID) async throws {
        guard epoch == studyEpoch, source.vaultID == vaultID, let store else { throw StudyError.staleRevision }
        if let session = sessions[source.path], session.isDirty || session.error != nil || session.conflictPath != nil { throw StudyError.staleRevision }
        let loaded = try await store.load(source.path, rejectConflicts: true)
        guard epoch == studyEpoch, source.vaultID == vaultID, loaded.content.id == source.documentID,
              loaded.content.contentRevision == source.contentRevision,
              source.pageID == nil || loaded.content.pages.contains(where: { $0.id == source.pageID }) else { throw StudyError.staleRevision }
        if let session = sessions[source.path], session.isDirty || session.error != nil || session.conflictPath != nil { throw StudyError.staleRevision }
    }
    func refreshStudyMaterials() async {
        let epoch = studyEpoch
        await materials.refreshSources { source in
            do {
                guard epoch == self.studyEpoch, let store = self.store else { return .stale }
                guard try await store.isAvailableLocally(source.path) else { return .missing }
                try await self.validateSavedStudySource(source, epoch: epoch); return .current
            }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return .missing }
            catch { return .stale }
        }
    }

    private var navigationGeneration = UUID()
    private var defaultsKey: String { "workspace-tabs-" + (vaultID ?? root?.path ?? "") }

    func start() async {
        guard !starting, store == nil else { return }; starting = true
        defer { starting = false }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            do {
                let fixtureID = ProcessInfo.processInfo.environment["YOHHAKU_TEST_VAULT"].flatMap(UUID.init(uuidString:)) ?? UUID()
                try await openVault(URL.temporaryDirectory.appendingPathComponent("UITest-\(fixtureID)"), remember: false)
                if entries.isEmpty { try await seed() }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--today-study-fixture"), flashcards.cards.isEmpty, materials.lesson == nil {
                    let now = Date()
                    for index in 0..<6 {
                        var card = Flashcard(japanese: index == 0 ? "優先" : "語\(index)", translation: "слово\(index)",
                            createdAt: now.addingTimeInterval(Double(index)), dueAt: now.addingTimeInterval(-60), successfulReviews: index < 2 ? 2 : 0)
                        if index == 0 { card.successfulReviews = 1; card.failedReviews = 1; card.lastRating = .forgot; card.sourcePath = "日本語/Источник.md"; card.sourceExcerpt = "Подтверждённый фрагмент"; card.sourceTextOrigin = .confirmedTranscription }
                        _ = await flashcards.add(card)
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--today-clock-fixture"), flashcards.cards.isEmpty, materials.lesson == nil {
                    _ = await flashcards.add(Flashcard(japanese: "時刻", translation: "время", dueAt: Date().addingTimeInterval(20), successfulReviews: 2))
                }
                if ProcessInfo.processInfo.arguments.contains("--today-recovery-fixture") {
                    if flashcards.cards.isEmpty { _ = await flashcards.add(Flashcard(japanese: "回復", translation: "восстановление")) }
                    flashcards.error = "Проверка восстановления библиотеки"
                }
                if ProcessInfo.processInfo.arguments.contains("--lesson-ink-fixture"), flashcards.cards.isEmpty, materials.lesson == nil {
                    let points = [CGPoint(x: 40, y: 40), CGPoint(x: 240, y: 120)].enumerated().map { index, point in
                        PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 4, height: 4),
                            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                    }
                    let ink = PKDrawing(strokes: [.init(ink: .init(.pen, color: .black), path: .init(controlPoints: points, creationDate: Date()))])
                    var card = Flashcard(japanese: "猫", translation: "кошка", dueAt: .distantPast, successfulReviews: 1)
                    card.handwriting = .init(japanese: ink.dataRepresentation()); _ = await flashcards.add(card)
                }
                if let lesson = materials.lesson, lesson.outcomes.count == 1, let step = lesson.current {
                    if ProcessInfo.processInfo.arguments.contains("--lesson-deleted-fixture") { _ = await flashcards.delete(id: step.card.id) }
                    if ProcessInfo.processInfo.arguments.contains("--lesson-edited-fixture"), var card = flashcards.cards.first(where: { $0.id == step.card.id }) {
                        card.japanese = "改訂"; _ = await flashcards.update(card)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--lesson-unconfirmed-fixture"), materials.state.lessonIntent == nil, let root,
                       let card = flashcards.cards.first(where: { $0.id == step.card.id }) {
                        let writer = StudyFileWriter(), stateURL = root.appendingPathComponent(".workspace/study-state.json")
                        let loaded = try await writer.loadState(stateURL)
                        let cardFile = try await writer.load(root.appendingPathComponent(".workspace/flashcards.json"))
                        var intent = DailyLessonReviewIntent(lessonID: lesson.id, stepID: step.id, rating: .remembered,
                            reviewedCard: FlashcardScheduler.review(card, rating: .remembered), expectedCardRevision: cardFile.revision)
                        intent.reviewedCard.appliedLessonOperationID = intent.id
                        var next = loaded.state; next.lessonIntent = intent
                        _ = try await writer.writeState(next, to: stateURL, expectedRevision: loaded.revision)
                        await materials.open(vaultRoot: root, cards: flashcards)
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--study-material-recovery-fixture"), let root {
                    let writer = StudyFileWriter(), cardURL = root.appendingPathComponent(".workspace/flashcards.json")
                    let cards = try await writer.load(cardURL)
                    if cards.revision == nil { _ = try await writer.write([], to: cardURL, expectedRevision: nil) }
                    let stateURL = root.appendingPathComponent(".workspace/study-state.json"), loaded = try await writer.loadState(stateURL)
                    if let record = loaded.state.records.first(where: { $0.disposition == .pending }) {
                        let savedCards = try await writer.load(cardURL)
                        var intent = StudyAcceptanceIntent(materialID: record.id, card: record.makeCard(), expectedCardRevision: savedCards.revision, createsCard: true)
                        intent.card.appliedMaterialOperationID = intent.id
                        var state = loaded.state; state.intents = [intent]
                        _ = try await writer.writeState(state, to: stateURL, expectedRevision: loaded.revision)
                        await flashcards.open(vaultRoot: root); await materials.open(vaultRoot: root, cards: flashcards)
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--study-material-stale-fixture"), let store {
                    let path = "日本語/Источник.md", loaded = try await store.load(path)
                    var changed = loaded.content; changed.markdown += "変更"
                    _ = try await store.save(path, content: changed, expectedRevision: loaded.revision)
                    await refreshStudyMaterials()
                }
                #endif
                if ProcessInfo.processInfo.arguments.contains("--canvas-study-fixture") {
                    var config = agent.configuration; config.provider = .network; config.remoteID = "fixture"; config.supportsImages = true; agent.configuration = config
                }
                if ProcessInfo.processInfo.arguments.contains("--canvas-maintenance-fixture"), let store {
                    let path = "日本語/Практика.studycanvas"
                    let loaded = try await store.load(path)
                    try await store.save(path, content: loaded.content, expectedRevision: loaded.revision,
                        assets: ["assets/obsolete.drawing": Data(repeating: 1, count: 128 * 1024)])
                }
            } catch { self.error = error.localizedDescription }
            return
        }
        let legacyLocal = Self.legacyLocalVaultURL
        if let bookmark = UserDefaults.standard.data(forKey: "vault-bookmark") {
            do {
                var stale = false
                #if targetEnvironment(macCatalyst)
                let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
                #else
                let options: URL.BookmarkResolutionOptions = []
                #endif
                let url = try URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale)
                if !Self.isSameLocation(url, legacyLocal) {
                    try await openVault(url)
                    return
                }
                // Older versions remembered their automatic on-device vault as if
                // the user had explicitly selected it. Ignore that bookmark so the
                // upgraded app can move to its iCloud container automatically.
                UserDefaults.standard.removeObject(forKey: "vault-bookmark")
            } catch {
                self.error = String.localizedStringWithFormat(
                    String(localized: "Папка недоступна: %@. Выберите её повторно."),
                    error.localizedDescription
                )
                showFolderPicker = true
            }
        }
        if let cloud = await Self.defaultICloudVaultURL() {
            do {
                try Self.copyLegacyVaultIfNeeded(from: legacyLocal, to: cloud)
                try await openVault(cloud, remember: false, iCloud: true)
                if entries.isEmpty { try await seed() }
                return
            } catch {
                self.error = String.localizedStringWithFormat(
                    String(localized: "Не удалось открыть iCloud: %@. Yohaku продолжит работу локально."),
                    error.localizedDescription
                )
            }
        } else {
            self.error = String(localized: "iCloud Drive недоступен. Войдите в iCloud и включите iCloud Drive; до этого Yohaku сохранит заметки только на устройстве.")
        }
        do {
            try await openVault(legacyLocal, remember: false, iCloud: false)
            if entries.isEmpty { try await seed() }
        } catch { self.error = error.localizedDescription }
    }
    func recoverDailyLesson(context: UUID) async {
        guard dailyLessonContext == context, dailyLessonVaultReady else { return }
        guard await flashcards.recoverSavedVersion(), dailyLessonContext == context, dailyLessonVaultReady else { return }
        await materials.recover(cards: flashcards)
    }

    func openVault(_ url: URL, remember: Bool = true, iCloud: Bool? = nil) async throws {
        let context = UUID(); dailyLessonContext = context; dailyLessonVaultReady = false
        resetKnowledgeSearch()
        navigationGeneration = UUID(); sourceNavigation = nil
        studyEpoch = UUID(); cancelMarkdownStudy(); agent.cancel(); await saveAll()
        guard dailyLessonContext == context else { throw StudyImportError.staleVault }
        guard !sessions.values.contains(where: { $0.isDirty }) else { throw StudyError.modelUnavailable("Сначала сохраните изменения или разрешите конфликт в текущем хранилище.") }
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        accessURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { accessURL = url } else { accessURL = nil }
        let store = VaultStore(root: url); try await store.prepare()
        let identifier = try await store.identifier()
        guard dailyLessonContext == context else { throw StudyImportError.staleVault }
        self.store = store; root = url; vaultID = identifier; sessions = [:]; activePath = nil; secondaryPath = nil
        materials.close()
        sourceNavigation = nil
        await flashcards.open(vaultRoot: url)
        guard dailyLessonContext == context else { throw StudyImportError.staleVault }
        await materials.open(vaultRoot: url, cards: flashcards)
        guard dailyLessonContext == context else { throw StudyImportError.staleVault }
        await refreshStudyMaterials()
        guard dailyLessonContext == context else { throw StudyImportError.staleVault }
        isUsingICloud = iCloud ?? Self.isUbiquitous(url)
        #if targetEnvironment(macCatalyst)
        let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let bookmarkOptions: URL.BookmarkCreationOptions = .minimalBookmark
        #endif
        if remember, let bookmark = try? url.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "vault-bookmark")
        }
        let loadedEntries = try await store.list()
        guard dailyLessonContext == context else { throw StudyImportError.staleVault }
        entries = loadedEntries
        do { try await store.reconcileKnowledge() }
        catch { if dailyLessonContext == context { knowledgeSearchError = error.localizedDescription } }
        guard dailyLessonContext == context else { throw StudyImportError.staleVault }
        let presenter = VaultPresenter(url: url, changed: { [weak self] in await self?.refresh() }, moved: { [weak self] old, new in await self?.externalMove(old, to: new) })
        self.presenter = presenter; NSFileCoordinator.addFilePresenter(presenter)
        if let data = UserDefaults.standard.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(SavedTabs.self, from: data) {
            tabs = saved.tabs.filter { tab in entries.contains { $0.path == tab.path } }
            for tab in tabs {
                do {
                    guard try await store.isAvailableLocally(tab.path) else { continue }
                    try await load(tab.path)
                }
                catch { self.error = String.localizedStringWithFormat(String(localized: "Не удалось открыть %@: %@"), tab.path, error.localizedDescription) }
            }
            activePath = saved.active.flatMap { sessions[$0] != nil ? $0 : nil } ?? tabs.first(where: { sessions[$0.path] != nil })?.path
            secondaryPath = saved.secondary.flatMap { sessions[$0] != nil ? $0 : nil }
        } else { tabs = [] }
        guard dailyLessonContext == context else { throw StudyImportError.staleVault }
        dailyLessonVaultReady = true
        if !query.isEmpty { search() }
    }

    func useDefaultICloudVault() async {
        guard let cloud = await Self.defaultICloudVaultURL() else {
            error = String(localized: "iCloud Drive недоступен. Войдите в iCloud и включите iCloud Drive.")
            return
        }
        do {
            try Self.copyLegacyVaultIfNeeded(from: Self.legacyLocalVaultURL, to: cloud)
            try await openVault(cloud, remember: false, iCloud: true)
            UserDefaults.standard.removeObject(forKey: "vault-bookmark")
            if entries.isEmpty { try await seed() }
        } catch {
            self.error = String.localizedStringWithFormat(String(localized: "Не удалось открыть iCloud: %@"), error.localizedDescription)
        }
    }

    nonisolated static var legacyLocalVaultURL: URL {
        URL.documentsDirectory.appendingPathComponent("Yohaku", isDirectory: true)
    }

    nonisolated static func defaultICloudVaultURL() async -> URL? {
        await Task.detached(priority: .userInitiated) {
            FileManager.default
                .url(forUbiquityContainerIdentifier: iCloudContainerIdentifier)?
                .appendingPathComponent("Documents", isDirectory: true)
        }.value
    }

    nonisolated static func isSameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }

    nonisolated static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    /// Preserve an existing on-device vault when upgrading to the iCloud-first
    /// version. The local copy remains as a recovery copy; migration only runs
    /// while the cloud document scope has no user-visible content.
    @discardableResult
    nonisolated static func copyLegacyVaultIfNeeded(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: source.path) else { return false }
        let sourceItems = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" }
        guard !sourceItems.isEmpty else { return false }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let cloudItems = try fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" && $0.lastPathComponent != ".workspace" }
        guard cloudItems.isEmpty else { return false }

        for sourceItem in sourceItems {
            let target = destination.appendingPathComponent(sourceItem.lastPathComponent)
            try copyMissingItem(from: sourceItem, to: target, fileManager: fileManager)
        }
        return true
    }

    nonisolated private static func copyMissingItem(from source: URL, to target: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
        if !fileManager.fileExists(atPath: target.path) {
            try fileManager.copyItem(at: source, to: target)
            return
        }
        guard isDirectory.boolValue else { return }
        for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try copyMissingItem(
                from: child,
                to: target.appendingPathComponent(child.lastPathComponent),
                fileManager: fileManager
            )
        }
    }
    private struct SavedTabs: Codable { var tabs: [DocumentTab]; var active: String?; var secondary: String? }
    func persistTabs() {
        if let data = try? JSONEncoder().encode(SavedTabs(tabs: tabs, active: activePath, secondary: secondaryPath)) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
    func refresh() async {
        guard let store, !refreshing else { return }; refreshing = true; defer { refreshing = false }
        do {
            entries = try await store.list()
            guard self.store === store else { return }
            for session in sessions.values { await session.refresh() }
            guard self.store === store else { return }
            await refreshStudyMaterials()
            guard self.store === store else { return }
            do { try await store.reconcileKnowledge() } catch { knowledgeSearchError = error.localizedDescription }
            guard self.store === store else { return }
            invalidateSourceNavigation()
            if let path = activePath { backlinks = try await store.backlinks(to: path) }
            if !query.isEmpty { search() }
        } catch { self.error = error.localizedDescription }
    }
    private func resetKnowledgeSearch() {
        searchTask?.cancel(); searchGeneration = UUID()
        knowledgeResults = []; searchResults = []; knowledgeCoverage = nil
        knowledgeNextCursor = nil; knowledgeSearchError = nil; knowledgeSearching = false
    }
    func search(loadMore: Bool = false) {
        searchTask?.cancel()
        let query = query, generation = UUID(), cursor = loadMore ? knowledgeNextCursor : nil
        searchGeneration = generation
        if !loadMore { knowledgeResults = []; searchResults = []; knowledgeCoverage = nil; knowledgeNextCursor = nil }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let store else {
            knowledgeSearching = false; return
        }
        knowledgeSearching = true; knowledgeSearchError = nil
        searchTask = Task {
            defer { if searchGeneration == generation { knowledgeSearching = false } }
            do {
                if !loadMore { try await Task.sleep(for: .milliseconds(200)) }
                guard searchIsCurrent(store, query: query, generation: generation) else { return }
                let page = try await store.searchKnowledge(.init(query: query, cursor: cursor))
                guard searchIsCurrent(store, query: query, generation: generation) else { return }
                knowledgeResults = loadMore ? knowledgeResults + page.hits : page.hits
                knowledgeCoverage = page.coverage; knowledgeNextCursor = page.nextCursor
            } catch is CancellationError {} catch {
                guard searchIsCurrent(store, query: query, generation: generation) else { return }
                knowledgeSearchError = error.localizedDescription
                // Keep the established text search usable while the disposable index is unavailable.
                let fallback = (try? await store.search(query)) ?? []
                guard searchIsCurrent(store, query: query, generation: generation) else { return }
                searchResults = fallback; knowledgeNextCursor = nil
            }
        }
    }
    private func searchIsCurrent(_ store: VaultStore, query: String, generation: UUID) -> Bool {
        !Task.isCancelled && self.store === store && self.query == query && searchGeneration == generation
    }
    func rebuildKnowledgeIndex() {
        searchTask?.cancel(); let generation = UUID(); searchGeneration = generation
        guard let store else { return }
        knowledgeSearching = true
        searchTask = Task {
            do {
                try await store.rebuildKnowledge()
                guard !Task.isCancelled, self.store === store, searchGeneration == generation else { return }
                knowledgeSearching = false; search()
            } catch {
                guard !Task.isCancelled, self.store === store, searchGeneration == generation else { return }
                knowledgeSearching = false; knowledgeSearchError = error.localizedDescription
            }
        }
    }
    func open(_ path: String, secondary: Bool = false, pageID: UUID? = nil) async {
        let generation = UUID(); navigationGeneration = generation
        if !secondary { sourceNavigation = nil }
        await openDocument(path, secondary: secondary, pageID: pageID, generation: generation)
    }
    private func openDocument(_ path: String, secondary: Bool, pageID: UUID?, generation: UUID) async {
        do {
            if !secondary, let activePath, activePath != path {
                await sessions[activePath]?.save()
            }
            guard navigationGeneration == generation else { return }
            try await load(path)
            guard navigationGeneration == generation else { return }
            if !tabs.contains(where: { $0.path == path }) { tabs.append(DocumentTab(path: path, pageID: pageID)) }
            else if let pageID, let i = tabs.firstIndex(where: { $0.path == path }) { tabs[i].pageID = pageID }
            if secondary { secondaryPath = path } else { activePath = path }
            let links = try await store?.backlinks(to: path) ?? []
            guard navigationGeneration == generation else { return }
            backlinks = links; persistTabs()
        } catch { self.error = error.localizedDescription }
    }
    func open(_ source: SourceContext) async {
        let generation = UUID(); navigationGeneration = generation; sourceNavigation = nil
        if let region = source.region,
           (![region.x, region.y, region.width, region.height, region.x + region.width, region.y + region.height].allSatisfy(\.isFinite) || region.width <= 0 || region.height <= 0) {
            error = String(localized: "Некорректная область источника.")
            return
        }
        do {
            try await load(source.path)
            guard navigationGeneration == generation else { return }
            guard let session = sessions[source.path] else { return }
            let targetPage = source.pageID ?? tabs.first(where: { $0.path == source.path })?.pageID ?? session.content.pages.first?.id
            if let targetPage, !session.content.pages.contains(where: { $0.id == targetPage }) {
                error = String(localized: "Страница источника больше не существует.")
                return
            }
            await openDocument(source.path, secondary: false, pageID: targetPage, generation: generation)
            if navigationGeneration == generation, let targetPage, activePath == source.path, sessions[source.path] === session {
                sourceNavigation = .init(path: source.path, pageID: targetPage, region: source.region)
            }
        } catch { self.error = error.localizedDescription }
    }
    func completeSourceNavigation(_ id: UUID) {
        guard sourceNavigation?.id == id else { return }
        sourceNavigation = nil
        persistTabs()
    }
    func invalidateSourceNavigation() {
        guard let request = sourceNavigation else { return }
        if sessions[request.path]?.content.pages.contains(where: { $0.id == request.pageID }) != true {
            sourceNavigation = nil
        }
    }
    private func load(_ path: String) async throws {
        guard let store, sessions[path] == nil else { return }
        let loaded = try await store.load(path)
        let session = DocumentSession(path: path, loaded: loaded, store: store)
        sessions[path] = session
        // Run conflict recovery on first open as well as on later presenter
        // notifications. Resolved-but-not-removed versions left by older builds
        // may otherwise never generate a fresh iCloud change callback.
        await session.refresh()
        await session.save()
        if session.conflictPath != nil { entries = try await store.list() }
    }
    func close(_ path: String) async {
        navigationGeneration = UUID()
        await sessions[path]?.save()
        guard sessions[path]?.isDirty != true else { error = String(localized: "Документ ещё не сохранён."); return }
        tabs.removeAll { $0.path == path }
        if sourceNavigation?.path == path { sourceNavigation = nil }
        if activePath == path { activePath = tabs.first?.path }
        if secondaryPath == path { secondaryPath = nil }
        if chatPath != path { sessions[path] = nil }; persistTabs()
    }
    func saveAll() async { for session in sessions.values { await session.save() }; persistTabs() }
    func analyzeCanvasStorage(_ path: String) async throws -> CanvasStorageReport {
        guard let store else { throw StudyError.invalidPath }
        if let session = sessions[path] {
            await session.save()
            guard !session.isDirty, session.conflictPath == nil else { throw StudyError.modelUnavailable("Сначала сохраните документ и разрешите конфликт.") }
        }
        return try await store.analyzeCanvasStorage(path, keeping: sessions[path]?.protectedAssetNames ?? [])
    }
    func prepareCanvasCompaction(_ report: CanvasStorageReport) async throws -> PreparedCanvasCompaction {
        guard let store else { throw StudyError.invalidPath }
        let current = try await analyzeCanvasStorage(report.path)
        guard current.fingerprint == report.fingerprint else { throw StudyError.staleRevision }
        let backups = URL.applicationSupportDirectory.appendingPathComponent("Yohaku/CanvasBackups", isDirectory: true)
        return try await store.prepareCanvasCompaction(report, backupDirectory: backups)
    }
    func applyCanvasCompaction(_ prepared: PreparedCanvasCompaction) async throws {
        guard let store else { throw StudyError.invalidPath }
        let current = try await analyzeCanvasStorage(prepared.report.path)
        guard current.fingerprint == prepared.report.fingerprint else { throw StudyError.staleRevision }
        try await store.applyCanvasCompaction(prepared)
        await refresh()
    }
    func dropInactiveSessions() {
        sessions = sessions.filter { $0.key == activePath || $0.key == secondaryPath || $0.key == chatPath || $0.value.isDirty }
    }
    func create(_ name: String, kind: DocumentKind, folder: String = "") async {
        guard let store else { return }
        do {
            let path = (folder.isEmpty ? "" : folder + "/") + name + "." + kind.fileExtension
            try await store.create(path, kind: kind, text: kind == .markdown ? "# \(name)\n\n" : "")
            await refresh(); await open(path)
        } catch { self.error = error.localizedDescription }
    }
    func createFolder(_ path: String) async { do { try await store?.createFolder(path); await refresh() } catch { self.error = error.localizedDescription } }
    func move(_ path: String, to destination: String) async {
        await saveAll()
        guard !sessions.values.contains(where: \.isDirty) else { error = String(localized: "Сначала разрешите ошибки сохранения."); return }
        do {
            try await store?.move(path, to: destination)
            sourceNavigation = nil
            func mapped(_ old: String) -> String { old == path || old.hasPrefix(path + "/") ? destination + old.dropFirst(path.count) : old }
            var remapped: [String: DocumentSession] = [:]
            for (key, session) in sessions { let new = mapped(key); session.path = new; remapped[new] = session }
            sessions = remapped; tabs = tabs.map { var tab = $0; tab.path = mapped(tab.path); return tab }
            activePath = activePath.map(mapped); secondaryPath = secondaryPath.map(mapped); chatPath = chatPath.map(mapped)
            _ = await materials.remap(path, to: destination)
            await refresh(); persistTabs()
        } catch { self.error = error.localizedDescription }
    }
    func trash(_ path: String) async {
        navigationGeneration = UUID()
        func isInsideDeletedItem(_ candidate: String) -> Bool {
            candidate == path || candidate.hasPrefix(path + "/")
        }

        // A damaged package may no longer have manifest.json, so trying to save it
        // before deletion makes the recovery action itself impossible. Preserve all
        // unrelated work, but deliberately discard unsaved state under the item the
        // user chose to delete.
        for (sessionPath, session) in sessions where !isInsideDeletedItem(sessionPath) { await session.save() }
        guard !sessions.contains(where: { !isInsideDeletedItem($0.key) && $0.value.isDirty }) else {
            error = String(localized: "Сначала сохраните документы.")
            return
        }

        let removedSessions = sessions.filter { isInsideDeletedItem($0.key) }
        for session in removedSessions.values { await session.suspendSavingForDeletion() }
        for sessionPath in removedSessions.keys { sessions[sessionPath] = nil }
        let previousChatPath = chatPath
        if let chatPath, isInsideDeletedItem(chatPath) { self.chatPath = nil }
        do {
            try await store?.trash(path)
            tabs.removeAll { isInsideDeletedItem($0.path) }
            if let activePath, isInsideDeletedItem(activePath) { self.activePath = tabs.first?.path }
            if let secondaryPath, isInsideDeletedItem(secondaryPath) { self.secondaryPath = nil }
            if let pendingContext, isInsideDeletedItem(pendingContext.path) { self.pendingContext = nil }
            if let request = sourceNavigation, isInsideDeletedItem(request.path) { sourceNavigation = nil }
            if let previousChatPath, isInsideDeletedItem(previousChatPath) { agent.cancel() }
            if activePath == nil { backlinks = [] }
            await refresh()
            persistTabs()
            error = nil
        } catch {
            for (sessionPath, session) in removedSessions { sessions[sessionPath] = session }
            chatPath = previousChatPath
            self.error = error.localizedDescription
        }
    }
    func ask(_ context: SourceContext) { pendingContext = context; chatPath = context.path; showAgent = true }
    func openLink(_ link: String, source: String) {
        if let resolved = NoteLinks.resolve(link, source: source) {
            if entries.contains(where: { $0.isDirectory && $0.path == resolved.path }) {
                query = resolved.path
                search()
                return
            }
            let fragment = resolved.fragment?.replacingOccurrences(of: "page=", with: "")
            Task { await open(resolved.path, pageID: fragment.flatMap(UUID.init(uuidString:))) }
        } else if let url = URL(string: link), ["https", "http"].contains(url.scheme) { UIApplication.shared.open(url) }
        else { error = String(localized: "Ссылка недоступна.") }
    }
    func accept(_ proposal: ChangeProposal) async {
        do {
            if let session = sessions[proposal.path] { try await session.accept(proposal) }
            else { _ = try await store?.apply(proposal) }
            agent.proposals.removeAll { $0.id == proposal.id }; await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func externalMove(_ old: URL, to new: URL) async {
        guard let root, old.path.hasPrefix(root.path + "/"), new.path.hasPrefix(root.path + "/") else {
            error = String(localized: "Хранилище перемещено или доступ к нему изменился. Выберите папку повторно."); return
        }
        let oldPath = String(old.path.dropFirst(root.path.count + 1)), newPath = String(new.path.dropFirst(root.path.count + 1))
        guard entries.contains(where: { $0.path == oldPath }) || sessions[oldPath] != nil else { return }
        do {
            try await store?.reconcileExternalMove(oldPath, to: newPath)
            sourceNavigation = nil
            func mapped(_ path: String) -> String { path == oldPath || path.hasPrefix(oldPath + "/") ? newPath + path.dropFirst(oldPath.count) : path }
            var updated: [String: DocumentSession] = [:]
            for (key, session) in sessions { session.path = mapped(key); updated[mapped(key)] = session }
            sessions = updated
            tabs = tabs.map { var tab = $0; tab.path = mapped(tab.path); return tab }
            activePath = activePath.map(mapped); secondaryPath = secondaryPath.map(mapped); chatPath = chatPath.map(mapped)
            _ = await materials.remap(oldPath, to: newPath)
            persistTabs(); await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func seed() async throws {
        guard let store else { return }
        try await store.createFolder("日本語")
        var notebook = try await store.create("日本語/Практика.studycanvas", kind: .notebook)
        notebook.content.pages[0].paper.pattern = .japanese; notebook.content.pages[0].paper.spacing = 42
        notebook.content.pages[0].objects = [.init(kind: .text, frame: Rect(x: 42, y: 42, width: 500, height: 108), content: "はじめましょう\nМесто для новых слов и маленьких открытий.")]
        try await store.save("日本語/Практика.studycanvas", content: notebook.content, expectedRevision: notebook.revision)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--markdown-study-fixture") || ProcessInfo.processInfo.arguments.contains("--canvas-study-fixture") {
            _ = try await store.create("日本語/Источник.md", kind: .markdown, text: "---\nprivate: not sent\n---\n猫はかわいい。")
        }
        #endif
        try await store.create("日本語/Начало.md", kind: .markdown, text: """
        # Место для мысли

        **Yohaku · 余白** — свободное пространство на странице.

        Здесь можно писать, собирать знания и задавать вопросы.

        ## Сегодня

        - [ ] Открыть тетрадь и написать несколько иероглифов
        - [ ] Выделить фрагмент и спросить агента
        - [ ] Сохранить объяснение в заметку

        [Открыть тетрадь](Практика.studycanvas)

        > 少しずつ — понемногу, шаг за шагом.
        """
        )
        await refresh(); await open("日本語/Начало.md"); await open("日本語/Практика.studycanvas")
    }
}

private final class VaultPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let changed: @MainActor @Sendable () async -> Void
    let moved: @MainActor @Sendable (URL, URL) async -> Void
    init(url: URL, changed: @escaping @MainActor @Sendable () async -> Void, moved: @escaping @MainActor @Sendable (URL, URL) async -> Void) {
        presentedItemURL = url; self.changed = changed; self.moved = moved; super.init(); presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }
    func presentedItemDidChange() { Task { await changed() } }
    func presentedSubitemDidChange(at url: URL) { Task { await changed() } }
    func presentedSubitemDidAppear(at url: URL) { Task { await changed() } }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { Task { await moved(oldURL, newURL) } }
    func presentedItemDidMove(to newURL: URL) { if let presentedItemURL { Task { await moved(presentedItemURL, newURL) } } }
}
