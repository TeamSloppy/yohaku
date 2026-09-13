import CryptoKit
import Foundation

/// Serializes all app file operations; UI state never serves as the on-disk revision.
public actor VaultStore {
    public let root: URL
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }()
    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    public func prepare() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".workspace/records"), withIntermediateDirectories: true)
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
            return LoadedDocument(content: content, revision: digest(data + metadata))
        }
    }

    @discardableResult
    public func create(_ path: String, kind: DocumentKind, text: String = "") throws -> LoadedDocument {
        let url = try fileURL(path)
        guard url.pathExtension == kind.fileExtension else { throw StudyError.invalidPath }
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
        let url = try fileURL(path)
        guard !fm.fileExists(atPath: url.path) else { throw StudyError.exists }
        try coordinated(url, writing: true) { try fm.createDirectory(at: $0, withIntermediateDirectories: true) }
    }

    /// Trash stays within the vault so accidental deletion can be recovered from Files.
    public func trash(_ path: String) throws {
        let source = try fileURL(path)
        let trash = root.appendingPathComponent(".workspace/trash/\(UUID().uuidString)")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try coordinated(source, writing: true) { try fm.moveItem(at: $0, to: trash.appendingPathComponent(source.lastPathComponent)) }
    }

    public func move(_ path: String, to destination: String) throws {
        let source = try fileURL(path), target = try fileURL(destination)
        guard !destination.hasPrefix(path + "/"), !fm.fileExists(atPath: target.path) else { throw StudyError.exists }
        let documents = try list().filter { !$0.isDirectory }
        var originals: [String: LoadedDocument] = [:]
        for entry in documents { originals[entry.path] = try load(entry.path) }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinated(source, writing: true) { try fm.moveItem(at: $0, to: target) }
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
        let source = try fileURL(path)
        let destination = source.deletingPathExtension().path.replacingOccurrences(of: root.path + "/", with: "")
            + " — конфликт " + UUID().uuidString.prefix(8) + "." + content.kind.fileExtension
        let url = try fileURL(destination)
        if content.kind != .markdown, fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: url) }
        let revision = (try? load(destination))?.revision
        try save(destination, content: content, expectedRevision: revision, assets: assets)
        return destination
    }

    /// Keep every iCloud conflict version as a separate visible file before resolving system versions.
    public func preserveCloudVersions(_ path: String) throws -> [String] {
        let url = try fileURL(path)
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return [] }
        var copies: [String] = []
        for version in versions {
            let filename = url.deletingPathExtension().lastPathComponent + " — iCloud " + UUID().uuidString.prefix(8) + "." + url.pathExtension
            let destination = url.deletingLastPathComponent().appendingPathComponent(filename)
            try coordinated(url, writing: true) { _ in
                _ = try version.replaceItem(at: destination, options: [])
            }
            copies.append(String(destination.path.dropFirst(root.path.count + 1)))
        }
        // Resolution occurs only after all versions have durable recoverable copies.
        for version in versions { version.isResolved = true }
        return copies
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
        return .init(content: content, revision: digest(data + metadata))
    }
    private func recordURL(_ path: String) -> URL { root.appendingPathComponent(".workspace/records/\(digest(Data(path.utf8))).json") }
    private func markdownWithoutMetadata(_ path: String) -> DocumentContent {
        var content = DocumentContent(kind: .markdown)
        let bytes = Array(SHA256.hash(data: Data(path.utf8)))
        content.id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return content
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
    private func coordinated<T>(_ url: URL, writing: Bool, _ action: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in result = Result { try action(coordinatedURL) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in result = Result { try action(coordinatedURL) } }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
