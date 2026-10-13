import Foundation

public enum NetworkMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case tun, systemProxy, off
    public var id: String { rawValue }
    public var title: String { switch self { case .tun: "TUN"; case .systemProxy: "系统代理"; case .off: "Off" } }
}
public enum ProxyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case rule, global, direct
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sourceURL: URL?
    public var rawFile: String
    public var resourceDirectory: String
    public var updatedAt: Date
    public var selections: [String: String] = [:]
    public init(id: UUID = UUID(), name: String, sourceURL: URL? = nil, rawFile: String, resourceDirectory: String = "", updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.sourceURL = sourceURL; self.rawFile = rawFile; self.resourceDirectory = resourceDirectory; self.updatedAt = updatedAt
    }
}
public struct AppState: Codable, Equatable, Sendable {
    public var schema = 1
    public var profiles: [Profile] = []
    public var activeProfileID: UUID?
    public var networkMode: NetworkMode = .off
    public var proxyMode: ProxyMode = .rule
    public var loginAtStartup = false
    public var runtimeFile: String?
    public var kernelFile: String?
    public var kernelVersion: String?
    public var revision: UUID = UUID()
    public init() {}
    public var activeProfile: Profile? { profiles.first { $0.id == activeProfileID } }
}
public struct ProxyGroup: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let type: String
    public let members: [String]
    public let selected: String?
    public let fixed: String?
    public var canSelect: Bool { ["Selector", "URLTest", "Fallback"].contains(type) }
    public init(name: String, type: String, members: [String], selected: String?, fixed: String? = nil) {
        self.name = name; self.type = type; self.members = members; self.selected = selected; self.fixed = fixed
    }
}
public enum Latency: Equatable, Sendable {
    case testing, value(Int), timeout, failed
    public var milliseconds: Int? { if case .value(let n) = self { n } else { nil } }
    public var title: String { switch self { case .testing: "测试中"; case .value(let n): "\(n) ms"; case .timeout: "超时"; case .failed: "失败" } }
    public static func sorted(_ members: [String], values: [String: Latency]) -> [String] {
        members.enumerated().sorted {
            let l = values[$0.element]?.milliseconds ?? Int.max, r = values[$1.element]?.milliseconds ?? Int.max
            return l == r ? $0.offset < $1.offset : l < r
        }.map(\.element)
    }
}
public enum ClientError: LocalizedError {
    case message(String)
    case timeout
    public var errorDescription: String? { switch self { case .message(let text): text; case .timeout: "操作超时，请重试。" } }
}
public enum Limits {
    public static let controllerPort = 19090
    public static let proxyPort = 17890
    public static let apiTimeout: TimeInterval = 10
    public static let delayTimeout = 5000
    public static let delayConcurrency = 4
    public static let delayURL = "https://www.gstatic.com/generate_204"
    public static let maxProfileBytes = 20 * 1024 * 1024
}
