import StudyIntelligence
import SwiftUI
import UIKit

struct NetworkModelSettingsView: View {
    @Bindable var agent: AgentSession
    @Environment(\.openURL) private var openURL
    @Bindable var state: NetworkModelSettingsState

    var body: some View {
        Group {
            if agent.configuration.provider == .codex {
                Section("Авторизация Codex") {
                    Label(
                        state.connected ? String(localized: "Codex подключён") : String(localized: "Вход с аккаунтом ChatGPT"),
                        systemImage: state.connected ? "checkmark.circle" : "person.crop.circle"
                    )
                    if let device = state.device {
                        Text(device.code).font(.title2.monospaced().bold()).textSelection(.enabled).accessibilityIdentifier("codex-device-code")
                        Button("Скопировать код") { UIPasteboard.general.string = device.code }
                        Link("Открыть окно входа Codex", destination: device.url)
                        Text("Введите этот код в окне авторизации.").font(.caption).foregroundStyle(.secondary)
                    }
                    if state.signingIn {
                        ProgressView("Ожидание подтверждения…")
                        Button("Отменить вход") { state.cancelLogin() }
                    } else {
                        Button(state.connected ? String(localized: "Войти в другой аккаунт Codex") : String(localized: "Войти в Codex")) { state.startLogin { openURL($0) } }
                            .accessibilityIdentifier("codex-sign-in")
                    }
                    if state.connected {
                        Button("Отключить Codex", role: .destructive) {
                            state.disconnect()
                        }
                    }
                    Link("Включить device code login в ChatGPT", destination: URL(string: "https://chatgpt.com/security-settings")!)
                    Text("Yohaku открывает страницу входа Codex. Авторизация сохраняется в Keychain этого устройства.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Модель Codex") {
                    modelPicker(selection: $agent.configuration.codexModel)
                }
            } else if agent.configuration.provider == .sloppy {
                Section("Сервер Sloppy") {
                    TextField("https://sloppy.example.com", text: $agent.configuration.sloppyEndpoint)
                        .keyboardType(.URL).accessibilityIdentifier("sloppy-server-url")
                    SecureField("Токен доступа Sloppy", text: $state.key).accessibilityIdentifier("sloppy-access-token")
                    Button("Сохранить токен в Keychain") { state.saveKey(configuration: agent.configuration) }
                    Text("Ключ привязан к адресу сервера. Укажите адрес перед вводом токена.").font(.caption).foregroundStyle(.secondary)
                    modelPicker(selection: $agent.configuration.sloppyModel)
                    Text("Серверу нужна поддержка Sloppy inference v1. Инструменты заметок выполняются в Yohaku; изменения по-прежнему требуют вашего подтверждения.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("OpenAI-совместимый сервер") {
                    TextField("Endpoint, включая /v1", text: $agent.configuration.endpoint).keyboardType(.URL)
                    TextField("Model ID", text: $agent.configuration.remoteID)
                    SecureField("API-ключ", text: $state.key)
                    Button("Сохранить ключ в Keychain") { state.saveKey(configuration: agent.configuration) }
                    Text("Ключ привязан к выбранному endpoint и не хранится в папке заметок.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !state.status.isEmpty { Section { Text(state.status).font(.callout).accessibilityIdentifier("model-connection-status") } }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(agent.running)
    }

    private func modelPicker(selection: Binding<String>) -> some View {
        Group {
            if !state.models.isEmpty {
                Picker("Модель", selection: selection) {
                    Text("Выберите модель").tag("")
                    if !selection.wrappedValue.isEmpty, !state.models.contains(where: { $0.id == selection.wrappedValue }) {
                        Text(selection.wrappedValue).tag(selection.wrappedValue)
                    }
                    ForEach(state.models) { Text($0.title).tag($0.id) }
                }.accessibilityIdentifier("remote-model-picker")
            }
            TextField("Model ID", text: selection)
            Button("Загрузить модели") { state.loadModels(configuration: agent.configuration) }.accessibilityIdentifier("load-remote-models")
        }
    }

}
