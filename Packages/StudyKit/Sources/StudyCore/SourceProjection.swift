import Foundation

/// Reconciles an edit to a same-length presentation (e.g. image attachment markers)
/// with its lossless Markdown source. Unchanged presentation characters never leak to disk.
public enum SourceProjection {
    public static func applyingEdit(source: String, oldDisplay: String, newDisplay: String) -> String {
        let before = Array(oldDisplay.utf16), after = Array(newDisplay.utf16)
        // The editor presentation currently keeps the same backing characters as
        // the Markdown source. If UIKit delivers delegate callbacks out of order,
        // preserving the current text is safer than silently restoring stale data.
        guard before.count == source.utf16.count else { return newDisplay }
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        // Keep UTF-16 surrogate pairs indivisible.
        if prefix > 0 && prefix < before.count && (0xDC00...0xDFFF).contains(before[prefix]) { prefix -= 1 }
        var suffix = 0
        while suffix < before.count - prefix && suffix < after.count - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        if suffix > 0 && suffix < before.count && (0xDC00...0xDFFF).contains(before[before.count - suffix]) { suffix -= 1 }
        let replacement = (newDisplay as NSString).substring(with: NSRange(location: prefix, length: after.count - prefix - suffix))
        return (source as NSString).replacingCharacters(in: NSRange(location: prefix, length: before.count - prefix - suffix), with: replacement)
    }
}
