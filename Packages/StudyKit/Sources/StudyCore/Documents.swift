import Foundation
import CryptoKit

public enum DocumentKind: String, Codable, Sendable, CaseIterable {
    case markdown, notebook, infinity
    public var fileExtension: String { self == .markdown ? "md" : "studycanvas" }
    public var title: String {
        switch self {
        case .markdown: String(localized: "Markdown")
        case .notebook: String(localized: "Тетрадь")
        case .infinity: String(localized: "Бесконечный холст")
        }
    }
    public var symbol: String {
        switch self { case .markdown: "doc.text"; case .notebook: "book.closed"; case .infinity: "infinity" }
    }
}

public enum PaperPattern: String, Codable, CaseIterable, Sendable {
    case plain, dots, lines, grid, japanese
    public var title: String {
        switch self {
        case .plain: String(localized: "Белый")
        case .dots: String(localized: "Точка")
        case .lines: String(localized: "Линия")
        case .grid: String(localized: "Клетка")
        case .japanese: String(localized: "Кана и кандзи")
        }
    }
}

public struct Paper: Codable, Equatable, Sendable {
    public var pattern: PaperPattern = .dots
    public var spacing: Double = 28
    public var background: String = "FFFEFA"
    public var lineColor: String = "C9C7BC"
    public init() {}
}

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 280, height: Double = 160) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func intersects(_ other: Rect) -> Bool {
        x <= other.x + other.width && x + width >= other.x && y <= other.y + other.height && y + height >= other.y
    }
}

public struct CanvasObject: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, text, link }
    public var id: UUID = UUID()
    public var kind: Kind
    public var frame: Rect
    public var content: String
    public init(kind: Kind, frame: Rect = Rect(x: 64, y: 64), content: String) {
        self.kind = kind; self.frame = frame; self.content = content
    }
}

/// An immutable drawing shard. Its bounds cover complete strokes, including boundary crossings.
public struct InkShard: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var file: String
    public var bounds: Rect
    public init(file: String, bounds: Rect) { self.file = file; self.bounds = bounds }
}

public struct CanvasPage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var title: String = String(localized: "Страница")
    public var paper = Paper()
    public var width: Double = 595
    public var height: Double = 842
    public var drawingFile: String?
    public var shards: [InkShard] = []
    public var objects: [CanvasObject] = []
    public init() {}
}

public struct SourceContext: Codable, Equatable, Sendable {
    public var path: String
    public var pageID: UUID?
    public var region: Rect?
    public var text: String?
    public var image: Data?
    public init(path: String, pageID: UUID? = nil, region: Rect? = nil, text: String? = nil, image: Data? = nil) {
        self.path = path; self.pageID = pageID; self.region = region; self.text = text; self.image = image
    }
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: UUID = UUID()
    public var role: Role
    public var text: String
    public var context: SourceContext?
    public var interrupted = false
    public init(role: Role, text: String, context: SourceContext? = nil) {
        self.role = role; self.text = text; self.context = context
    }
}

public struct DocumentContent: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id = UUID()
    public var kind: DocumentKind
    public var markdown = ""
    public var pages: [CanvasPage]
    public var messages: [ChatMessage] = []
    public var appliedProposals: Set<UUID> = []
    public init(kind: DocumentKind) {
        self.kind = kind; self.pages = kind == .markdown ? [] : [CanvasPage()]
    }
    public var contentRevision: String {
        var copy = self; copy.messages = []; copy.appliedProposals = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(copy)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct LoadedDocument: Sendable {
    public var content: DocumentContent
    public var revision: String
    public init(content: DocumentContent, revision: String) { self.content = content; self.revision = revision }
}

public struct VaultEntry: Identifiable, Hashable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var kind: DocumentKind?
    public var id: String { path }
    public var title: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    public var parent: String { (path as NSString).deletingLastPathComponent }
    public init(path: String, isDirectory: Bool, kind: DocumentKind? = nil) {
        self.path = path; self.isDirectory = isDirectory; self.kind = kind
    }
}

public struct ChangeProposal: Codable, Equatable, Identifiable, Sendable {
    public enum Action: String, Codable, Sendable { case createMarkdown, replaceMarkdown, addCard }
    public var id = UUID()
    public var action: Action
    public var path: String
    public var baseRevision: String?
    public var text: String
    public var pageID: UUID?
    public var isLink = false
    public init(action: Action, path: String, baseRevision: String? = nil, text: String, pageID: UUID? = nil, isLink: Bool = false) {
        self.action = action; self.path = path; self.baseRevision = baseRevision; self.text = text; self.pageID = pageID; self.isLink = isLink
    }
}

public enum StudyError: LocalizedError {
    case invalidPath, exists, staleRevision, unsupportedVersion, missingPage, modelUnavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPath: String(localized: "Путь должен находиться внутри выбранного хранилища.")
        case .exists: String(localized: "Файл с таким именем уже существует.")
        case .staleRevision: String(localized: "Документ изменился. Сохранены обе версии; выберите нужную перед продолжением.")
        case .unsupportedVersion: String(localized: "Эта версия документа пока не поддерживается.")
        case .missingPage: String(localized: "Страница больше не существует.")
        case .modelUnavailable(let reason): reason
        }
    }
}
