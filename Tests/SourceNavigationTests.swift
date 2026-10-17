import PencilKit
import StudyCanvas
import StudyCore
import SwiftUI
import Testing
import UIKit
@testable import Yohaku

@MainActor @Suite(.serialized) struct SourceNavigationTests {
    private func document(_ kind: DocumentKind) async throws -> DocumentSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VaultStore(root: root)
        try await store.prepare()
        let path = "Source." + kind.fileExtension
        return DocumentSession(path: path, loaded: try await store.create(path, kind: kind), store: store)
    }
    private func workspace(_ session: DocumentSession) -> WorkspaceModel {
        let workspace = WorkspaceModel()
        workspace.store = session.store
        workspace.sessions[session.path] = session
        workspace.tabs = [.init(path: session.path, pageID: session.content.pages[0].id)]
        workspace.activePath = session.path
        return workspace
    }
    private func mount(_ view: UIView) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 700, height: 700)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        view.frame = controller.view.bounds
        window.makeKeyAndVisible()
        view.setNeedsLayout(); view.layoutIfNeeded()
        return window
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(predicate())
    }
    @Test func existingTabReceivesFullSourceAndDistinctSingleUseRequests() async throws {
        let session = try await document(.notebook)
        let second = CanvasPage()
        session.edit { $0.pages.append(second) }
        let workspace = workspace(session)
        let region = Rect(x: 100, y: 500, width: 120, height: 80)
        let source = SourceContext(path: session.path, pageID: second.id, region: region)

        await workspace.open(source)
        let first = try #require(workspace.sourceNavigation)
        #expect(workspace.tabs.count == 1)
        #expect(workspace.tabs[0].pageID == second.id)
        #expect(first.pageID == second.id && first.region == region)
        await workspace.open(source)
        let next = try #require(workspace.sourceNavigation)
        #expect(first.id != next.id)
        workspace.completeSourceNavigation(first.id)
        #expect(workspace.sourceNavigation == next)
        workspace.completeSourceNavigation(next.id)
        #expect(workspace.sourceNavigation == nil)
        await workspace.open(SourceContext(path: session.path, pageID: second.id))
        #expect(workspace.tabs[0].pageID == second.id)
        #expect(workspace.sourceNavigation?.region == nil)
    }
    @Test func invalidTargetsAndRemovedPagesCannotLeavePendingNavigation() async throws {
        let session = try await document(.notebook)
        let workspace = workspace(session)
        let pageID = session.content.pages[0].id
        await workspace.open(SourceContext(path: session.path, pageID: pageID, region: Rect()))
        await workspace.open(SourceContext(path: session.path, pageID: UUID(), region: Rect()))
        #expect(workspace.sourceNavigation == nil)
        #expect(workspace.error != nil)
        #expect(workspace.tabs[0].pageID == pageID)
        await workspace.open(SourceContext(path: session.path, pageID: pageID, region: Rect(x: .infinity)))
        #expect(workspace.sourceNavigation == nil)
        await workspace.open(SourceContext(path: session.path, pageID: pageID, region: Rect()))
        session.edit { $0.pages = [CanvasPage()] }
        workspace.invalidateSourceNavigation()
        #expect(workspace.sourceNavigation == nil)
        await workspace.open(SourceContext(path: session.path, pageID: session.content.pages[0].id, region: Rect()))
        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await workspace.openVault(otherRoot, remember: false, iCloud: false)
        #expect(workspace.sourceNavigation == nil)
    }
    @Test(arguments: [DocumentKind.notebook, .infinity])
    func navigationWaitsForMountAndLayoutThenDoesNotReplay(_ kind: DocumentKind) async throws {
        let session = try await document(kind)
        let pageID = session.content.pages[0].id
        if kind == .infinity { session.edit { $0.pages[0].lastInkBounds = Rect(x: 100_000, y: 100_000) } }
        let surface = PencilSurfaceView(session: session, pageID: pageID)
        let region = kind == .infinity ? Rect(x: -90_000, y: 60_000, width: 180, height: 100) : Rect(x: 300, y: 600, width: 100, height: 80)
        let request = SourceNavigationRequest(path: session.path, pageID: pageID, region: region)
        var applied: [UUID] = []
        var position = CanvasPosition()
        surface.onPosition = { position = $0 }
        surface.onNavigationApplied = { applied.append($0) }
        surface.navigate(to: request)
        #expect(applied.isEmpty)
        let window = try mount(surface)
        defer { surface.finish(); window.isHidden = true }
        try await waitUntil { applied == [request.id] }
        let desiredX = (region.x + region.width / 2) * position.zoom - surface.bounds.width / 2
        let inset = surface.canvas.adjustedContentInset
        let expectedX = kind == .infinity ? desiredX : min(max(-inset.left, desiredX), max(-inset.left, surface.canvas.contentSize.width - surface.bounds.width + inset.right))
        #expect(abs(position.x * position.zoom - expectedX) < 1)
        #expect(position.y <= region.y)
        let highlight = try #require(surface.subviews.first { $0.accessibilityIdentifier == "source-region-highlight" })
        #expect(!highlight.isHidden && surface.bounds.contains(highlight.frame))
        if kind == .notebook {
            #expect(abs(surface.canvas.contentSize.width - session.content.pages[0].width * position.zoom) < 1)
            #expect(abs(surface.canvas.contentSize.height - session.content.pages[0].height * position.zoom) < 1)
        }
        // Keep the manual pan in the finite page's scrollable range, avoiding bounce correction.
        surface.canvas.contentOffset.x += kind == .infinity ? 100 : -50
        surface.scrollViewWillBeginDragging(surface.canvas)
        let moved = surface.canvas.contentOffset
        surface.navigate(to: request)
        surface.setNeedsLayout(); surface.layoutIfNeeded(); surface.updateContent()
        #expect(surface.canvas.contentOffset == moved)
        #expect(highlight.isHidden)
        let second = SourceNavigationRequest(path: session.path, pageID: pageID, region: region)
        surface.navigate(to: second)
        try await waitUntil { applied.count == 2 }
        #expect(applied == [request.id, second.id])
        #expect(!highlight.isHidden)
        let wrongPage = SourceNavigationRequest(path: session.path, pageID: UUID(), region: region)
        surface.navigate(to: wrongPage)
        #expect(applied.count == 2)
        if kind == .notebook {
            surface.navigate(to: .init(path: session.path, pageID: pageID, region: Rect(x: 0, y: 0, width: 80, height: 80)))
            try await waitUntil { applied.count == 3 }
            #expect(surface.bounds.contains(highlight.frame))
            #expect(abs(surface.canvas.contentOffset.x + surface.canvas.adjustedContentInset.left) < 1)
        }
    }
    @Test func navigationFinishesStrokeBeforeRecentringAndLoadsTargetShard() async throws {
        let session = try await document(.infinity)
        func stroke(_ x: CGFloat, _ y: CGFloat) -> PKStroke {
            let points = [CGPoint(x: x, y: y), CGPoint(x: x + 60, y: y + 60)].enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        let target = PKDrawing(strokes: [stroke(-80_000, 70_000)])
        let file = session.addAsset(target.dataRepresentation(), extension: "drawing")
        session.edit { $0.pages[0].shards = [.init(file: file, bounds: Rect(target.bounds))] }
        let surface = PencilSurfaceView(session: session, pageID: session.content.pages[0].id)
        let window = try mount(surface)
        defer { surface.finish(); window.isHidden = true }
        // Let any initial legacy focus and ink reload finish, then explicitly start at home.
        try await Task.sleep(for: .milliseconds(200))
        let home = SourceNavigationRequest(path: session.path, pageID: session.content.pages[0].id, region: Rect(x: 0, y: 0, width: 100, height: 100))
        var applied: [UUID] = []
        surface.onNavigationApplied = { applied.append($0) }
        surface.navigate(to: home)
        try await waitUntil { applied.contains(home.id) && surface.canvas.drawing.strokes.isEmpty }
        surface.canvasViewDidBeginUsingTool(surface.canvas)
        surface.canvas.drawing = PKDrawing(strokes: [stroke(8_192, 8_192)])
        let request = SourceNavigationRequest(path: session.path, pageID: session.content.pages[0].id, region: Rect(target.bounds))
        surface.navigate(to: request)
        #expect(!applied.contains(request.id))
        surface.canvasViewDidEndUsingTool(surface.canvas)
        try await waitUntil { applied.contains(request.id) && surface.canvas.drawing.strokes.count == 1 && abs(surface.canvas.drawing.bounds.midX - 8_192) < 1_000 }
        #expect(session.content.pages[0].shards.count == 2)
        let bounds = session.content.pages[0].shards.map(\.bounds)
        #expect(bounds.contains { $0.x < -70_000 })
        #expect(bounds.contains { abs($0.x) < 100 })
        let highlight = try #require(surface.subviews.first { $0.accessibilityIdentifier == "source-region-highlight" })
        #expect(!highlight.isHidden)
    }
    @Test func cancellingDeferredNavigationDoesNotReplayOrClearCompletedHighlight() async throws {
        let session = try await document(.notebook)
        let pageID = session.content.pages[0].id
        let surface = PencilSurfaceView(session: session, pageID: pageID)
        var applied: [UUID] = []
        surface.onNavigationApplied = { applied.append($0) }
        let beforeMount = SourceNavigationRequest(path: session.path, pageID: pageID, region: Rect(x: 200, y: 500))
        surface.navigate(to: beforeMount)
        surface.navigate(to: nil)
        let window = try mount(surface)
        defer { surface.finish(); window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        #expect(applied.isEmpty)
        let offset = surface.canvas.contentOffset
        surface.canvasViewDidBeginUsingTool(surface.canvas)
        let duringStroke = SourceNavigationRequest(path: session.path, pageID: pageID, region: Rect(x: 300, y: 600))
        surface.navigate(to: duringStroke)
        surface.navigate(to: nil)
        surface.canvasViewDidEndUsingTool(surface.canvas)
        surface.setNeedsLayout(); surface.layoutIfNeeded(); surface.updateContent()
        #expect(applied.isEmpty)
        #expect(surface.canvas.contentOffset == offset)
        let next = SourceNavigationRequest(path: session.path, pageID: pageID, region: Rect(x: 100, y: 400))
        surface.navigate(to: next)
        try await waitUntil { applied == [next.id] }
        let highlight = try #require(surface.subviews.first { $0.accessibilityIdentifier == "source-region-highlight" })
        #expect(!highlight.isHidden)
        surface.navigate(to: nil)
        surface.setNeedsLayout(); surface.layoutIfNeeded(); surface.updateContent()
        #expect(applied == [next.id])
        #expect(!highlight.isHidden)
    }
    @Test func editorConsumesRequestOnCorrectPageAndPersistsViewport() async throws {
        let session = try await document(.notebook)
        let second = CanvasPage()
        session.edit { $0.pages.append(second) }
        let workspace = workspace(session)
        let controller = UIHostingController(rootView: DocumentEditor(session: session, workspace: workspace, pageStripVisible: .constant(false)))
        let window = try mount(controller.view)
        defer { window.isHidden = true }
        await workspace.open(SourceContext(path: session.path, pageID: second.id, region: Rect(x: 200, y: 500, width: 120, height: 120)))
        try await waitUntil { workspace.sourceNavigation == nil && (workspace.tabs[0].pagePositions?[second.id.uuidString]?.zoom ?? 0) > 0 }
        #expect(workspace.tabs[0].pageID == second.id)
        #expect((workspace.tabs[0].pagePositions?[second.id.uuidString]?.y ?? 0) > 0)
    }
}
