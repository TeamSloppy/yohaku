import StudyCore
import StudyIntelligence
import SwiftUI

struct AgentPanel: View {
    @Bindable var workspace: WorkspaceModel
    @State private var prompt = ""
    @State private var saveReply: ReplyToSave?
    private var session: DocumentSession? { (workspace.chatPath ?? workspace.activePath).flatMap { workspace.sessions[$0] } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Помощник").font(.headline)
                    Text(workspace.agent.configuration.provider == .local ? "На этом устройстве" : "Сетевой провайдер").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { workspace.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Настройки модели")
                Button { workspace.showAgent = false } label: { Image(systemName: "xmark") }.accessibilityLabel("Закрыть помощника")
            }.padding(18)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if session?.content.messages.isEmpty != false {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Разберёмся вместе").font(.title2.weight(.semibold))
                                Text("Выделите фрагмент на листе или текст в заметке. Можно спросить о переводе, грамматике или новом слове.").font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 24)
                        }
                        ForEach(session?.content.messages ?? []) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(message.role == .user ? "ВЫ" : "ПОМОЩНИК").font(.caption2.weight(.bold)).tracking(1); Spacer(); if message.interrupted { Text("Прервано").font(.caption2).foregroundStyle(.orange) } }
                                    .foregroundStyle(.secondary)
                                if let data = message.context?.image, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 150).clipShape(RoundedRectangle(cornerRadius: 8)) }
                                Text(.init(message.text.isEmpty ? "…" : message.text)).textSelection(.enabled).font(.subheadline)
                                if let context = message.context {
                                    Button(context.path) { Task { await workspace.open(context.path, pageID: context.pageID) } }.font(.caption2).lineLimit(1)
                                }
                                if message.role == .assistant && !message.text.isEmpty {
                                    Button("Сохранить в заметку", systemImage: "doc.badge.plus") { saveReply = .init(text: message.text) }.font(.caption)
                                }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(message.role == .user ? Palette.accent.opacity(0.07) : Palette.background, in: RoundedRectangle(cornerRadius: 12))
                        }
                        ForEach(workspace.agent.proposals) { proposal in
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Предложение изменений", systemImage: "pencil.and.list.clipboard").font(.caption.bold())
                                Text(proposal.path).font(.caption).foregroundStyle(.secondary)
                                Text(proposal.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                HStack {
                                    Button("Применить") { Task { await workspace.accept(proposal) } }.buttonStyle(.borderedProminent)
                                    Button("Отклонить") { workspace.agent.proposals.removeAll { $0.id == proposal.id } }
                                }.font(.caption)
                            }.padding(14).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(16)
                }
                .onChange(of: session?.content.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if let error = workspace.agent.error { Text(error).font(.caption).foregroundStyle(.orange).padding(14) }
            if let context = workspace.pendingContext {
                HStack(alignment: .top) {
                    if let data = context.image, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 5)) }
                    VStack(alignment: .leading) { Text("Выделенный фрагмент").font(.caption.bold()); Text(context.text ?? (context.path as NSString).lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                    Spacer(); Button { workspace.pendingContext = nil } label: { Image(systemName: "xmark.circle.fill") }
                }.padding(12).background(Palette.accent.opacity(0.06))
            }
            VStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(["Объясни", "Переведи", "Разбери грамматику"], id: \.self) { text in Button(text) { prompt = text + " этот фрагмент." }.buttonStyle(.bordered).font(.caption) }
                    }
                }
                HStack(alignment: .bottom) {
                    TextField("Задайте вопрос…", text: $prompt, axis: .vertical).lineLimit(2...6).font(.subheadline).accessibilityIdentifier("agent-prompt")
                    if workspace.agent.running {
                        Button { workspace.agent.cancel() } label: { Image(systemName: "stop.fill").padding(8) }.accessibilityLabel("Остановить")
                    } else {
                        Button {
                            guard let session else { return }
                            workspace.agent.send(prompt, context: workspace.pendingContext, document: session)
                            prompt = ""; workspace.pendingContext = nil
                        } label: { Image(systemName: "arrow.up").font(.headline).padding(10).background(Palette.accent, in: Circle()).foregroundStyle(.white) }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session == nil).accessibilityLabel("Отправить")
                    }
                }.padding(12).background(Palette.background, in: RoundedRectangle(cornerRadius: 14))
                if workspace.agent.running { Text(workspace.agent.status).font(.caption2).foregroundStyle(.secondary) }
                else if let message = session?.content.messages.last(where: { $0.role == .user }) {
                    Button("Повторить последний вопрос") { guard let session else { return }; workspace.agent.send(message.text, context: message.context, document: session) }.font(.caption2)
                }
            }.padding(14)
        }.background(Palette.surface)
        .sheet(item: $saveReply) { reply in SaveReplySheet(text: reply.text, workspace: workspace, source: session?.path) }
    }
}

private struct ReplyToSave: Identifiable { let id = UUID(); let text: String }
private struct SaveReplySheet: View {
    let text: String
    var workspace: WorkspaceModel
    let source: String?
    @State private var name = "Объяснение"
    @State private var existing = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Picker("Сохранить", selection: $existing) {
                    Text("Новая заметка").tag("")
                    ForEach(workspace.entries.filter { $0.kind == .markdown }) { Text($0.path).tag($0.path) }
                }
                if existing.isEmpty { TextField("Имя", text: $name) }
                Text(text).font(.subheadline)
            }.navigationTitle("Сохранить объяснение")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") {
                            Task {
                                guard let store = workspace.store else { return }
                                do {
                                    let path = existing.isEmpty ? name + ".md" : existing
                                    let link = source.map { "\n\n[Источник](\(NoteLinks.relativePath(to: $0, from: path)))" } ?? ""
                                    if existing.isEmpty { try await store.create(path, kind: .markdown, text: text + link) }
                                    else if let session = workspace.sessions[path] { session.edit { $0.markdown += "\n\n" + text + link }; await session.save() }
                                    else { var loaded = try await store.load(path); loaded.content.markdown += "\n\n" + text + link; try await store.save(path, content: loaded.content, expectedRevision: loaded.revision) }
                                    await workspace.refresh(); dismiss()
                                } catch { workspace.error = error.localizedDescription }
                            }
                        }.disabled(name.isEmpty && existing.isEmpty)
                    }
                }
        }
    }
}
