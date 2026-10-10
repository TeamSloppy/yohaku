import Foundation
import StudyCore

@main struct CanvasMaintenanceCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count >= 2, ["analyze", "prepare"].contains(arguments[0]),
                  arguments[0] != "prepare" || arguments.count == 3 else {
                throw StudyError.modelUnavailable("Usage: yohaku-canvas-maintenance analyze <vault> | prepare <vault> <local-backup-directory>\nThis tool never replaces or deletes original documents.")
            }
            let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let store = VaultStore(root: root)
            var output: URL?
            if arguments[0] == "prepare" {
                let directory = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
                guard directory != root, !directory.path.hasPrefix(root.path + "/"), !root.path.hasPrefix(directory.path + "/") else { throw StudyError.invalidPath }
                var ancestor = directory
                while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
                guard !FileManager.default.isUbiquitousItem(at: ancestor) else { throw StudyError.modelUnavailable("Backup directory must be local, outside iCloud.") }
                output = directory
            }
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in
                enumerationError = error; return false
            }) else { throw CocoaError(.fileReadUnknown) }
            var paths: [String] = []
            while let url = enumerator.nextObject() as? URL {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if url.pathExtension == "studycanvas" {
                    paths.append(String(url.path.dropFirst(root.path.count + 1))); enumerator.skipDescendants()
                }
            }
            if let enumerationError { throw enumerationError }
            var reports: [CanvasStorageReport] = [], prepared: [PreparedCanvasCompaction] = []
            var failures: [String: String] = [:]
            for path in paths.sorted() {
                do {
                    let report = try await store.analyzeCanvasStorage(path)
                    reports.append(report)
                    if let output, report.canCompact {
                        prepared.append(try await store.prepareCanvasCompaction(report, backupDirectory: output))
                    }
                } catch {
                    failures[path] = error.localizedDescription
                    FileHandle.standardError.write(Data((path + ": " + error.localizedDescription + "\n").utf8))
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let data = try encoder.encode(prepared)
                try data.write(to: output.appendingPathComponent("prepared-copies.json"), options: .atomic)
                try encoder.encode(reports).write(to: output.appendingPathComponent("analysis.json"), options: .atomic)
                try encoder.encode(failures).write(to: output.appendingPathComponent("errors.json"), options: .atomic)
                print(String(decoding: data, as: UTF8.self))
            } else { print(String(decoding: try encoder.encode(reports), as: UTF8.self)) }
            if !failures.isEmpty { exit(1) }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
