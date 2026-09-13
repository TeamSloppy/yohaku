import Foundation
import StudyCore

struct MarkdownLinkCompletionQuery: Equatable {
    let text: String
    let replacementRange: NSRange
}

struct MarkdownAutomaticEdit: Equatable {
    let replacementRange: NSRange
    let replacementText: String
    let selection: NSRange
    let changesText: Bool
}

enum MarkdownEditingSupport {
    static func linkQuery(in text: String, selection: NSRange) -> MarkdownLinkCompletionQuery? {
        let source = text as NSString
        guard selection.length == 0, selection.location <= source.length else { return nil }
        let beforeCaret = source.substring(to: selection.location) as NSString
        let opener = beforeCaret.range(of: "[[", options: .backwards)
        guard opener.location != NSNotFound else { return nil }

        let queryRange = NSRange(location: NSMaxRange(opener), length: selection.location - NSMaxRange(opener))
        let query = source.substring(with: queryRange)
        guard !query.contains("\n"), !query.contains("\r"), !query.contains("[["), !query.contains("]]") else { return nil }

        var replacementEnd = selection.location
        if replacementEnd + 2 <= source.length, source.substring(with: NSRange(location: replacementEnd, length: 2)) == "]]" {
            replacementEnd += 2
        }
        return .init(text: query, replacementRange: NSRange(location: opener.location, length: replacementEnd - opener.location))
    }

    static func suggestions(entries: [VaultEntry], query: String, currentPath: String, limit: Int = 8) -> [VaultEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func score(_ entry: VaultEntry) -> Int? {
            guard entry.path != currentPath else { return nil }
            if needle.isEmpty { return entry.isDirectory ? 0 : 1 }
            if entry.title.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 0 }
            if entry.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 1 }
            if entry.title.localizedCaseInsensitiveContains(needle) { return 2 }
            if entry.path.localizedCaseInsensitiveContains(needle) { return 3 }
            return nil
        }
        return entries.compactMap { entry in score(entry).map { ($0, entry) } }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                if lhs.1.isDirectory != rhs.1.isDirectory { return lhs.1.isDirectory }
                return lhs.1.path.localizedStandardCompare(rhs.1.path) == .orderedAscending
            }
            .prefix(limit)
            .map(\.1)
    }

    static func link(to entry: VaultEntry, from source: String) -> String {
        let relative = NoteLinks.relativePath(to: entry.path, from: source)
        let destination = entry.isDirectory ? (relative.isEmpty ? "./" : relative + "/") : relative
        let title = entry.title.replacingOccurrences(of: "]", with: "\\]")
        return "[\(title)](\(destination))"
    }

    static func automaticEdit(in text: String, range: NSRange, replacement: String) -> MarkdownAutomaticEdit? {
        let source = text as NSString
        guard range.location <= source.length, NSMaxRange(range) <= source.length,
              replacement.utf16.count == 1 else { return nil }
        if range.location > 0, source.substring(with: NSRange(location: range.location - 1, length: 1)) == "\\" { return nil }

        let closers: Set<String> = [")", "]", "}", "\"", "'", "`", "»"]
        if range.length == 0, closers.contains(replacement), range.location < source.length,
           source.substring(with: NSRange(location: range.location, length: 1)) == replacement {
            return .init(replacementRange: range, replacementText: "", selection: NSRange(location: range.location + 1, length: 0), changesText: false)
        }

        let pairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`", "«": "»"]
        guard let closer = pairs[replacement] else { return nil }
        let selected = source.substring(with: range)
        return .init(
            replacementRange: range,
            replacementText: replacement + selected + closer,
            selection: NSRange(location: range.location + 1, length: range.length),
            changesText: true
        )
    }
}
