import Foundation
import Darwin

public final class StateStore {
    public let root: URL
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    public init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MihomoSwift", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["profiles", "runtime", "kernels", "work"] { try FileManager.default.createDirectory(at: self.root.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    public func url(_ relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw ClientError.message("数据文件路径无效。") }
        let u = root.appendingPathComponent(relative).standardizedFileURL
        guard u.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ClientError.message("数据文件路径越界。") }
        return u
    }
    public func load() throws -> AppState {
        let file = root.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return AppState() }
        let state = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: file))
        guard state.schema == 1 else { throw ClientError.message("此版本不支持保存的状态格式。") }
        return state
    }
    public func save(_ state: AppState) throws { try atomicWrite(encoder.encode(state), to: root.appendingPathComponent("state.json")) }
    public func begin(_ state: AppState) throws { try atomicWrite(encoder.encode(state), to: root.appendingPathComponent("transaction.json")) }
    public func finish() throws {
        let file = root.appendingPathComponent("transaction.json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    public var hasPendingTransaction: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("transaction.json").path) }
    public func writeImmutable(_ data: Data, folder: String, suffix: String) throws -> String {
        let name = "\(folder)/\(UUID().uuidString).\(suffix)"
        try atomicWrite(data, to: url(name)); return name
    }
    public func read(_ relative: String) throws -> Data { try Data(contentsOf: url(relative)) }
    public func remove(_ relative: String) throws { try FileManager.default.removeItem(at: url(relative)) }
    public func garbageCollect(_ state: AppState) throws {
        guard !hasPendingTransaction else { return }
        let keep = Set(state.profiles.map(\.rawFile) + [state.runtimeFile, state.kernelFile].compactMap { $0 })
        for folder in ["profiles", "runtime", "kernels"] {
            for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: [.isRegularFileKey]) where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                if !keep.contains("\(folder)/\(file.lastPathComponent)") { try FileManager.default.removeItem(at: file) }
            }
        }
    }
    public func controllerSecret() throws -> String {
        let u = root.appendingPathComponent("controller.key")
        if FileManager.default.fileExists(atPath: u.path) { return try String(contentsOf: u, encoding: .utf8) }
        let key = UUID().uuidString + UUID().uuidString
        try atomicWrite(Data(key.utf8), to: u); return key
    }
}
public func atomicWrite(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
    let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temp) }
    try data.write(to: temp, options: .withoutOverwriting)
    guard chmod(temp.path, permissions) == 0 else { throw ClientError.message("无法保护保存文件。") }
    let fd = open(temp.path, O_RDONLY)
    guard fd >= 0 else { throw ClientError.message("无法打开保存文件。") }
    let sync = fsync(fd); close(fd)
    guard sync == 0, rename(temp.path, url.path) == 0 else { throw ClientError.message("无法原子保存状态；旧状态保留。") }
    let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
    if directory >= 0 { _ = fsync(directory); close(directory) }
}
