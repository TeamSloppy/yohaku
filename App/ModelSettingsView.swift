import StudyIntelligence
import SwiftUI

struct ModelSettingsView: View {
    @Bindable var agent: AgentSession
    @Environment(\.dismiss) private var dismiss
    @State private var keyError: String?
    @State private var networkSettings = NetworkModelSettingsState()
    @State private var pronunciationSettings = PronunciationServiceSettings()
    @State private var showHub = false
    @State private var profile = DeviceModelProfile.capture()
    var body: some View {
        NavigationStack {
            Form {
                Section("Где работает модель") {
                    Picker("Провайдер", selection: $agent.configuration.provider) {
                        Text("На устройстве · MLX").tag(ModelConfiguration.Provider.local)
                        Text("OpenAI / совместимый API").tag(ModelConfiguration.Provider.network)
                        Text("Codex · Device code").tag(ModelConfiguration.Provider.codex)
                        Text("Сервер Sloppy").tag(ModelConfiguration.Provider.sloppy)
                    }.pickerStyle(.menu).disabled(agent.running).accessibilityIdentifier("model-provider-picker")
                }
                if agent.configuration.provider == .local {
                    Section("Это устройство") { DeviceProfileView(profile: profile) { profile = .capture() } }
                    Section("Локальная модель") {
                        Button { showHub = true } label: { Label("Каталог Hugging Face и подбор", systemImage: "magnifyingglass") }.accessibilityIdentifier("open-huggingface-catalog")
                        TextField("ID модели или ссылка Hugging Face", text: $agent.configuration.localID).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(agent.downloads.running || agent.running)
                        Text(ModelCatalog.isDownloaded(agent.configuration.localID) ? String(localized: "Скачана · готова к загрузке в память") : String(localized: "Файлы модели ещё не скачаны")).font(.caption).foregroundStyle(.secondary)
                        if agent.downloads.running {
                            ProgressView(value: agent.downloads.progress)
                            Button("Остановить загрузку") { agent.downloads.cancel() }
                        } else {
                            Button("Скачать / продолжить", systemImage: "arrow.down.circle") {
                                if let id = ModelCatalog.normalizedID(agent.configuration.localID) { agent.configuration.localID = id }
                                agent.downloads.download(agent.configuration.localID)
                            }.disabled(agent.running)
                            if ModelCatalog.isDownloaded(agent.configuration.localID) {
                                Button("Удалить с устройства", role: .destructive) {
                                    Task { await agent.releaseMemory(); do { try agent.downloads.remove(agent.configuration.localID) } catch { keyError = error.localizedDescription } }
                                }.disabled(agent.running)
                            }
                        }
                        if !agent.downloads.status.isEmpty { Text(agent.downloads.status).font(.caption) }
                        Text(ModelCatalog.entry(for: agent.configuration.localID)?.detail ?? String(localized: "Для снимков нужна vision-модель. Совместимость пользовательских моделей зависит от адаптера MLX.")).font(.caption).foregroundStyle(.secondary)
                        Text("На устройстве с 4 ГБ: короткий контекст, до 256 токенов ответа. После запроса модель освобождается из памяти.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    NetworkModelSettingsView(agent: agent, state: networkSettings)
                }
                Section("Возможности выбранной модели") {
                    if agent.configuration.provider == .local, let model = ModelCatalog.entry(for: agent.configuration.localID) {
                        Label(model.images ? String(localized: "Изображения поддерживаются") : String(localized: "Только текст"), systemImage: model.images ? "photo" : "text.alignleft")
                        Text("Эти компактные модели отвечают без инструментов агента.").font(.caption).foregroundStyle(.secondary)
                    } else {
                    Toggle("Поддерживает изображения", isOn: $agent.configuration.supportsImages)
                    Toggle("Поддерживает вызов инструментов", isOn: $agent.configuration.supportsTools)
                    Text("Укажите возможности по карточке модели. Наличие поддержки в провайдере не гарантирует её в конкретной модели.").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(agent.running)
                PronunciationServiceSettingsView(settings: pronunciationSettings)
                Section("Об этом пространстве") {
                    Text("Yohaku · 余白").font(.headline)
                    Text("Заметки сохраняются в выбранной папке. iCloud Drive переносит файлы средствами системы. Локальная ошибка никогда не переключает модель на сеть.").font(.caption).foregroundStyle(.secondary)
                    if let duration = agent.lastDuration { Text("Последний ответ: \(duration)").font(.caption) }
                    if let peak = agent.lastLocalPeakMiB { Text("Пик памяти MLX: \(peak) МиБ (без интерфейса и системы)").font(.caption) }
                }
                if let keyError { Text(keyError).foregroundStyle(.orange) }
            }.navigationTitle("Модели и настройки").toolbar { Button("Готово") { dismiss() } }
                .sheet(isPresented: $showHub) { ModelHubView(agent: agent) }
        }
        .onAppear { networkSettings.configure(agent.configuration) }
        .onChange(of: agent.configuration.provider) { _, _ in networkSettings.configure(agent.configuration) }
        .onChange(of: agent.configuration.credentialAccount) { _, _ in networkSettings.configure(agent.configuration) }
        .onDisappear { networkSettings.cancel() }
        .presentationDetents([.large])
    }
}

private struct PronunciationServiceSettingsView: View {
    @Bindable var settings: PronunciationServiceSettings

    var body: some View {
        Section("Японское произношение") {
            Picker("Источник примера", selection: $settings.provider) {
                ForEach(PronunciationProvider.allCases, id: \.self) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .accessibilityIdentifier("pronunciation-provider-picker")
            if settings.provider == .forvo {
                SecureField("Forvo API key", text: $settings.forvoKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("forvo-api-key")
                Button("Сохранить ключ Forvo") { settings.save() }
                    .accessibilityIdentifier("save-pronunciation-services")
            }
            if !settings.status.isEmpty {
                Text(settings.status).font(.caption).foregroundStyle(.secondary)
            }
            Text(settings.provider == .kanjiAlive
                 ? "Kanji alive загружает примеры слов с аудио на GitHub. Данные Kanji alive · CC BY 4.0."
                 : "Forvo загружает произношение выбранного слова. Ваша запись и её анализ остаются на устройстве и обрабатываются Apple Speech и AVFoundation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
