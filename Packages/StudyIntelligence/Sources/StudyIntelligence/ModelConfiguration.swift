import CryptoKit
import Foundation

public struct ModelConfiguration: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable { case local, network, codex, sloppy }
    public var provider: Provider = .local
    public var localID = "mlx-community/SmolVLM-256M-Instruct-4bit"
    public var endpoint = "https://api.openai.com/v1"
    public var remoteID = ""
    public var codexModel = ""
    public var sloppyEndpoint = ""
    public var sloppyModel = ""
    public var supportsImages = true
    public var supportsTools = false
    public init() {}

    public var credentialAccount: String {
        let url = provider == .sloppy ? sloppyEndpoint : endpoint
        let normalized = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(provider == .sloppy ? "sloppy" : "network")-\(hash)"
    }

    enum CodingKeys: String, CodingKey {
        case provider, localID, endpoint, remoteID, codexModel, sloppyEndpoint, sloppyModel, supportsImages, supportsTools
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .local
        localID = try c.decodeIfPresent(String.self, forKey: .localID) ?? localID
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? endpoint
        remoteID = try c.decodeIfPresent(String.self, forKey: .remoteID) ?? remoteID
        codexModel = try c.decodeIfPresent(String.self, forKey: .codexModel) ?? codexModel
        sloppyEndpoint = try c.decodeIfPresent(String.self, forKey: .sloppyEndpoint) ?? sloppyEndpoint
        sloppyModel = try c.decodeIfPresent(String.self, forKey: .sloppyModel) ?? sloppyModel
        supportsImages = try c.decodeIfPresent(Bool.self, forKey: .supportsImages) ?? supportsImages
        supportsTools = try c.decodeIfPresent(Bool.self, forKey: .supportsTools) ?? supportsTools
    }
}
