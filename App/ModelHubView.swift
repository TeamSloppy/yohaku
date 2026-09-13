import StudyIntelligence
import SwiftUI

struct ModelHubView: View {
    @Bindable var agent: AgentSession
    @State private var browser = ModelBrowser()
    @State private var showAccess = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section { DeviceProfileView(profile: browser.profile, refresh: browser.refreshProfile) }
                Section {
                    Picker("Режим", selection: $browser.mode) {
                        ForEach(ModelBrowser.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).onChange(of: browser.mode) { browser.changeMode() }
                    Picker("Задача", selection: $browser.taskKind) {
                        ForEach(ModelBrowser.TaskKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.onChange(of: browser.taskKind) { browser.search() }
                    if browser.mode == .all {
                        Toggle("Только MLX-версии", isOn: $browser.mlxOnly).onChange(of: browser.mlxOnly) { browser.search() }
                    } else {
                        Text("Живой поиск MLX-моделей до \(browser.maximumParameters / 1_000_000_000)B параметров. Затем проверяются реальные размеры файлов и архитектура. Во вкладке «Каталог HF» ограничение размера снято.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let error = browser.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                        Button("Повторить поиск") { browser.search() }
                    }
                    if browser.loading {
                        HStack { ProgressView(); Text("Проверено \(browser.inspected) из \(browser.models.count)").font(.caption); Spacer(); Button("Остановить") { browser.cancel() } }
                    }
                    if browser.visibleModels.isEmpty && !browser.loading && browser.error == nil {
                        Text(browser.mode == .recommended ? "Среди проверенных моделей пока нет подходящих по оценке. Измените задачу, запрос или откройте весь каталог." : "Модели не найдены.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(browser.visibleModels) { model in
                        NavigationLink {
                            HFModelDetailView(model: model, browser: browser, agent: agent) { inspection in
                                choose(inspection); dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(model.id).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                                HStack(spacing: 10) {
                                    if model.gated || model.isPrivate { Image(systemName: "lock") }
                                    Text(model.task ?? "Задача не указана").lineLimit(1)
                                    Spacer(); Label(model.downloads.formatted(), systemImage: "arrow.down")
                                }.font(.caption2).foregroundStyle(.secondary)
                                if let assessment = browser.assessment(model.id) {
                                    Label(assessment.title, systemImage: symbol(assessment.status)).font(.caption).foregroundStyle(color(assessment.status))
                                    if let info = browser.inspections[model.id] {
                                        Text("Веса: \(DeviceModelProfile.size(info.repository.weightBytes)) · RAM ≈ \(DeviceModelProfile.size(assessment.estimatedMemory))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                } else if browser.inspectionErrors[model.id] != nil {
                                    Text("Метаданные недоступны — откройте карточку").font(.caption).foregroundStyle(.secondary)
                                } else { Text("Оценка ещё не выполнена").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 5)
                        }
                    }
                    if browser.nextPage != nil { Button("Проверить следующие модели") { browser.loadMore() }.disabled(browser.loading) }
                } header: {
                    Text(browser.mode == .recommended ? "Кандидаты · \(browser.visibleModels.count) из \(browser.models.count)" : "Каталог · \(browser.models.count)")
                } footer: {
                    Text("Кандидат — оценка совместимости и памяти, а не гарантия скорости или качества. Модель устройства и объём RAM не отправляются в Hugging Face: Hub получает поисковый запрос и фильтры.")
                }
            }
            .navigationTitle("Hugging Face")
            .searchable(text: $browser.query, prompt: "Название, автор или ID модели")
            .onChange(of: browser.query) { browser.search(debounced: true) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { showAccess = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Доступ Hugging Face") }
            }
            .task { if browser.models.isEmpty { browser.search() } }
            .sheet(isPresented: $showAccess) { HFTokenView { browser.search() } }
        }.onDisappear { browser.cancel() }
    }
    private func choose(_ inspection: HFInspection) {
        agent.configuration.localID = inspection.model.id
        agent.configuration.supportsImages = inspection.supportsImages ?? false
        // The current local streaming backends do not promise tool calling for arbitrary Hub models.
        agent.configuration.supportsTools = false
    }
    private func symbol(_ status: ModelDeviceAssessment.Status) -> String {
        switch status { case .candidate: "checkmark.circle"; case .tight: "exclamationmark.circle"; case .tooLarge: "memorychip"; case .unsupported: "nosign"; case .unknown: "questionmark.circle" }
    }
    private func color(_ status: ModelDeviceAssessment.Status) -> Color { status == .candidate ? Palette.accent : status == .tight || status == .tooLarge ? .orange : .secondary }
}

struct DeviceProfileView: View {
    let profile: DeviceModelProfile
    let refresh: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Label(profile.name, systemImage: "ipad").font(.headline); Spacer(); Button(action: refresh) { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Обновить характеристики") }
            Text(profile.systemVersion).font(.caption).foregroundStyle(.secondary)
            LabeledContent(profile.isSimulator ? "RAM среды симулятора" : "Физическая RAM", value: DeviceModelProfile.size(profile.physicalMemory))
            LabeledContent("Доступно процессу сейчас", value: DeviceModelProfile.size(profile.availableMemory))
            LabeledContent("Свободно на накопителе", value: DeviceModelProfile.size(profile.freeStorage))
            LabeledContent("GPU", value: profile.gpuName ?? "Metal недоступен")
            Text("Бюджет подбора: \(DeviceModelProfile.size(profile.memoryBudget)). Это запас для модели; интерфейсу и системе тоже нужна память.").font(.caption).foregroundStyle(.secondary)
            if profile.isSimulator { Text("Подбор в симуляторе использует условный профиль 4 ГБ. На физическом устройстве будут прочитаны его реальные характеристики.").font(.caption).foregroundStyle(.secondary) }
        }.font(.subheadline).padding(.vertical, 6)
    }
}

struct HFModelDetailView: View {
    let model: HFModel
    @Bindable var browser: ModelBrowser
    @Bindable var agent: AgentSession
    let choose: (HFInspection) -> Void
    @State private var detail: HFInspection?
    @State private var error: String?
    @State private var loading = false
    @State private var showAccess = false
    private var assessment: ModelDeviceAssessment? { detail.map { ModelDeviceAssessment.evaluate($0, device: browser.profile) } }
    var body: some View {
        List {
            Section {
                Text(model.id).font(.headline).textSelection(.enabled)
                Link("Открыть полную страницу на Hugging Face", destination: model.modelURL)
                if model.gated || model.isPrivate {
                    Label("Может потребоваться read token и разрешение автора модели.", systemImage: "lock").font(.caption)
                    Button("Настроить доступ") { showAccess = true }
                }
            }
            if loading { ProgressView("Чтение конфигурации и размеров файлов…") }
            if let error { Section { Text(error).foregroundStyle(.orange); Button("Повторить") { Task { await load(refresh: true) } }; Button("Read token") { showAccess = true } } }
            if let detail, let assessment {
                Section("Оценка для \(browser.profile.name)") {
                    Text(assessment.title).font(.headline)
                    Text(assessment.reason)
                    LabeledContent("Веса", value: DeviceModelProfile.size(detail.repository.weightBytes))
                    LabeledContent("Загрузка", value: DeviceModelProfile.size(detail.repository.downloadBytes))
                    LabeledContent("RAM, оценка", value: DeviceModelProfile.size(assessment.estimatedMemory))
                    Text("Оценка = 2 × размер весов + 512 МиБ. Она не измеряет активации конкретной архитектуры; реальный пик может отличаться.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Модель") {
                    LabeledContent("Архитектура", value: detail.modelType ?? "неизвестна")
                    LabeledContent("Формат MLX", value: detail.isMLX ? "Да" : "Не подтверждён")
                    LabeledContent("Изображения", value: detail.supportsImages.map { $0 ? "Да" : "Нет" } ?? "Неизвестно")
                    LabeledContent("Квантование", value: detail.quantizationBits.map { "\($0) бит" } ?? "Не указано")
                    LabeledContent("Лицензия", value: detail.license ?? "Смотрите карточку модели")
                    Text("Revision: \(detail.repository.sha)").font(.caption2).textSelection(.enabled)
                }
                Section {
                    if ModelCatalog.isDownloaded(model.id) {
                        Button("Использовать скачанную модель") { choose(detail) }.disabled(agent.running || agent.downloads.running || !assessment.canDownload)
                    } else {
                        Button("Скачать и выбрать") {
                            agent.downloads.download(model.id, inspection: detail); choose(detail)
                        }.disabled(agent.running || agent.downloads.running || !assessment.canDownload)
                    }
                    Button("Выбрать без скачивания") { choose(detail) }.disabled(agent.running || agent.downloads.running || !assessment.canDownload)
                    if !assessment.canDownload { Text("Каталог открыт полностью. Для запуска этой модели нужен другой формат, адаптер или больше ресурсов.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("Карточка модели").navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .sheet(isPresented: $showAccess) { HFTokenView { Task { await load(refresh: true) } } }
    }
    private func load(refresh: Bool = false) async {
        loading = true; error = nil
        do { detail = try await browser.inspection(model.id, refresh: refresh) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct HFTokenView: View {
    let onSave: () -> Void
    @State private var token = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Доступ к Hub") {
                    Text("Публичные модели доступны без аккаунта. Для приватных и закрытых моделей укажите свой read token.")
                    SecureField("hf_…", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Link("Создать read token на Hugging Face", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                    Text("Токен хранится в Keychain этого устройства. Доступ и условия закрытых моделей подтверждаются вами на их страницах.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Button("Удалить сохранённый токен", role: .destructive) { token = ""; save() }
            }.navigationTitle("Hugging Face · доступ")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Сохранить") { save() } }
                }.onAppear { token = HFTokenStore.read() }
        }
    }
    private func save() {
        do { try HFTokenStore.save(token); onSave(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
