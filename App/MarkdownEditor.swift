import StudyCore
import SwiftUI
import UIKit

/// Live Preview only changes presentation attributes. The backing UTF-16 string stays Markdown.
struct MarkdownEditor: UIViewRepresentable {
    let session: DocumentSession
    let sourceMode: Bool
    let cursor: Int
    let onSelection: (String, Int) -> Void
    let onLink: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.delegate = context.coordinator; view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 28, left: 12, bottom: 80, right: 12)
        view.text = session.content.markdown
        view.selectedRange = NSRange(location: min(cursor, (view.text as NSString).length), length: 0)
        view.accessibilityIdentifier = "markdown-editor"
        view.font = .systemFont(ofSize: 18); view.adjustsFontForContentSizeCategory = true
        context.coordinator.style(view)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let changedMode = context.coordinator.parent.sourceMode != sourceMode
        context.coordinator.parent = self
        guard view.markedTextRange == nil else { return }
        if context.coordinator.baseSource != session.content.markdown {
            let selected = view.selectedRange
            context.coordinator.styling = true
            view.text = session.content.markdown
            view.selectedRange = NSRange(location: min(selected.location, (view.text as NSString).length), length: 0)
            context.coordinator.styling = false
            context.coordinator.style(view)
        } else if changedMode { context.coordinator.style(view) }
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor
        var styling = false
        var baseSource = ""
        var lastDisplay = ""
        var images: [String: UIImage] = [:]
        var requested: Set<String> = []
        var imageViews: [UIView] = []
        var activeParagraph = NSRange(location: NSNotFound, length: 0)
        init(_ parent: MarkdownEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            guard !styling else { return }
            let display = textView.text ?? ""
            let text = SourceProjection.applyingEdit(source: baseSource, oldDisplay: lastDisplay, newDisplay: display)
            baseSource = text; lastDisplay = display
            parent.session.edit { $0.markdown = text }
            if textView.markedTextRange == nil { style(textView) }
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !styling, textView.markedTextRange == nil else { return }
            let text = baseSource as NSString
            let range = textView.selectedRange
            guard range.location <= text.length, range.location + range.length <= text.length else { return }
            parent.onSelection(text.substring(with: range), range.location)
            let paragraph = text.paragraphRange(for: NSRange(location: range.location, length: 0))
            if paragraph != activeParagraph { style(textView) }
        }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            parent.onLink(URL.absoluteString); return false
        }
        func style(_ view: UITextView) {
            guard !styling, view.markedTextRange == nil else { return }
            styling = true; defer { styling = false }
            let text = parent.session.content.markdown as NSString, full = NSRange(location: 0, length: text.length)
            baseSource = text as String
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6; paragraph.paragraphSpacing = 10
            activeParagraph = text.paragraphRange(for: NSRange(location: min(view.selectedRange.location, text.length), length: 0))
            let storage = view.textStorage
            let selected = view.selectedRange
            storage.beginEditing()
            imageViews.forEach { $0.removeFromSuperview() }; imageViews = []
            var pendingImages: [(UIImage, NSRange, CGSize)] = []
        var pendingTasks: [(marker: NSRange, title: NSRange, checked: Bool, name: String)] = []
            defer {
                storage.endEditing(); lastDisplay = storage.string
                view.selectedRange = NSRange(location: min(selected.location, storage.length), length: min(selected.length, max(0, storage.length - selected.location)))
                for (image, range, size) in pendingImages {
                    guard let position = view.position(from: view.beginningOfDocument, offset: range.location),
                          let end = view.position(from: position, offset: 1), let textRange = view.textRange(from: position, to: end) else { continue }
                    let frame = view.firstRect(for: textRange)
                    let preview = UIImageView(image: image); preview.contentMode = .scaleAspectFit
                    preview.frame = CGRect(x: view.textContainerInset.left + 5, y: frame.minY, width: size.width, height: size.height)
                    preview.isUserInteractionEnabled = false; view.addSubview(preview); imageViews.append(preview)
                }
                for task in pendingTasks {
                    // The Markdown marker is intentionally invisible in Live Preview, so it has no
                    // reliable layout rect. Position the native control from the visible title instead.
                    guard let start = view.position(from: view.beginningOfDocument, offset: task.title.location),
                          let end = view.position(from: start, offset: 1), let textRange = view.textRange(from: start, to: end) else { continue }
                    let titleRect = view.firstRect(for: textRange)
                    let button = UIButton(type: .system)
                    button.setImage(UIImage(systemName: task.checked ? "checkmark.square.fill" : "square"), for: .normal)
                    button.tintColor = .systemTeal
                    button.frame = CGRect(x: titleRect.minX - 29, y: titleRect.minY, width: 25, height: 25)
                    button.accessibilityLabel = task.name
                    button.accessibilityValue = task.checked ? "Выполнено" : "Не выполнено"
                    button.addAction(UIAction { [weak view] _ in
                        guard let view, let a = view.position(from: view.beginningOfDocument, offset: task.marker.location),
                              let b = view.position(from: a, offset: 1), let target = view.textRange(from: a, to: b) else { return }
                        view.replace(target, withText: task.checked ? " " : "x")
                    }, for: .touchUpInside)
                    view.addSubview(button); imageViews.append(button)
                }
            }
            storage.setAttributes([.font: parent.sourceMode ? UIFont.monospacedSystemFont(ofSize: 16, weight: .regular) : UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.label, .paragraphStyle: paragraph], range: full)
            guard !parent.sourceMode else { return }
            func matches(_ pattern: String, _ body: (NSTextCheckingResult) -> Void) {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
                regex.enumerateMatches(in: text as String, range: full) { match, _, _ in if let match { body(match) } }
            }
            func hide(_ range: NSRange, force: Bool = false) {
                guard force || NSIntersectionRange(range, activeParagraph).length == 0 else {
                    storage.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: range); return
                }
                storage.addAttributes([.font: UIFont.systemFont(ofSize: 0.1), .foregroundColor: UIColor.clear, .kern: 0], range: range)
            }
            matches(#"^(#{1,6}) (.+)$"#) { match in
                let level = match.range(at: 1).length
                let size: CGFloat = level == 1 ? 32 : level == 2 ? 25 : 21
                storage.addAttributes([.font: UIFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: UIColor.label], range: match.range)
                hide(NSRange(location: match.range.location, length: level + 1))
            }
            matches(#"\*\*([^*\n]+)\*\*"#) { match in
                storage.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 18), range: match.range(at: 1))
                hide(NSRange(location: match.range.location, length: 2)); hide(NSRange(location: NSMaxRange(match.range) - 2, length: 2))
            }
            matches(#"(?<!\*)\*([^*\n]+)\*(?!\*)"#) { match in
                storage.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: 18), range: match.range(at: 1))
                hide(NSRange(location: match.range.location, length: 1)); hide(NSRange(location: NSMaxRange(match.range) - 1, length: 1))
            }
            matches(#"`([^`\n]+)`"#) { match in
                storage.addAttributes([.font: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular), .backgroundColor: UIColor.secondarySystemFill], range: match.range(at: 1))
                hide(NSRange(location: match.range.location, length: 1)); hide(NSRange(location: NSMaxRange(match.range) - 1, length: 1))
            }
            matches(#"^> (.*)$"#) { match in
                storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: match.range)
            }
            matches(#"^- \[([ xX])\] (.+)$"#) { match in
                let checked = text.substring(with: match.range(at: 1)).lowercased() == "x"
                let itemStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
                itemStyle.firstLineHeadIndent = 30; itemStyle.headIndent = 30
                storage.addAttribute(.paragraphStyle, value: itemStyle, range: match.range)
                hide(NSRange(location: match.range.location, length: match.range(at: 2).location - match.range.location), force: true)
                if checked { storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: UIColor.secondaryLabel], range: match.range(at: 2)) }
                pendingTasks.append((match.range(at: 1), match.range(at: 2), checked, text.substring(with: match.range(at: 2))))
            }
            matches(#"!?\[([^\]]*)\]\(([^\s\)]+)\)"#) { match in
                let destination = text.substring(with: match.range(at: 2))
                storage.addAttributes([.foregroundColor: UIColor.systemTeal, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range(at: 1))
                if let url = URL(string: destination) { storage.addAttribute(.link, value: url, range: match.range(at: 1)) }
                hide(NSRange(location: match.range.location, length: match.range(at: 1).location - match.range.location))
                hide(NSRange(location: NSMaxRange(match.range(at: 1)), length: NSMaxRange(match.range) - NSMaxRange(match.range(at: 1))))
            }
            matches(#"(?s)^```[^\n]*\n.*?^```"#) { match in
                storage.addAttributes([.font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: UIColor.secondaryLabel, .backgroundColor: UIColor.secondarySystemFill], range: match.range)
            }
            matches(#"!\[[^\]]*\]\(([^\s\)]+)\)"#) { match in
                guard NSIntersectionRange(match.range, activeParagraph).length == 0 else { return }
                let destination = text.substring(with: match.range(at: 1))
                guard let path = NoteLinks.resolve(destination, source: parent.session.path)?.path else { return }
                if let image = images[path] {
                    hide(match.range)
                    let width = min(420, max(120, view.bounds.width - 64)), height = width * image.size.height / image.size.width
                    let imageParagraph = NSMutableParagraphStyle()
                    imageParagraph.minimumLineHeight = min(420, height) + 16
                    imageParagraph.maximumLineHeight = min(420, height) + 16
                    storage.addAttribute(.paragraphStyle, value: imageParagraph, range: match.range)
                    pendingImages.append((image, match.range, CGSize(width: width, height: min(420, height))))
                } else if requested.insert(path).inserted {
                    Task { [weak self, weak view] in
                        guard let self else { return }
                        if let data = try? await parent.session.store.readFile(path), let image = UIImage(data: data) { images[path] = image }
                        if let view, view.markedTextRange == nil { style(view) }
                    }
                }
            }
        }
    }
}
