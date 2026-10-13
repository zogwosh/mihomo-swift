import Foundation
import Yams

public struct ComposedConfiguration {
    public let data: Data
    public let document: [String: Any]
}
public enum Configuration {
    public static let whitelist: Set<String> = ["mode", "tun.enable", "external-controller", "external-controller-tls", "external-controller-unix", "external-controller-pipe", "secret", "mixed-port", "allow-lan", "bind-address", "profile.store-selected", "proxy-providers.*.path", "rule-providers.*.path"]
    public static func parse(_ raw: Data) throws -> [String: Any] {
        guard !raw.isEmpty, raw.count <= Limits.maxProfileBytes, let text = String(data: raw, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { throw ClientError.message("配置为空、过大或不是 UTF-8 YAML。") }
        let docs: [Any]
        do {
            var sequence = try Yams.load_all(yaml: text)
            var values: [Any] = []
            while let value = sequence.next() { values.append(value) }
            if let error = sequence.error { throw error }; docs = values
        } catch { throw ClientError.message("YAML 解析失败，请检查配置格式。") }
        guard docs.count == 1, let doc = docs.first as? [String: Any], !doc.isEmpty,
              doc["proxies"] != nil || doc["proxy-providers"] != nil || doc["rules"] != nil || doc["proxy-groups"] != nil else { throw ClientError.message("响应不是有效的 Mihomo 配置。") }
        if let tun = doc["tun"], !(tun is [String: Any]) { throw ClientError.message("tun 必须是配置对象。") }
        if let p = doc["profile"], !(p is [String: Any]) { throw ClientError.message("profile 必须是配置对象。") }
        if (doc["listeners"] as? [[String: Any]] ?? []).contains(where: { ($0["type"] as? String)?.lowercased() == "tun" }) {
            throw ClientError.message("Profile 使用独立 TUN listener，与互斥网络模式不兼容；请使用顶层 tun 配置。")
        }
        // Additional controller listeners must not bypass the app's local authenticated endpoint.
        if let ui = doc["external-ui"] as? String, !ui.isEmpty {
            guard !ui.hasPrefix("/"), !ui.hasPrefix("~"), !ui.split(separator: "/").contains("..") else { throw ClientError.message("Profile 的控制页面资源路径越界。") }
        }
        try validateResourcePaths(doc)
        return doc
    }
    public static func compose(raw: Data, network: NetworkMode, proxy: ProxyMode, secret: String, controllerPort: Int = Limits.controllerPort, proxyPort: Int = Limits.proxyPort, resourcePrefix: String = "") throws -> ComposedConfiguration {
        var doc = try parse(raw)
        doc["mode"] = proxy.rawValue
        var tun = doc["tun"] as? [String: Any] ?? [:]; tun["enable"] = network == .tun; doc["tun"] = tun
        doc["external-controller"] = "127.0.0.1:\(controllerPort)"
        for key in ["external-controller-tls", "external-controller-unix", "external-controller-pipe"] { doc.removeValue(forKey: key) }
        doc["secret"] = secret
        var cache = doc["profile"] as? [String: Any] ?? [:]; cache["store-selected"] = false; doc["profile"] = cache
        if network == .systemProxy { doc["mixed-port"] = proxyPort; doc["allow-lan"] = false; doc["bind-address"] = "127.0.0.1" }
        if !resourcePrefix.isEmpty {
            for key in ["proxy-providers", "rule-providers"] {
                if var providers = doc[key] as? [String: [String: Any]] {
                    for name in Array(providers.keys) {
                        if let path = providers[name]?["path"] as? String { providers[name]?["path"] = resourcePrefix + "/" + path }
                    }
                    doc[key] = providers
                }
            }
        }
        let yaml = try Yams.dump(object: doc, sortKeys: true)
        return ComposedConfiguration(data: Data(yaml.utf8), document: doc)
    }
    public static func resourcePaths(_ document: [String: Any]) -> [String] {
        var result: [String] = []
        for key in ["proxy-providers", "rule-providers"] {
            for provider in (document[key] as? [String: [String: Any]] ?? [:]).values where provider["type"] as? String == "file" {
                if let path = provider["path"] as? String { result.append(path) }
            }
        }
        return Array(Set(result)).sorted()
    }
    public static func validateResourcePaths(_ value: Any) throws {
        if let dictionary = value as? [String: Any] {
            for (key, item) in dictionary {
                if key == "path", let path = item as? String {
                    guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.split(separator: "/").contains(".."), !path.isEmpty, !path.contains("\0") else { throw ClientError.message("配置包含越界资源路径；请使用配置目录内的相对路径。") }
                }
                try validateResourcePaths(item)
            }
        } else if let array = value as? [Any] { for item in array { try validateResourcePaths(item) } }
    }
}
