import Foundation

public enum NoteLinks {
    public static func destinations(in text: String) -> [String] {
        matches(text).map { (text as NSString).substring(with: $0.range(at: 1)) }
    }
    public static func resolve(_ destination: String, source: String) -> (path: String, fragment: String?)? {
        guard URLComponents(string: destination)?.scheme == nil, !destination.hasPrefix("/") else { return nil }
        let parts = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let raw = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let sourceURL = URL(fileURLWithPath: "/vault/" + source)
        let path = raw.isEmpty ? sourceURL : sourceURL.deletingLastPathComponent().appendingPathComponent(raw).standardizedFileURL
        guard path.path.hasPrefix("/vault/") else { return nil }
        return (String(path.path.dropFirst(7)), parts.count > 1 ? String(parts[1]) : nil)
    }
    public static func relativePath(to target: String, from source: String) -> String {
        var left = Array(source.split(separator: "/").dropLast())
        var right = Array(target.split(separator: "/"))
        while !left.isEmpty && !right.isEmpty && left[0] == right[0] { left.removeFirst(); right.removeFirst() }
        return (Array(repeating: "..", count: left.count) + right.map(String.init)).joined(separator: "/")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
    }
    public static func rewriteDestination(_ destination: String, source: String, newSource: String, map: (String) -> String) -> String {
        guard let resolved = resolve(destination, source: source) else { return destination }
        let path = relativePath(to: map(resolved.path), from: newSource)
        return path + (resolved.fragment.map { "#" + $0 } ?? "")
    }
    public static func rewrite(_ text: String, source: String, newSource: String, map: (String) -> String) -> String {
        let result = NSMutableString(string: text)
        for match in matches(text).reversed() {
            let range = match.range(at: 1)
            result.replaceCharacters(in: range, with: rewriteDestination((text as NSString).substring(with: range), source: source, newSource: newSource, map: map))
        }
        return result as String
    }
    private static func matches(_ text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: #"!?\[[^\]]*\]\(([^\s\)]+)\)"#) else { return [] }
        let full = NSRange(location: 0, length: (text as NSString).length)
        let code = try? NSRegularExpression(pattern: #"(?ms)^```.*?^```[^\n]*|`[^`\n]*`"#)
        let protected = code?.matches(in: text, range: full).map(\.range) ?? []
        return regex.matches(in: text, range: full).filter { match in !protected.contains { NSIntersectionRange($0, match.range).length > 0 } }
    }
}
