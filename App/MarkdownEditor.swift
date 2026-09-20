import StudyCore
import SwiftUI
import UIKit

final class MarkdownTextView: UITextView {
    var onLayout: ((MarkdownTextView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}

final class MarkdownEditorContainer: UIView {
    // TextKit 2 on Mac Catalyst can redraw only part of a range after changing
    // its font to the tiny font used for hidden Markdown syntax. That leaves
    // fragments such as "[" and "canvas)" visible until the next full layout.
    // TextKit 1 applies those presentation attributes consistently while still
    // keeping the lossless Markdown source in the text storage.
    let textView = MarkdownTextView(usingTextLayoutManager: false)
    private let completionPanel = UIView()
    private let completionStack = UIStackView()
    private var completionAnchor = CGRect.zero
    private var completionHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(textView)
        completionPanel.backgroundColor = .secondarySystemBackground
        completionPanel.layer.cornerRadius = 12
        completionPanel.layer.borderWidth = 1 / max(1, traitCollection.displayScale)
        completionPanel.layer.borderColor = UIColor.separator.cgColor
        completionPanel.layer.shadowColor = UIColor.black.cgColor
        completionPanel.layer.shadowOpacity = 0.18
        completionPanel.layer.shadowRadius = 12
        completionPanel.layer.shadowOffset = CGSize(width: 0, height: 5)
        completionStack.axis = .vertical
        completionStack.alignment = .fill
        completionPanel.addSubview(completionStack)
        addSubview(completionPanel)
        completionPanel.isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        layoutCompletionPanel()
    }

    func showCompletion(entries: [VaultEntry], anchor: CGRect, onSelect: @escaping (VaultEntry) -> Void) {
        prepareCompletion(anchor: anchor)
        if entries.isEmpty {
            let label = UILabel()
            label.text = String(localized: "Нет подходящих заметок или папок")
            label.textColor = .secondaryLabel
            label.font = .systemFont(ofSize: 14)
            label.textAlignment = .center
            label.accessibilityIdentifier = "markdown-link-completion-empty"
            completionStack.addArrangedSubview(label)
            completionHeight = 52
        } else {
            for entry in entries {
                var configuration = UIButton.Configuration.plain()
                configuration.title = entry.title
                configuration.subtitle = entry.isDirectory ? entry.path + "/" : entry.path
                configuration.image = UIImage(systemName: entry.isDirectory ? "folder" : (entry.kind?.symbol ?? "doc"))
                configuration.imagePadding = 10
                configuration.titleAlignment = .leading
                configuration.baseForegroundColor = .label
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)
                let button = UIButton(configuration: configuration)
                button.contentHorizontalAlignment = .leading
                button.accessibilityIdentifier = "markdown-link-completion-\(entry.path)"
                button.addAction(UIAction { _ in onSelect(entry) }, for: .touchUpInside)
                completionStack.addArrangedSubview(button)
            }
            completionHeight = CGFloat(entries.count * 48 + 12)
        }
        completionPanel.isHidden = false
        completionPanel.isAccessibilityElement = false
        completionPanel.accessibilityIdentifier = "markdown-link-completion"
        setNeedsLayout()
        layoutIfNeeded()
    }

    func showCommands(_ commands: [MarkdownSlashCommand], anchor: CGRect, onSelect: @escaping (MarkdownSlashCommand) -> Void) {
        prepareCompletion(anchor: anchor)
        if commands.isEmpty {
            let label = UILabel()
            label.text = "Нет подходящих команд"
            label.textColor = .secondaryLabel
            label.font = .systemFont(ofSize: 14)
            label.textAlignment = .center
            label.accessibilityIdentifier = "markdown-slash-command-empty"
            completionStack.addArrangedSubview(label)
            completionHeight = 52
        } else {
            for command in commands {
                var configuration = UIButton.Configuration.plain()
                configuration.title = command.title
                configuration.subtitle = command.subtitle
                configuration.image = UIImage(systemName: command.symbol)
                configuration.imagePadding = 10
                configuration.titleAlignment = .leading
                configuration.baseForegroundColor = .label
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)
                let button = UIButton(configuration: configuration)
                button.contentHorizontalAlignment = .leading
                button.accessibilityIdentifier = "markdown-slash-command-\(command.id)"
                button.addAction(UIAction { _ in onSelect(command) }, for: .touchUpInside)
                completionStack.addArrangedSubview(button)
            }
            completionHeight = CGFloat(commands.count * 48 + 12)
        }
        completionPanel.accessibilityIdentifier = "markdown-slash-command-menu"
        completionPanel.isHidden = false
        setNeedsLayout()
        layoutIfNeeded()
    }

    func hideCompletion() {
        completionPanel.isHidden = true
    }

    private func prepareCompletion(anchor: CGRect) {
        completionStack.arrangedSubviews.forEach { view in completionStack.removeArrangedSubview(view); view.removeFromSuperview() }
        completionAnchor = anchor
        completionPanel.isAccessibilityElement = false
    }

    private func layoutCompletionPanel() {
        guard !completionPanel.isHidden else { return }
        let visibleBounds = bounds.insetBy(dx: 12, dy: 12)
        let width = min(380, max(220, visibleBounds.width))
        let x = min(max(visibleBounds.minX, completionAnchor.minX), max(visibleBounds.minX, visibleBounds.maxX - width))
        let below = completionAnchor.maxY + 7
        let y = below + completionHeight <= visibleBounds.maxY ? below : max(visibleBounds.minY, completionAnchor.minY - completionHeight - 7)
        completionPanel.frame = CGRect(x: x, y: y, width: width, height: completionHeight)
        completionStack.frame = completionPanel.bounds.insetBy(dx: 6, dy: 6)
        bringSubviewToFront(completionPanel)
    }
}

