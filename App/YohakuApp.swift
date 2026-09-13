import StudyCore
import StudyIntelligence
import SwiftUI

@main struct YohakuApp: App {
    @State private var workspace = WorkspaceModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WorkspaceView(workspace: workspace)
                .tint(Palette.accent)
                .task { await workspace.start() }
                .onChange(of: phase) { _, new in
                    if new == .active { Task { await workspace.refresh() } }
                    else if new == .background {
                        workspace.agent.cancel()
                        Task { await workspace.saveAll(); await workspace.agent.releaseMemory() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await workspace.agent.releaseMemory(); workspace.dropInactiveSessions() }
                }
        }
    }
}

enum Palette {
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.56, green: 0.79, blue: 0.69, alpha: 1) : UIColor(red: 0.19, green: 0.42, blue: 0.35, alpha: 1) })
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.075, green: 0.09, blue: 0.11, alpha: 1) : UIColor(red: 0.95, green: 0.95, blue: 0.92, alpha: 1) })
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 1) : UIColor(red: 0.99, green: 0.985, blue: 0.97, alpha: 1) })
    static let muted = Color.secondary
}
