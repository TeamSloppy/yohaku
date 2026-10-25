import Foundation

/// A title edit preserves the item's parent folder and the document's format.
struct DocumentRename {
    let path: String
    let isDirectory: Bool

    var name: String {
        let filename = (path as NSString).lastPathComponent
        return isDirectory ? filename : (filename as NSString).deletingPathExtension
    }

    func destination(for title: String) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != ".", title != "..",
              title.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\0\n\r")) == nil else { return nil }
        let ext = isDirectory ? "" : (path as NSString).pathExtension
        let filename = ext.isEmpty ? title : title + "." + ext
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? filename : (parent as NSString).appendingPathComponent(filename)
    }
}
