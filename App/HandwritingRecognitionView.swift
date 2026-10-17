import StudyCanvas
import StudyCore
import SwiftUI

struct HandwritingRecognitionRequest: Identifiable {
    let id = UUID()
    let source: SourceContext
    let revision: String
    let store: VaultStore

    @MainActor func isCurrent(session: DocumentSession, workspace: WorkspaceModel) -> Bool {
        workspace.store === store && session.store === store && session.path == source.path
            && session.content.contentRevision == revision && !session.isDirty && session.conflictPath == nil
            && session.content.pages.contains { $0.id == source.pageID }
    }
}

struct HandwritingRecognitionView: View {
    let request: HandwritingRecognitionRequest
    @Bindable var session: DocumentSession
    @Bindable var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var language = LocalRecognitionLanguage.japanese
    @State private var running = false
    @State private var message = String(localized: "Выберите язык и запустите распознавание.")
    @State private var hits: [KnowledgeSearchHit] = []
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(request.source.path).textSelection(.enabled)
                    if let index = session.content.pages.firstIndex(where: { $0.id == request.source.pageID }) {
                        let title = session.content.pages[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
                        Text(String(localized: "Страница") + " \(index + 1)" + (title.isEmpty ? "" : " · " + title)).font(.caption)
                    }
                    Text(request.source.region == nil ? "Текущая страница" : "Выбранная область")
                    Text("Распознавание на устройстве. В поиске будет доступен только обработанный фрагмент.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Язык рукописи", selection: $language) {
                        Text("Японский").tag(LocalRecognitionLanguage.japanese)
                        Text("Русский").tag(LocalRecognitionLanguage.russian)
                        Text("Английский").tag(LocalRecognitionLanguage.english)
                    }.accessibilityIdentifier("handwriting-language").disabled(running)
                    Button("Распознать") { run() }
                        .disabled(running || !request.isCurrent(session: session, workspace: workspace))
                        .accessibilityIdentifier("handwriting-run")
                    if running {
                        ProgressView().accessibilityIdentifier("handwriting-loading")
                        Button("Отменить распознавание") { cancel() }
                            .accessibilityIdentifier("handwriting-cancel")
                    }
                    Text(message).accessibilityIdentifier("handwriting-status")
                }
                if !hits.isEmpty {
                    Section("Распознанный текст") {
                        ForEach(hits) { hit in
                            Button {
                                guard request.isCurrent(session: session, workspace: workspace) else { invalidate(); return }
                                Task { await workspace.open(hit.sourceContext); dismiss() }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hit.text)
                                    Text(hit.language ?? language.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                            }.accessibilityIdentifier("handwriting-observation-\(hit.id)")
                        }
                    }
                }
            }
            .navigationTitle("Распознать рукопись")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Готово") { cancel(); dismiss() }.accessibilityIdentifier("handwriting-done")
            } }
        }
        .accessibilityIdentifier("handwriting-sheet")
        .onDisappear { cancel() }
        .onChange(of: session.content.contentRevision) { _, _ in invalidate() }
        .onChange(of: session.path) { _, _ in invalidate() }
        .onChange(of: workspace.root) { _, _ in invalidate() }
        .onChange(of: workspace.store.map(ObjectIdentifier.init)) { _, _ in invalidate() }
        .onChange(of: session.conflictPath) { _, _ in invalidate() }
    }

    private func valid(_ operation: UUID) -> Bool {
        !Task.isCancelled && generation == operation && request.isCurrent(session: session, workspace: workspace)
    }
    private func run() {
        cancel(); let operation = UUID(); generation = operation
        let selectedLanguage = language
        running = true; hits = []; message = String(localized: "Распознавание…")
        task = Task { @MainActor in
            defer { if generation == operation { running = false } }
            do {
                guard valid(operation) else { if generation == operation { invalidate() }; return }
                let snapshot = try await request.store.knowledgeSnapshot(request.source.path,
                    pageID: request.source.pageID, region: request.source.region, includeAssets: true)
                guard valid(operation), snapshot.sourceFingerprint == request.revision else { if generation == operation { invalidate() }; return }
                let output = try await LocalHandwritingRecognition.recognize(snapshot, language: selectedLanguage)
                guard valid(operation) else { if generation == operation { invalidate() }; return }
                let fragments = output.observations.enumerated().map { offset, observation in
                    KnowledgeSearchHit(id: output.runFingerprint + ":\(offset)", path: output.source.path,
                        pageID: output.source.pageID, region: observation.worldRect, text: observation.text,
                        provenance: .ocr, sourceFingerprint: output.sourceFingerprint,
                        language: observation.language, confidence: observation.confidence,
                        runFingerprint: output.runFingerprint, engineFingerprint: output.engineVersion)
                }
                try await request.store.commitRecognition(fragments, matching: snapshot,
                    state: output.state == .empty ? .empty : .partial)
                guard valid(operation) else { if generation == operation { invalidate() }; return }
                hits = fragments
                message = output.state == .empty ? String(localized: "Текст не найден в выбранном фрагменте.")
                    : String(localized: "Фрагмент распознан и добавлен в локальный поиск.")
                workspace.search()
            } catch is CancellationError {
                if generation == operation { message = String(localized: "Распознавание отменено.") }
            } catch {
                guard valid(operation) else { if generation == operation { invalidate() }; return }
                message = recognitionMessage(error)
            }
        }
    }
    private func cancel() {
        generation = UUID(); task?.cancel(); task = nil; running = false
        message = String(localized: "Распознавание отменено.")
    }
    private func invalidate() {
        cancel(); hits = []; message = String(localized: "Источник изменился. Закройте окно и выберите фрагмент заново.")
    }
    private func recognitionMessage(_ error: Error) -> String {
        switch error {
        case LocalRecognitionError.unsupportedSource:
            String(localized: "Этот источник не поддерживает распознавание.")
        case LocalRecognitionError.missingAssets:
            String(localized: "Отсутствуют файлы рисунка или изображения. Источник не изменён.")
        case LocalRecognitionError.unavailableAssets, KnowledgeSnapshotError.sourceUnavailable:
            String(localized: "Источник недоступен локально. Скачайте его из iCloud и повторите.")
        case LocalRecognitionError.unavailableLanguage:
            String(localized: "Выбранный язык недоступен для распознавания на этом устройстве.")
        case LocalRecognitionError.invalidRegion, KnowledgeSnapshotError.invalidRegion,
             KnowledgeSnapshotError.explicitRegionRequired, KnowledgeSnapshotError.byteLimitExceeded,
             KnowledgeSnapshotError.assetLimitExceeded:
            String(localized: "Выберите меньшую область для распознавания.")
        case KnowledgeIndexError.staleSource:
            String(localized: "Источник изменился. Закройте окно и выберите фрагмент заново.")
        default:
            String(localized: "Не удалось распознать фрагмент.") + " " + error.localizedDescription
        }
    }
}
