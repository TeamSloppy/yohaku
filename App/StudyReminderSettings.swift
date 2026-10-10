import SwiftUI
import UserNotifications

struct StudyReminderSettings: View {
    @State private var companion = StudyCompanion.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase

    private var reminderDate: Date {
        Calendar.current.date(bySettingHour: companion.time.hour, minute: companion.time.minute, second: 0, of: Date()) ?? Date()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Напоминать о повторении", isOn: Binding(
                        get: { companion.enabled },
                        set: { value in Task { await companion.setEnabled(value) } }
                    ))
                    .accessibilityIdentifier("study-reminder-enabled")
                    .disabled(companion.isUpdating)
                    DatePicker("Каждый день в", selection: Binding(
                        get: { reminderDate },
                        set: { date in Task { await companion.setTime(date) } }
                    ), displayedComponents: .hourAndMinute)
                    .disabled(!companion.enabled || companion.isUpdating)
                    .accessibilityIdentifier("study-reminder-time")
                    if companion.authorization == .denied {
                        Button("Разрешить уведомления в Настройках", systemImage: "gear") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                } header: {
                    Text("Повторение слов")
                } footer: {
                    Text(companion.authorization == .denied
                         ? "Уведомления запрещены системой. Разрешите их в Настройках, чтобы получать напоминания."
                         : "Напоминание приходит по местному времени, пока в хранилище есть карточки. Нажмите на уведомление, чтобы открыть изучение.")
                }
                Section("Виджет «Слово на час»") {
                    Label("Новое слово каждый час", systemImage: "clock")
                    Text("Добавьте виджет Yohaku через меню виджетов на домашнем экране. Он показывает слово, чтение и перевод из текущего хранилища, включая рукописные карточки.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error = companion.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Напоминания и виджет")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task { await companion.reconcile() }
            .onChange(of: phase) { _, phase in
                if phase == .active { Task { await companion.reconcile() } }
            }
        }
    }
}
