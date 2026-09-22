import CryptoKit
import Foundation

/// Serializes all app file operations; UI state never serves as the on-disk revision.
public actor VaultStore {
    private struct DeletionMarker: Codable {
        var path: String
        var deletedAt: Date
    }

    public let root: URL
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }()
    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    public func prepare() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".workspace/records"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".workspace/trash"), withIntermediateDirectories: true)
        try fm.createDirectory(at: deletionMarkersURL, withIntermediateDirectories: true)
    }
    public func identifier() throws -> String {
        let file = root.appendingPathComponent(".workspace/vault-id")
        if let data = try? Data(contentsOf: file), let value = String(data: data, encoding: .utf8), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString
        try Data(value.utf8).write(to: file, options: .atomic)
        return value
    }

    public func fileURL(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { throw StudyError.invalidPath }
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { throw StudyError.invalidPath }
        return url
    }

    public func list() throws -> [VaultEntry] {
        try enforceDeletionMarkers()
        var entries: [VaultEntry] = []
        func visit(_ directory: URL, prefix: String) throws {
            let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            for url in children {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { continue }
                let path = prefix + url.lastPathComponent
                if url.pathExtension == "studycanvas" {
                    let kind = (try? load(path).content.kind) ?? .notebook
                    entries.append(.init(path: path, isDirectory: false, kind: kind))
                } else if values.isDirectory == true {
                    entries.append(.init(path: path, isDirectory: true))
                    try visit(url, prefix: path + "/")
                } else if url.pathExtension.lowercased() == "md" {
                    entries.append(.init(path: path, isDirectory: false, kind: .markdown))
                }
            }
        }
        try visit(root, prefix: "")
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public func load(_ path: String) throws -> LoadedDocument {
        let url = try fileURL(path)
        return try coordinated(url, writing: false) { coordinatedURL in
            let isMarkdown = coordinatedURL.pathExtension.lowercased() == "md"
            let data = try Data(contentsOf: isMarkdown ? coordinatedURL : coordinatedURL.appendingPathComponent("manifest.json"))
            var content: DocumentContent
            var metadata = Data()
            if isMarkdown {
                metadata = (try? Data(contentsOf: recordURL(path))) ?? Data()
                content = metadata.isEmpty ? markdownWithoutMetadata(path) : try JSONDecoder().decode(DocumentContent.self, from: metadata)
                guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                content.markdown = text
            } else { content = try JSONDecoder().decode(DocumentContent.self, from: data) }
            guard content.schemaVersion == 1 else { throw StudyError.unsupportedVersion }
            let needsRepair = isMarkdown ? false : repairMissingDrawingAssets(in: &content, package: coordinatedURL)
            return LoadedDocument(content: content, revision: digest(data + metadata), needsRepair: needsRepair)
        }
    }

    @discardableResult
    public func create(_ path: String, kind: DocumentKind, text: String = "") throws -> LoadedDocument {
        try enforceDeletionMarkers()
        let url = try fileURL(path)
        guard url.pathExtension == kind.fileExtension else { throw StudyError.invalidPath }
        try clearDeletionMarkers(overlapping: path)
        guard !fm.fileExists(atPath: url.path) else { throw StudyError.exists }
        var content = DocumentContent(kind: kind); content.markdown = text
        return try save(path, content: content, expectedRevision: nil)
    }

    /// Assets have unique immutable names. Only changed data is resident in memory.
    @discardableResult
    public func save(_ path: String, content: DocumentContent, expectedRevision: String?, assets: [String: Data] = [:]) throws -> LoadedDocument {
        let url = try fileURL(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try coordinated(url, writing: true) { target in
            if fm.fileExists(atPath: target.path) {
                guard let expectedRevision, try loadUncoordinated(path).revision == expectedRevision else { throw StudyError.staleRevision }
            } else if expectedRevision != nil { throw StudyError.staleRevision }
            if content.kind == .markdown {
                var metadata = content; metadata.markdown = ""
                try Data(content.markdown.utf8).write(to: target, options: .atomic)
                try encoder.encode(metadata).write(to: recordURL(path), options: .atomic)
            } else {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                for (name, data) in assets {
                    let asset = try safeAssetURL(package: target, name: name)
                    try fm.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: asset, options: .atomic)
                }
                // The manifest is the commit point; existing assets are never overwritten by editors.
                try encoder.encode(content).write(to: target.appendingPathComponent("manifest.json"), options: .atomic)
            }
            return try loadUncoordinated(path)
        }
    }

    public func readAsset(_ path: String, name: String) throws -> Data {
        let package = try fileURL(path)
        let asset = try safeAssetURL(package: package, name: name)
        return try coordinated(asset, writing: false) { try Data(contentsOf: $0) }
    }

    public func readFile(_ path: String, maxBytes: Int = 32 * 1024 * 1024) throws -> Data {
        let url = try fileURL(path)
        return try coordinated(url, writing: false) { file in
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxBytes else { throw StudyError.modelUnavailable(String(localized: "Файл слишком большой для предпросмотра.")) }
            return try Data(contentsOf: file)
        }
    }

    public func importMarkdownAsset(_ data: Data, extension suffix: String) throws -> String {
        guard suffix.allSatisfy({ $0.isLetter || $0.isNumber }), !suffix.isEmpty else { throw StudyError.invalidPath }
        let path = "Вложения/\(UUID().uuidString).\(suffix)"
        let url = try fileURL(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinated(url, writing: true) { try data.write(to: $0, options: .atomic) }
        return path
    }

    public func createFolder(_ path: String) throws {
        try enforceDeletionMarkers()
        let url = try fileURL(path)
        try clearDeletionMarkers(overlapping: path)
        guard !fm.fileExists(atPath: url.path) else { throw StudyError.exists }
        try coordinated(url, writing: true) { try fm.createDirectory(at: $0, withIntermediateDirectories: true) }
    }

    /// Trash stays within the vault so accidental deletion can be recovered from Files.
    public func trash(_ path: String) throws {
        let source = try fileURL(path)
        let trash = root.appendingPathComponent(".workspace/trash/\(UUID().uuidString)")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent(source.lastPathComponent)
        try writeDeletionMarker(path)
        do {
            discardCloudConflictVersions(at: source)
            try coordinatedMove(from: source, to: destination)
        } catch {
            try? fm.removeItem(at: markerURL(for: path))
            throw error
        }
    }

    public func move(_ path: String, to destination: String) throws {
        try enforceDeletionMarkers()
        let source = try fileURL(path), target = try fileURL(destination)
        guard !destination.hasPrefix(path + "/"), !fm.fileExists(atPath: target.path) else { throw StudyError.exists }
        try clearDeletionMarkers(overlapping: destination)
        let documents = try list().filter { !$0.isDirectory }
        var originals: [String: LoadedDocument] = [:]
        for entry in documents { originals[entry.path] = try load(entry.path) }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeDeletionMarker(path)
        do { try coordinatedMove(from: source, to: target) }
        catch {
            try? fm.removeItem(at: markerURL(for: path))
            throw error
        }
        func mapped(_ old: String) -> String {
            old == path || old.hasPrefix(path + "/") ? destination + old.dropFirst(path.count) : old
        }
        for entry in documents {
            guard let original = originals[entry.path] else { continue }
            let newPath = mapped(entry.path)
            if newPath != entry.path, fm.fileExists(atPath: recordURL(entry.path).path) {
                try fm.moveItem(at: recordURL(entry.path), to: recordURL(newPath))
            }
            var content = original.content
            content.markdown = NoteLinks.rewrite(content.markdown, source: entry.path, newSource: newPath, map: mapped)
            for p in content.pages.indices {
                for o in content.pages[p].objects.indices where content.pages[p].objects[o].kind == .link {
                    let link = content.pages[p].objects[o].content
                    content.pages[p].objects[o].content = NoteLinks.rewriteDestination(link, source: entry.path, newSource: newPath, map: mapped)
                }
            }
            if content != original.content || newPath != entry.path {
                let revision = try load(newPath).revision
                try save(newPath, content: content, expectedRevision: revision)
            }
        }
    }

    public func search(_ query: String) throws -> [VaultEntry] {
        let all = try list().filter { !$0.isDirectory }
        if query.isEmpty { return all }
        return all.filter { entry in
            if entry.path.localizedCaseInsensitiveContains(query) { return true }
            guard let document = try? load(entry.path).content else { return false }
            return document.markdown.localizedCaseInsensitiveContains(query)
                || document.pages.flatMap(\.objects).contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    public func reconcileExternalMove(_ oldPath: String, to newPath: String) throws {
        _ = try fileURL(oldPath); _ = try fileURL(newPath)
        func mapped(_ path: String) -> String {
            path == oldPath || path.hasPrefix(oldPath + "/") ? newPath + path.dropFirst(oldPath.count) : path
        }
        for entry in try list() where !entry.isDirectory {
            let moved = entry.path == newPath || entry.path.hasPrefix(newPath + "/")
            let priorPath = moved ? oldPath + entry.path.dropFirst(newPath.count) : entry.path
            if moved && fm.fileExists(atPath: recordURL(priorPath).path) && !fm.fileExists(atPath: recordURL(entry.path).path) {
                try fm.moveItem(at: recordURL(priorPath), to: recordURL(entry.path))
            }
            var loaded = try load(entry.path)
            let previous = loaded.content
            loaded.content.markdown = NoteLinks.rewrite(previous.markdown, source: priorPath, newSource: entry.path, map: mapped)
            for p in loaded.content.pages.indices {
                for o in loaded.content.pages[p].objects.indices where loaded.content.pages[p].objects[o].kind == .link {
                    loaded.content.pages[p].objects[o].content = NoteLinks.rewriteDestination(loaded.content.pages[p].objects[o].content, source: priorPath, newSource: entry.path, map: mapped)
                }
            }
            if loaded.content != previous { try save(entry.path, content: loaded.content, expectedRevision: loaded.revision) }
        }
    }

    public func backlinks(to target: String) throws -> [VaultEntry] {
        try list().filter { entry in
            guard !entry.isDirectory, let document = try? load(entry.path).content else { return false }
            let links = NoteLinks.destinations(in: document.markdown) + document.pages.flatMap(\.objects).filter { $0.kind == .link }.map(\.content)
            return links.contains { NoteLinks.resolve($0, source: entry.path)?.path == target }
        }
    }

    public func apply(_ proposal: ChangeProposal) throws -> LoadedDocument {
        if proposal.action == .createMarkdown {
            if let existing = try? load(proposal.path), existing.content.appliedProposals.contains(proposal.id) { return existing }
            var content = DocumentContent(kind: .markdown); content.markdown = proposal.text; content.appliedProposals.insert(proposal.id)
            guard !fm.fileExists(atPath: try fileURL(proposal.path).path) else { throw StudyError.exists }
            return try save(proposal.path, content: content, expectedRevision: nil)
        }
        var loaded = try load(proposal.path)
        if loaded.content.appliedProposals.contains(proposal.id) { return loaded }
        guard proposal.baseRevision == loaded.content.contentRevision else { throw StudyError.staleRevision }
        switch proposal.action {
        case .replaceMarkdown:
            guard loaded.content.kind == .markdown else { throw StudyError.invalidPath }
            loaded.content.markdown = proposal.text
        case .addCard:
            guard let index = loaded.content.pages.firstIndex(where: { $0.id == proposal.pageID }) else { throw StudyError.missingPage }
            loaded.content.pages[index].objects.append(.init(kind: proposal.isLink ? .link : .text, content: proposal.text))
        case .createMarkdown: break
        }
        loaded.content.appliedProposals.insert(proposal.id)
        return try save(proposal.path, content: loaded.content, expectedRevision: loaded.revision)
    }

    public func preserveConflict(_ path: String, content: DocumentContent, assets: [String: Data]) throws -> String {
        if let existing = try existingRecoveryPath(for: path, content: content) { return existing }
        let source = try fileURL(path)
        let destination = recoveryPath(for: path, kind: content.kind)
        let url = try fileURL(destination)
        if content.kind != .markdown, fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: url) }
        let revision = (try? load(destination))?.revision
        try save(destination, content: content, expectedRevision: revision, assets: assets)
        return destination
    }

    /// Keep every iCloud conflict version as a separate visible file before resolving system versions.
    public func preserveCloudVersions(_ path: String) throws -> [String] {
        let url = try fileURL(path)
        let versions = cloudConflictVersions(at: url)
        // Yohaku builds before this fix marked conflict versions resolved but
        // forgot to remove them. Recover those legacy versions once as well;
        // ordinary non-conflict document history is deliberately ignored.
        guard !versions.isEmpty else { return [] }
        var copies: [String] = []
        for version in versions {
            let destinationPath = recoveryPath(for: path, kind: nil)
            let destination = try fileURL(destinationPath)
            // Foundation requires conflict-version contents to be accessed from
            // a coordinated read of the version URL, not the current item URL.
            try coordinated(version.url, writing: false) { versionURL in
                try fm.copyItem(at: versionURL, to: destination)
            }
            if let loaded = try? loadUncoordinated(destinationPath),
               let existing = try existingRecoveryPath(for: path, content: loaded.content, excluding: destinationPath) {
                try fm.removeItem(at: destination)
                if !copies.contains(existing) { copies.append(existing) }
            } else {
                copies.append(destinationPath)
            }
        }
        // Resolution occurs only after all versions have durable recoverable
        // copies. Resolved versions must also be removed or iCloud keeps syncing
        // them to every device and can report the same conflict repeatedly.
        for version in versions {
            version.isResolved = true
            try? version.remove()
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        return copies
    }

    private var deletionMarkersURL: URL { root.appendingPathComponent(".workspace/deletions", isDirectory: true) }

    private func markerURL(for path: String) -> URL {
        deletionMarkersURL.appendingPathComponent(digest(Data(path.utf8))).appendingPathExtension("json")
    }

    private func writeDeletionMarker(_ path: String) throws {
        try fm.createDirectory(at: deletionMarkersURL, withIntermediateDirectories: true)
        try encoder.encode(DeletionMarker(path: path, deletedAt: Date())).write(to: markerURL(for: path), options: .atomic)
    }

    private func deletionMarkers() throws -> [(URL, DeletionMarker)] {
        guard fm.fileExists(atPath: deletionMarkersURL.path) else { return [] }
        return try fm.contentsOfDirectory(at: deletionMarkersURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).compactMap { url in
            guard let data = try? Data(contentsOf: url), let marker = try? JSONDecoder().decode(DeletionMarker.self, from: data) else { return nil }
            return (url, marker)
        }
    }

    private func clearDeletionMarkers(overlapping path: String) throws {
        for (url, marker) in try deletionMarkers() where
            marker.path == path || marker.path.hasPrefix(path + "/") || path.hasPrefix(marker.path + "/") {
            try fm.removeItem(at: url)
        }
    }

    /// A deletion marker wins over a late iCloud download. The deleted item has
    /// already been retained in `.workspace/trash`, so removing a resurrected
    /// visible copy is both deterministic and recoverable.
    private func enforceDeletionMarkers() throws {
        for (_, marker) in try deletionMarkers() {
            let url = try fileURL(marker.path)
            guard fm.fileExists(atPath: url.path) else { continue }
            discardCloudConflictVersions(at: url)
            try coordinated(url, writing: true, options: .forDeleting) { try fm.removeItem(at: $0) }
        }
    }

    private func discardCloudConflictVersions(at url: URL) {
        for version in cloudConflictVersions(at: url) {
            version.isResolved = true
            try? version.remove()
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }

    private func cloudConflictVersions(at url: URL) -> [NSFileVersion] {
        var versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        for version in NSFileVersion.otherVersionsOfItem(at: url) ?? [] where version.isConflict && !versions.contains(version) {
            versions.append(version)
        }
        return versions
    }

    private func coordinatedMove(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: source,
            options: .forMoving,
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            result = Result { try fm.moveItem(at: coordinatedSource, to: coordinatedDestination) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }

    private func recoveryPath(for path: String, kind: DocumentKind?) -> String {
        let original = path as NSString
        let directory = original.deletingLastPathComponent
        let originalFilename = original.lastPathComponent as NSString
        let stem = canonicalDocumentStem(originalFilename.deletingPathExtension)
        let suffix = kind?.fileExtension ?? originalFilename.pathExtension
        let filename = "\(stem) — восстановлено \(UUID().uuidString.prefix(8)).\(suffix)"
        return directory.isEmpty ? filename : (directory as NSString).appendingPathComponent(filename)
    }

    private func canonicalDocumentStem(_ value: String) -> String {
        var stem = value
        let labels = [" — конфликт ", " — iCloud ", " — восстановлено "]
        while let match = labels.compactMap({ label -> String.Index? in
            guard let range = stem.range(of: label, options: .backwards), range.upperBound < stem.endIndex else { return nil }
            let identifier = stem[range.upperBound...]
            guard identifier.count == 8, identifier.allSatisfy(\.isHexDigit) else { return nil }
            return range.lowerBound
        }).max() {
            stem = String(stem[..<match])
        }
        return stem
    }

    private func existingRecoveryPath(for path: String, content: DocumentContent, excluding excluded: String? = nil) throws -> String? {
        let original = try fileURL(path)
        let directory = original.deletingLastPathComponent()
        let stem = canonicalDocumentStem(original.deletingPathExtension().lastPathComponent)
        guard fm.fileExists(atPath: directory.path) else { return nil }
        for candidate in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let resolvedPath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(root.path + "/") else { continue }
            let relative = String(resolvedPath.dropFirst(root.path.count + 1))
            let candidateStem = candidate.deletingPathExtension().lastPathComponent
            guard relative != path, relative != excluded, candidate.pathExtension == content.kind.fileExtension,
                  candidateStem != stem, canonicalDocumentStem(candidateStem) == stem,
                  let loaded = try? loadUncoordinated(relative), loaded.content == content else { continue }
            return relative
        }
        return nil
    }

    private func loadUncoordinated(_ path: String) throws -> LoadedDocument {
        let url = try fileURL(path)
        let data = try Data(contentsOf: url.pathExtension == "md" ? url : url.appendingPathComponent("manifest.json"))
        let metadata = url.pathExtension == "md" ? ((try? Data(contentsOf: recordURL(path))) ?? Data()) : Data()
        var content = url.pathExtension == "md" ? (metadata.isEmpty ? markdownWithoutMetadata(path) : try JSONDecoder().decode(DocumentContent.self, from: metadata)) : try JSONDecoder().decode(DocumentContent.self, from: data)
        if url.pathExtension == "md" {
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            content.markdown = text
        }
        guard content.schemaVersion == 1 else { throw StudyError.unsupportedVersion }
        let needsRepair = url.pathExtension == "md" ? false : repairMissingDrawingAssets(in: &content, package: url)
        return .init(content: content, revision: digest(data + metadata), needsRepair: needsRepair)
    }
    private func recordURL(_ path: String) -> URL { root.appendingPathComponent(".workspace/records/\(digest(Data(path.utf8))).json") }
    private func markdownWithoutMetadata(_ path: String) -> DocumentContent {
        var content = DocumentContent(kind: .markdown)
        let bytes = Array(SHA256.hash(data: Data(path.utf8)))
        content.id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return content
    }

    /// Drawing assets are immutable snapshots. Older builds pruned the previous
    /// snapshot immediately after a local save, before iCloud had necessarily
    /// uploaded the replacement. If a manifest now points to a missing drawing,
    /// retain every non-empty orphan as its own recovery page rather than guessing
    /// which snapshot is newest and discarding the rest.
    private func repairMissingDrawingAssets(in content: inout DocumentContent, package: URL) -> Bool {
        let referenced = Set(content.pages.flatMap { page in
            [page.drawingFile].compactMap { $0 } + page.shards.map(\.file)
        })
        let missing = referenced.filter { !fm.fileExists(atPath: package.appendingPathComponent($0).path) }
        guard !missing.isEmpty else { return false }

        for pageIndex in content.pages.indices {
            if let drawing = content.pages[pageIndex].drawingFile, missing.contains(drawing) {
                content.pages[pageIndex].drawingFile = nil
            }
            content.pages[pageIndex].shards.removeAll { missing.contains($0.file) }
        }

        let assetsDirectory = package.appendingPathComponent("assets", isDirectory: true)
        let candidates = ((try? fm.contentsOfDirectory(
            at: assetsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            guard url.pathExtension == "drawing" else { return false }
            let name = "assets/" + url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return !referenced.contains(name) && size > 42
        }.sorted {
            let lhs = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let rhs = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (lhs ?? .distantPast) < (rhs ?? .distantPast)
        }

        let template = content.pages.first ?? CanvasPage()
        for (offset, candidate) in candidates.enumerated() {
            var page = CanvasPage()
            page.title = String(localized: "Восстановлено") + " \(offset + 1)"
            page.paper = template.paper; page.width = template.width; page.height = template.height
            let name = "assets/" + candidate.lastPathComponent
            if content.kind == .infinity {
                page.shards = [.init(file: name, bounds: Rect(x: -1_000_000, y: -1_000_000, width: 2_000_000, height: 2_000_000))]
            } else {
                page.drawingFile = name
            }
            content.pages.append(page)
        }
        return true
    }

    public func pruneAssets(_ path: String, keeping names: Set<String>) throws {
        guard path.hasSuffix(".studycanvas") else { return }
        let package = try fileURL(path), directory = package.appendingPathComponent("assets")
        guard fm.fileExists(atPath: directory.path) else { return }
        try coordinated(package, writing: true) { _ in
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where !names.contains("assets/" + file.lastPathComponent) {
                try fm.removeItem(at: file)
            }
        }
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func safeAssetURL(package: URL, name: String) throws -> URL {
        guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw StudyError.invalidPath }
        let url = package.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(package.path + "/") else { throw StudyError.invalidPath }
        return url
    }
    private func coordinated<T>(
        _ url: URL,
        writing: Bool,
        options: NSFileCoordinator.WritingOptions = [],
        _ action: (URL) throws -> T
    ) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        if writing {
            coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinatedURL in result = Result { try action(coordinatedURL) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in result = Result { try action(coordinatedURL) } }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