/// Live Preview only changes presentation attributes. The backing UTF-16 string stays Markdown.
struct MarkdownEditor: UIViewRepresentable {
    let session: DocumentSession
    let sourceMode: Bool
    let cursor: Int
    let onSelection: (String, Int) -> Void
    let onLink: (String) -> Void
    var entries: [VaultEntry] = []
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MarkdownEditorContainer {
        let container = MarkdownEditorContainer()
        let view = container.textView
        context.coordinator.attach(to: view, container: container)
        view.delegate = context.coordinator; view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 28, left: 12, bottom: 80, right: 12)
        view.text = session.content.markdown
        view.selectedRange = NSRange(location: min(cursor, (view.text as NSString).length), length: 0)
        view.accessibilityIdentifier = "markdown-editor"
        view.font = .systemFont(ofSize: 18); view.adjustsFontForContentSizeCategory = true
        context.coordinator.style(view)
        context.coordinator.updateCompletion(view)
        return container
    }
    func updateUIView(_ container: MarkdownEditorContainer, context: Context) {
        let view = container.textView
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
        context.coordinator.updateCompletion(view)
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
        private var imageOverlays: [(view: UIImageView, range: NSRange)] = []
        private var taskOverlays: [(button: UIButton, title: NSRange)] = []
        private weak var container: MarkdownEditorContainer?
        init(_ parent: MarkdownEditor) { self.parent = parent }
        func attach(to view: MarkdownTextView, container: MarkdownEditorContainer? = nil) {
            self.container = container
            view.onLayout = { [weak self] view in self?.layoutOverlays(in: view) }
        }
        func textViewDidChange(_ textView: UITextView) {
            guard !styling else { return }
            let display = textView.text ?? ""
            let text = SourceProjection.applyingEdit(source: baseSource, oldDisplay: lastDisplay, newDisplay: display)
            baseSource = text; lastDisplay = display
            parent.session.edit { $0.markdown = text }
            if textView.markedTextRange == nil { style(textView) }
            updateCompletion(textView)
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !styling, textView.markedTextRange == nil else { return }
            // UIKit can report the new selection before textViewDidChange. Do not
            // style the new string with ranges from the previous source revision;
            // textViewDidChange will reconcile the edit and style it immediately.
            guard (textView.text ?? "") == lastDisplay else { return }
            let text = baseSource as NSString
            let range = textView.selectedRange
            guard range.location <= text.length, range.location + range.length <= text.length else { return }
            parent.onSelection(text.substring(with: range), range.location)
            let paragraph = text.paragraphRange(for: NSRange(location: range.location, length: 0))
            if paragraph != activeParagraph { style(textView) }
            updateCompletion(textView)
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard textView.markedTextRange == nil,
                  let edit = MarkdownEditingSupport.automaticEdit(in: baseSource, range: range, replacement: text) else { return true }
            if edit.changesText {
                textView.textStorage.replaceCharacters(in: edit.replacementRange, with: edit.replacementText)
                textView.selectedRange = edit.selection
                textViewDidChange(textView)
            } else {
                textView.selectedRange = edit.selection
                textViewDidChangeSelection(textView)
            }
            return false
        }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            parent.onLink(URL.absoluteString); return false
        }
        func updateCompletion(_ textView: UITextView) {
            guard !styling, let container,
                  let position = textView.position(from: textView.beginningOfDocument, offset: textView.selectedRange.location) else {
                container?.hideCompletion(); return
            }
            let caret = textView.convert(textView.caretRect(for: position), to: container)
            let text = textView.text ?? baseSource
            if let query = MarkdownEditingSupport.linkQuery(in: text, selection: textView.selectedRange) {
                let entries = MarkdownEditingSupport.suggestions(entries: parent.entries, query: query.text, currentPath: parent.session.path)
                container.showCompletion(entries: entries, anchor: caret) { [weak self, weak textView] entry in
                    guard let self, let textView else { return }
                    applyCompletion(entry, to: textView)
                }
            } else if let query = MarkdownEditingSupport.slashQuery(in: text, selection: textView.selectedRange) {
                container.showCommands(MarkdownEditingSupport.slashCommands(matching: query.text), anchor: caret) { [weak self, weak textView] command in
                    guard let self, let textView else { return }
                    applySlashCommand(command, query: query, to: textView)
                }
            } else {
                container.hideCompletion()
            }
        }
        private func applyCompletion(_ entry: VaultEntry, to textView: UITextView) {
            if textView.markedTextRange != nil {
                textView.unmarkText()
                textViewDidChange(textView)
            }
            guard let query = MarkdownEditingSupport.linkQuery(in: textView.text ?? baseSource, selection: textView.selectedRange) else {
                container?.hideCompletion(); return
            }
            let link = MarkdownEditingSupport.link(to: entry, from: parent.session.path)
            textView.textStorage.replaceCharacters(in: query.replacementRange, with: link)
            textView.selectedRange = NSRange(location: query.replacementRange.location + (link as NSString).length, length: 0)
            textViewDidChange(textView)
            container?.hideCompletion()
        }
        private func applySlashCommand(_ command: MarkdownSlashCommand, query: MarkdownSlashCommandQuery, to textView: UITextView) {
            textView.textStorage.replaceCharacters(in: query.replacementRange, with: command.insertion)
            textView.selectedRange = NSRange(
                location: query.replacementRange.location + command.selection.location,
                length: command.selection.length
            )
            textViewDidChange(textView)
            container?.hideCompletion()
        }
        func style(_ view: UITextView) {
            guard !styling, view.markedTextRange == nil else { return }
            // Applying source ranges to a newer UITextView string corrupts both
            // presentation attributes and the next source reconciliation.
            guard (view.text ?? "") == parent.session.content.markdown else { return }
            styling = true; defer { styling = false }
            let text = parent.session.content.markdown as NSString, full = NSRange(location: 0, length: text.length)
            baseSource = text as String
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6; paragraph.paragraphSpacing = 10
            activeParagraph = text.paragraphRange(for: NSRange(location: min(view.selectedRange.location, text.length), length: 0))
            let storage = view.textStorage
            let selected = view.selectedRange
            storage.beginEditing()
            imageViews.forEach { $0.removeFromSuperview() }; imageViews = []
            imageOverlays = []; taskOverlays = []
            var pendingImages: [(UIImage, NSRange, CGSize)] = []
            var pendingTasks: [(marker: NSRange, title: NSRange, checked: Bool, name: String)] = []
            defer {
                storage.endEditing(); lastDisplay = storage.string
                view.selectedRange = NSRange(location: min(selected.location, storage.length), length: min(selected.length, max(0, storage.length - selected.location)))
                for (image, range, size) in pendingImages {
                    let preview = UIImageView(image: image); preview.contentMode = .scaleAspectFit
                    preview.bounds.size = size
                    preview.isUserInteractionEnabled = false; view.addSubview(preview); imageViews.append(preview)
                    imageOverlays.append((preview, range))
                }
                for task in pendingTasks {
                    let button = UIButton(type: .system)
                    button.setImage(UIImage(systemName: task.checked ? "checkmark.square.fill" : "square"), for: .normal)
                    button.tintColor = .systemTeal
                    button.bounds.size = CGSize(width: 25, height: 25)
                    button.accessibilityLabel = task.name
                    button.accessibilityValue = task.checked ? String(localized: "Выполнено") : String(localized: "Не выполнено")
                    button.accessibilityIdentifier = task.checked ? "markdown-task-checked" : "markdown-task-unchecked"
                    button.addAction(UIAction { [weak view] _ in
                        guard let view, let a = view.position(from: view.beginningOfDocument, offset: task.marker.location),
                              let b = view.position(from: a, offset: 1), let target = view.textRange(from: a, to: b) else { return }
                        view.replace(target, withText: task.checked ? " " : "x")
                    }, for: .touchUpInside)
                    view.addSubview(button); imageViews.append(button)
                    taskOverlays.append((button, task.title))
                }
                view.setNeedsLayout()
                layoutOverlays(in: view)
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
                hide(NSRange(location: match.range.location, length: match.range(at: 1).location - match.range.location), force: true)
                hide(NSRange(location: NSMaxRange(match.range(at: 1)), length: NSMaxRange(match.range) - NSMaxRange(match.range(at: 1))), force: true)
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

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = scrollView as? UITextView else { return }
            layoutOverlays(in: view)
        }

        private func layoutOverlays(in view: UITextView) {
            guard !styling, view.bounds.width > 0 else { return }

            for overlay in imageOverlays {
                guard let frame = textRect(for: overlay.range, in: view) else { continue }
                overlay.view.frame.origin = CGPoint(x: view.textContainerInset.left + 5, y: frame.minY)
            }

            for overlay in taskOverlays {
                // Markdown syntax is invisible in Live Preview, so use the visible title's final
                // TextKit rect. This runs after SwiftUI assigns the view its real size and on reflow.
                guard let titleRect = textRect(for: overlay.title, in: view) else { continue }
                overlay.button.frame.origin = CGPoint(x: titleRect.minX - 29, y: titleRect.midY - overlay.button.bounds.height / 2)
            }
        }

        private func textRect(for range: NSRange, in view: UITextView) -> CGRect? {
            guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: max(1, range.length)),
                  let textRange = view.textRange(from: start, to: end) else { return nil }
            return view.firstRect(for: textRange)
        }
    }
}
