import AdaEngine
import StudyCanvas
import StudyCore
import UIKit

@main struct AdaCanvasProbeApp: AdaEngine.App {
    var body: some AppScene {
        WindowGroup(content: {
            VStack {
                Text("AdaUI × PencilKit · сравнительный прототип")
                AdaPencilProbe()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }, assetBundle: .main)
        .windowMode(.windowed)
        .windowTitle("AdaCanvas Probe")
    }
}

/// Runs exactly the same PencilSurfaceView as the production SwiftUI shell.
private struct AdaPencilProbe: UIKitViewRepresentable {
    func makeUIView(context: Context) -> ProbeContainer { ProbeContainer() }
    func updateUIView(_ uiView: ProbeContainer, in context: Context) {}
    static func dismantleUIView(_ uiView: ProbeContainer, coordinator: ()) { uiView.surface?.finish() }
}

private final class ProbeContainer: UIKit.UIView {
    var surface: PencilSurfaceView?
    private let label = UIKit.UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        print("[AdaCanvasProbe] Native container created")
        label.text = "Открытие тестовой тетради…"; label.numberOfLines = 0; addSubview(label)
        Task {
            do {
                let store = VaultStore(root: URL.documentsDirectory.appendingPathComponent("AdaProbe"))
                try await store.prepare()
                let loaded: LoadedDocument
                if let existing = try? await store.load("Probe.studycanvas") { loaded = existing }
                else { loaded = try await store.create("Probe.studycanvas", kind: .notebook) }
                let session = DocumentSession(path: "Probe.studycanvas", loaded: loaded, store: store)
                guard let page = loaded.content.pages.first else { return }
                let surface = PencilSurfaceView(session: session, pageID: page.id)
                self.surface = surface; label.removeFromSuperview(); addSubview(surface); setNeedsLayout()
                print("[AdaCanvasProbe] PencilKit surface ready")
            } catch { label.text = error.localizedDescription }
        }
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() { super.layoutSubviews(); surface?.frame = bounds; label.frame = bounds.insetBy(dx: 20, dy: 20) }
}
