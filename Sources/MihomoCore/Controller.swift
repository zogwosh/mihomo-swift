import Foundation

public protocol ControllerAPI: Sendable {
    var port: Int { get }
    func confirm(network: NetworkMode, proxy: ProxyMode) async throws
    func version() async throws -> String
    func configuration() async throws -> [String: Any]
    func groups() async throws -> [ProxyGroup]
    func reload(path: String) async throws
    func setMode(_ mode: ProxyMode) async throws
    func select(group: String, member: String) async throws
    func clearSelection(group: String) async throws
    func delay(node: String) async throws -> Int
}
public final class Controller: ControllerAPI, @unchecked Sendable {
    public let port: Int
    private let baseURL: URL
    private let secret: String
    private let session: URLSession
    public init(port: Int = Limits.controllerPort, secret: String, session: URLSession? = nil) {
        self.port = port; self.baseURL = URL(string: "http://127.0.0.1:\(port)")!; self.secret = secret
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.timeoutIntervalForRequest = Limits.apiTimeout; config.timeoutIntervalForResource = 15
        self.session = session ?? URLSession(configuration: config)
    }
    private func request(_ parts: [String], method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        components.percentEncodedPath = "/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
         if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!); req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 504 { throw ClientError.timeout }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ClientError.message("内核未接受请求，请重试。") }
        if data.isEmpty { return [:] }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.message("内核返回了无法识别的结果。") }
        return result
    }
    public func version() async throws -> String {
        guard let version = try await request(["version"])["version"] as? String else { throw ClientError.message("无法确认内核版本。") }; return version
    }
    public func configuration() async throws -> [String: Any] { try await request(["configs"]) }
    public func groups() async throws -> [ProxyGroup] {
        let doc = try await request(["proxies"])
        let proxies = doc["proxies"] as? [String: [String: Any]] ?? [:]
        return proxies.compactMap { name, p in
            guard let members = p["all"] as? [String], let type = p["type"] as? String, p["hidden"] as? Bool != true else { return nil }
            return ProxyGroup(name: name, type: type, members: members, selected: p["now"] as? String, fixed: p["fixed"] as? String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func reload(path: String) async throws { _ = try await request(["configs"], method: "PUT", query: [.init(name: "force", value: "true")], body: ["path": path]) }
    public func setMode(_ mode: ProxyMode) async throws { _ = try await request(["configs"], method: "PATCH", body: ["mode": mode.rawValue]) }
    public func select(group: String, member: String) async throws { _ = try await request(["proxies", group], method: "PUT", body: ["name": member]) }
    public func clearSelection(group: String) async throws { _ = try await request(["proxies", group], method: "DELETE") }
    public func delay(node: String) async throws -> Int {
        let result = try await request(["proxies", node, "delay"], query: [.init(name: "url", value: Limits.delayURL), .init(name: "timeout", value: String(Limits.delayTimeout))])
        guard let n = result["delay"] as? Int, n > 0 else { throw ClientError.message("延迟测试失败。") }; return n
    }
    public func confirm(network: NetworkMode, proxy: ProxyMode) async throws {
        let config = try await configuration()
        guard (config["mode"] as? String)?.lowercased() == proxy.rawValue,
              (config["tun"] as? [String: Any])?["enable"] as? Bool == (network == .tun) else { throw ClientError.message("内核回读状态与请求不一致。") }
        if network == .systemProxy { guard config["mixed-port"] as? Int == Limits.proxyPort else { throw ClientError.message("本地代理端口未就绪。") } }
    }
}
