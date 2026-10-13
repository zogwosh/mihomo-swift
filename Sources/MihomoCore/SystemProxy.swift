import Foundation
import SystemConfiguration

// Operates in the privileged helper only. Entire original dictionaries preserve PAC, exclusions and per-protocol values.
public final class SystemProxy {
    private let journal: URL
    public init(journal: URL) { self.journal = journal }
    private func preferences() throws -> SCPreferences {
        guard let p = SCPreferencesCreate(nil, "MihomoSwift" as CFString, nil) else { throw ClientError.message("无法读取系统网络设置。") }; return p
    }
    private func saved() throws -> [String: [String: Any]] {
        guard FileManager.default.fileExists(atPath: journal.path) else { return [:] }
        return try PropertyListSerialization.propertyList(from: Data(contentsOf: journal), format: nil) as? [String: [String: Any]] ?? [:]
    }
    public func enable(port: Int) throws {
        let p = try preferences()
        guard SCPreferencesLock(p, true) else { throw ClientError.message("网络设置正在被其他程序修改。") }; defer { SCPreferencesUnlock(p) }
        var snapshots = try saved()
        guard let services = SCNetworkServiceCopyAll(p) as? [SCNetworkService] else { throw ClientError.message("没有可管理的网络服务。") }
        var mutations: [(SCNetworkProtocol, [String: Any])] = []
        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies), let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
            let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
            var applied = current
            for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable"] { applied[key] = 1 }
            for key in ["HTTPProxy", "HTTPSProxy", "SOCKSProxy"] { applied[key] = "127.0.0.1" }
            for key in ["HTTPPort", "HTTPSPort", "SOCKSPort"] { applied[key] = port }
            applied["ProxyAutoConfigEnable"] = 0; applied["ProxyAutoDiscoveryEnable"] = 0
            if snapshots[id] == nil { snapshots[id] = ["original": current, "applied": applied, "protocolEnabled": SCNetworkProtocolGetEnabled(proto)] }
            else {
                guard NSDictionary(dictionary: current).isEqual(to: snapshots[id]?["applied"] as? [String: Any] ?? [:]) else { throw ClientError.message("其他程序已修改系统代理，请先切换 Off 再重试。") }
            }
            mutations.append((proto, applied))
        }
        guard !mutations.isEmpty else { throw ClientError.message("没有可管理的网络服务。") }
        // Durable recovery information is written before any system mutation.
        try atomicWrite(PropertyListSerialization.data(fromPropertyList: snapshots, format: .binary, options: 0), to: journal)
        for (proto, applied) in mutations {
            guard SCNetworkProtocolSetConfiguration(proto, applied as CFDictionary), SCNetworkProtocolSetEnabled(proto, true) else { throw ClientError.message("系统代理设置失败，已保留恢复记录。") }
        }
        guard SCPreferencesCommitChanges(p), SCPreferencesApplyChanges(p) else { throw ClientError.message("系统代理应用失败，已保留恢复记录。") }
        let check = try preferences()
        for service in SCNetworkServiceCopyAll(check) as? [SCNetworkService] ?? [] {
            guard let id = SCNetworkServiceGetServiceID(service) as String?, let snapshot = snapshots[id], let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            guard NSDictionary(dictionary: SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]).isEqual(to: snapshot["applied"] as? [String: Any] ?? [:]), SCNetworkProtocolGetEnabled(proto) else { throw ClientError.message("系统代理回读确认失败。") }
        }
    }
    public func restore() throws {
        var snapshots = try saved(); guard !snapshots.isEmpty else { return }
        let p = try preferences(); guard SCPreferencesLock(p, true) else { throw ClientError.message("网络设置被占用，代理恢复尚未完成。") }; defer { SCPreferencesUnlock(p) }
        var completed: [String] = []
        for service in SCNetworkServiceCopyAll(p) as? [SCNetworkService] ?? [] {
            guard let id = SCNetworkServiceGetServiceID(service) as String?, let snapshot = snapshots[id], let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
            let applied = snapshot["applied"] as? [String: Any] ?? [:]
            let original = snapshot["original"] as? [String: Any] ?? [:]
            // Restore only the values we still own; preserve concurrent third-party edits, including unrelated keys.
            var restored = current
            let managed = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "HTTPProxy", "HTTPSProxy", "SOCKSProxy", "HTTPPort", "HTTPSPort", "SOCKSPort", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
            for key in managed where equal(current[key], applied[key]) { restored[key] = original[key] }
            guard SCNetworkProtocolSetConfiguration(proto, restored as CFDictionary) else { throw ClientError.message("部分网络服务代理尚未恢复。") }
            if NSDictionary(dictionary: current).isEqual(to: applied) && SCNetworkProtocolGetEnabled(proto) { _ = SCNetworkProtocolSetEnabled(proto, snapshot["protocolEnabled"] as? Bool ?? true) }
            completed.append(id)
        }
        guard SCPreferencesCommitChanges(p), SCPreferencesApplyChanges(p) else { throw ClientError.message("代理恢复未完成，将在下次启动继续恢复。") }
        for id in completed { snapshots.removeValue(forKey: id) }
        // Removed services no longer affect the system; keep them in the journal until they reappear.
        if snapshots.isEmpty { try FileManager.default.removeItem(at: journal) }
        else { try atomicWrite(PropertyListSerialization.data(fromPropertyList: snapshots, format: .binary, options: 0), to: journal) }
    }
    private func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if lhs == nil && rhs == nil { return true }
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return false }; return lhs.isEqual(rhs)
    }
}
