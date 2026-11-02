import Foundation

public struct VaultFileSyncStatus: Equatable, Sendable {
    public enum State: Int, Sendable {
        case local, synced, downloaded, checking, outdated, waitingForUpload, cloudOnly, uploading, downloading, conflict, failed
    }
    public var state: State
    public var isAvailableLocally: Bool
    public var detail: String?

    public init(_ state: State, isAvailableLocally: Bool = true, detail: String? = nil) {
        self.state = state; self.isAvailableLocally = isAvailableLocally; self.detail = detail
    }

    /// A package is only offline-ready when every asset is on this device.
    public static func combined(_ statuses: [Self]) -> Self {
        let dominant = statuses.max { $0.state.rawValue < $1.state.rawValue } ?? .init(.local)
        return .init(dominant.state, isAvailableLocally: statuses.allSatisfy(\.isAvailableLocally), detail: dominant.detail)
    }
}

public protocol VaultCloudFileAccess: Sendable {
    func status(at url: URL) throws -> VaultFileSyncStatus
    func requestDownload(at url: URL) throws
}

public struct SystemVaultCloudFileAccess: VaultCloudFileAccess {
    public init() {}
    public func status(at url: URL) throws -> VaultFileSyncStatus {
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .isDirectoryKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey,
            .ubiquitousItemHasUnresolvedConflictsKey
        ])
        guard values.isUbiquitousItem == true else { return .init(.local) }
        let available = values.ubiquitousItemDownloadingStatus != .notDownloaded
        if let error = values.ubiquitousItemDownloadingError ?? values.ubiquitousItemUploadingError {
            return .init(.failed, isAvailableLocally: available, detail: error.localizedDescription)
        }
        if values.ubiquitousItemHasUnresolvedConflicts == true { return .init(.conflict, isAvailableLocally: available) }
        if values.ubiquitousItemIsDownloading == true { return .init(.downloading, isAvailableLocally: available) }
        if values.ubiquitousItemIsUploading == true { return .init(.uploading, isAvailableLocally: available) }
        if !available { return .init(.cloudOnly, isAvailableLocally: false) }
        if values.ubiquitousItemIsUploaded == false { return .init(.waitingForUpload) }
        if values.ubiquitousItemDownloadingStatus == .downloaded { return .init(.outdated) }
        if values.ubiquitousItemDownloadingStatus == .current {
            return .init(values.ubiquitousItemIsUploaded == true ? .synced : .downloaded)
        }
        // Directories often have no download status; inspect their children instead.
        return .init(values.isDirectory == true ? .local : .checking, isAvailableLocally: values.isDirectory == true)
    }
    public func requestDownload(at url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}

public struct VaultSyncSnapshot: Sendable {
    public var files: [String: VaultFileSyncStatus]
    public var overall: VaultFileSyncStatus
}

extension VaultStore {
    public func syncSnapshot() throws -> VaultSyncSnapshot {
        let documents = try list().filter { !$0.isDirectory }
        var files: [String: VaultFileSyncStatus] = [:]
        for entry in documents { files[entry.path] = try fileSyncStatus(entry.path) }
        // Cards, study progress, Markdown metadata and deletion markers also sync.
        let metadataURL = root.appendingPathComponent(".workspace", isDirectory: true)
        let metadata = try syncItems(at: metadataURL).map { syncStatus(at: $0) }
        return .init(files: files, overall: .combined(Array(files.values) + metadata))
    }

    public func fileSyncStatus(_ path: String) throws -> VaultFileSyncStatus {
        .combined(try syncItems(at: fileURL(path)).map { syncStatus(at: $0) })
    }

    /// Enqueue transfers without coordinated reads or loading canvas manifests.
    /// iCloud owns upload scheduling; saving local edits makes them eligible.
    public func requestCloudDownloads(_ path: String? = nil) throws -> [String: String] {
        let url = try path.map { try fileURL($0) } ?? root
        var failures: [String: String] = [:]
        for item in try syncItems(at: url) {
            do {
                let status = try cloudFiles.status(at: item)
                if !status.isAvailableLocally || status.state == .outdated || status.state == .failed {
                    try cloudFiles.requestDownload(at: item)
                }
            } catch { failures[item.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")] = error.localizedDescription }
        }
        return failures
    }

    private func syncStatus(at url: URL) -> VaultFileSyncStatus {
        do { return try cloudFiles.status(at: url) }
        catch { return .init(.failed, isAvailableLocally: false, detail: error.localizedDescription) }
    }

    private func syncItems(at url: URL) throws -> [URL] {
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { return [] }
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        var items = [url]
        if let status = try? cloudFiles.status(at: url), !status.isAvailableLocally { return items }
        if values.isDirectory == true {
            // Explicit recursion reports enumeration failures instead of silently
            // claiming a partially downloaded package is ready for a lesson.
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)) {
                if url.pathComponents == root.appendingPathComponent(".workspace").pathComponents, child.lastPathComponent == "trash" { continue }
                items += try syncItems(at: child)
            }
        }
        return items
    }
}
