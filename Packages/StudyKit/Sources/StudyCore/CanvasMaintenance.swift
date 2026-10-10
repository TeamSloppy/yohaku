import CryptoKit
import Foundation
import PencilKit

public struct CanvasStorageReport: Codable, Equatable, Sendable {
    public let path: String
    public let fingerprint: String
    public let totalBytes: Int64
    public let retainedBytes: Int64
    public let obsoleteDrawingCount: Int
    public let pageCount: Int
    public let protectedAssets: Set<String>
    public let missingAssets: [String]
    public var blockers: [String]
    public var reclaimableBytes: Int64 { totalBytes - retainedBytes }
    public var canCompact: Bool { blockers.isEmpty && missingAssets.isEmpty && reclaimableBytes > 0 }
}

public struct PreparedCanvasCompaction: Codable, Sendable {
    public let report: CanvasStorageReport
    public let backupURL: URL
    public let compactURL: URL
}

public extension DocumentContent {
    var referencedAssetNames: Set<String> {
        Set(pages.flatMap { page in
            [page.drawingFile].compactMap { $0 } + page.shards.map(\.file)
                + page.objects.filter { $0.kind == .image }.map(\.content)
        })
    }
}

/// No recovery or deletion is performed by inspection. The original manifest
/// bytes and every retained file are preserved, including unknown JSON fields.
enum CanvasPackageMaintenance {
    struct FileRecord: Codable, Equatable {
        let name: String
        let bytes: Int64
        let sha256: String
    }
    struct Snapshot {
        let report: CanvasStorageReport
        let files: [FileRecord]
        let obsolete: Set<String>
    }
    static var fm: FileManager { .default }

    static func inspect(_ package: URL, path: String, keeping: Set<String>) throws -> Snapshot {
        let package = package.standardizedFileURL.resolvingSymlinksInPath()
        guard package.pathExtension == "studycanvas" else { throw StudyError.invalidPath }
        let availability = try package.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard availability.ubiquitousItemDownloadingStatus != .notDownloaded else {
            throw StudyError.modelUnavailable("Сначала скачайте документ из iCloud через приложение «Файлы».")
        }
        let manifestURL = try relativeURL(package, name: "manifest.json")
        let manifestValues = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true else { throw StudyError.invalidPath }
        let manifest = try Data(contentsOf: manifestURL)
        let content = try JSONDecoder().decode(DocumentContent.self, from: manifest)
        guard content.schemaVersion == 1, content.kind != .markdown else { throw StudyError.unsupportedVersion }
        var referenced = content.referencedAssetNames.union(keeping)
        // Preserve references added by newer schema-1 clients as well.
        func visitJSON(_ value: Any) {
            if let name = value as? String, name.hasPrefix("assets/") { referenced.insert(name) }
            else if let values = value as? [Any] { values.forEach(visitJSON) }
            else if let values = value as? [String: Any] { values.values.forEach(visitJSON) }
        }
        visitJSON(try JSONSerialization.jsonObject(with: manifest))
        for name in referenced { _ = try relativeURL(package, name: name) }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey]
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: package, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            enumerationError = error; return false
        }) else { throw CocoaError(.fileReadUnknown) }
        var files: [FileRecord] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw StudyError.invalidPath }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw StudyError.invalidPath }
            guard values.ubiquitousItemDownloadingStatus != .notDownloaded else {
                throw StudyError.modelUnavailable("Не все вложения скачаны из iCloud. Скачайте весь документ и повторите анализ.")
            }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(package.path + "/") else { throw StudyError.invalidPath }
            let name = String(canonical.path.dropFirst(package.path.count + 1))
            let bytes = Int64(values.fileSize ?? 0)
            files.append(.init(name: name, bytes: bytes, sha256: try hashFile(url, expectedBytes: bytes)))
        }
        if let enumerationError { throw enumerationError }
        files.sort { $0.name < $1.name }
        let present = Set(files.map(\.name))
        let obsolete = Set(files.map(\.name).filter {
            $0.hasPrefix("assets/") && $0.hasSuffix(".drawing") && !referenced.contains($0)
        })
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        let retained = files.filter { !obsolete.contains($0.name) }.reduce(Int64(0)) { $0 + $1.bytes }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = SHA256.hash(data: try encoder.encode(files) + encoder.encode(keeping.sorted())).map { String(format: "%02x", $0) }.joined()
        let missing = referenced.subtracting(present).sorted()
        var blockers = missing.isEmpty ? [] : ["В документе отсутствуют вложения. Очистка заблокирована до восстановления."]
        for name in referenced.intersection(present).sorted() where name.hasSuffix(".drawing") {
            do { _ = try PKDrawing(data: Data(contentsOf: relativeURL(package, name: name))) }
            catch { blockers.append("Не удалось прочитать рисунок: " + name) }
        }
        let report = CanvasStorageReport(path: path, fingerprint: fingerprint, totalBytes: total, retainedBytes: retained,
            obsoleteDrawingCount: obsolete.count, pageCount: content.pages.count, protectedAssets: keeping,
            missingAssets: missing, blockers: blockers)
        return Snapshot(report: report, files: files, obsolete: obsolete)
    }

    static func prepare(_ package: URL, snapshot: Snapshot, directory: URL) throws -> PreparedCanvasCompaction {
        guard snapshot.report.canCompact else { throw StudyError.modelUnavailable("Для этого документа очистка недоступна.") }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard !directory.path.hasPrefix(package.path + "/"), directory != package,
              !package.path.hasPrefix(directory.path + "/") else { throw StudyError.invalidPath }
        var ancestor = directory
        while !fm.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        guard !fm.isUbiquitousItem(at: ancestor) else {
            throw StudyError.modelUnavailable("Для резервной копии нужна локальная папка вне iCloud.")
        }
        let operation = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: operation, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = operation.appendingPathComponent("Original", isDirectory: true).appendingPathComponent(package.lastPathComponent)
        let compact = operation.appendingPathComponent("Compact", isDirectory: true).appendingPathComponent(package.lastPathComponent)
        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: package, to: backup)
        let verifiedBackup = try inspect(backup, path: snapshot.report.path, keeping: snapshot.report.protectedAssets)
        guard verifiedBackup.files == snapshot.files else { throw StudyError.staleRevision }
        // Copy only retained bytes; obsolete drawings remain in the full backup.
        try fm.createDirectory(at: compact, withIntermediateDirectories: true)
        for file in snapshot.files where !snapshot.obsolete.contains(file.name) {
            let source = try relativeURL(package, name: file.name), target = try relativeURL(compact, name: file.name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
        }
        try verifyCompact(compact, snapshot: snapshot)
        let prepared = PreparedCanvasCompaction(report: snapshot.report, backupURL: backup, compactURL: compact)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(prepared).write(to: operation.appendingPathComponent("report.json"), options: .atomic)
        return prepared
    }

    static func verifyCompact(_ compact: URL, snapshot: Snapshot) throws {
        let inspected = try inspect(compact, path: snapshot.report.path, keeping: snapshot.report.protectedAssets)
        guard inspected.files == snapshot.files.filter({ !snapshot.obsolete.contains($0.name) }),
              inspected.report.missingAssets.isEmpty else { throw StudyError.staleRevision }
    }

    static func relativeURL(_ package: URL, name: String) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\0"),
              !name.split(separator: "/").contains("..") else { throw StudyError.invalidPath }
        let url = package.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(package.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { throw StudyError.invalidPath }
        return url
    }

    static func hashFile(_ url: URL, expectedBytes: Int64) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data); bytes += Int64(data.count) }
        guard bytes == expectedBytes else { throw StudyError.staleRevision }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
