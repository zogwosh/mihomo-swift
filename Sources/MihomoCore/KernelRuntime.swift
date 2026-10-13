import Foundation
import HelperIPC
import ServiceManagement

public protocol KernelRuntime: AnyObject {
    var usesHelper: Bool { get }
    func prepare(configuration: Data, resources: [String: Data]) async throws -> String
    func validate(kernel: URL, configuration: Data, resources: [String: Data]) async throws
    func start(kernel: URL, configurationPath: String) async throws
    func systemProxy(_ enabled: Bool) async throws
    func stop() async throws
    func finalize(kernel: URL) async throws
}
public extension KernelRuntime { func finalize(kernel: URL) async throws {} }
public final class LocalRuntime: KernelRuntime {
    public let usesHelper = false
    private let store: StateStore
    private let supervisor: URL
    private var process: Process?
    public init(store: StateStore, supervisor: URL) { self.store = store; self.supervisor = supervisor }
    public func prepare(configuration: Data, resources: [String: Data]) async throws -> String {
        for (path, data) in resources {
            let url = store.root.appendingPathComponent("work").appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try atomicWrite(data, to: url)
        }
        let file = try store.writeImmutable(configuration, folder: "work", suffix: "yaml")
        return try store.url(file).path
    }
    public func validate(kernel: URL, configuration: Data, resources: [String: Data]) async throws {
        let path = try await prepare(configuration: configuration, resources: resources)
        let result = try await ProcessRunner.run(kernel, arguments: ["-t", "-d", store.root.appendingPathComponent("work").path, "-f", path], timeout: 25)
        guard result.status == 0 else { throw ClientError.message("内核配置验证失败；请检查 Profile 与相对路径资源。") }
    }
    public func start(kernel: URL, configurationPath: String) async throws {
        try await stop()
        try await recoverOrphan()
        guard FileManager.default.isExecutableFile(atPath: supervisor.path) else { throw ClientError.message("缺少内核看护组件，请使用完整 App 包。") }
        let p = Process(); p.executableURL = supervisor
        p.arguments = ["--user-supervisor", String(getpid()), kernel.path, store.root.appendingPathComponent("work").path, configurationPath]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); process = p
    }
    private func recoverOrphan() async throws {
        let journal = store.root.appendingPathComponent("work/user-process.plist")
        guard let data = try? Data(contentsOf: journal), let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let pid = record["pid"] as? Int32, let executable = record["executable"] as? String else { return }
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == executable {
            // The per-data-directory instance lock is held by the app; this record can only belong to a prior instance.
            kill(pid, SIGTERM); try await Task.sleep(for: .milliseconds(250))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == executable { kill(pid, SIGKILL) }
        }
        try FileManager.default.removeItem(at: journal)
    }
    public func systemProxy(_ enabled: Bool) async throws {
        if enabled { throw ClientError.message("系统代理需要已签名并获系统批准的 Helper。开发包可在 Off 下使用节点与配置功能。") }
    }
    public func stop() async throws {
        guard let p = process else { return }
        if p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            guard !p.isRunning else { throw ClientError.message("内核看护组件未完成清理；请重试退出。") }
        }
        process = nil
    }
}
private final class ReplyGate<T>: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) { lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.resume(with: result) }
}
public final class HelperRuntime: KernelRuntime {
    public let usesHelper = true
    private let connection: NSXPCConnection
    private var timer: Timer?
    public static var service: SMAppService { .daemon(plistName: HelperIdentity.plist) }
    public init() throws {
        guard let team = HelperIdentity.teamIdentifier() else { throw ClientError.message("当前是未签名开发包；特权功能需要 Developer ID 签名。") }
        guard Self.service.status == .enabled else { throw ClientError.message("Helper 尚未获系统批准，请在设置中修复授权。") }
        connection = NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.setCodeSigningRequirement(HelperIdentity.requirement(identifier: HelperIdentity.service, team: team))
        connection.resume()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, let proxy = self.connection.remoteObjectProxyWithErrorHandler({ _ in }) as? HelperProtocol else { return }; proxy.heartbeat { _ in }
        }
    }
    deinit { timer?.invalidate(); connection.invalidate() }
    private func call<T>(timeout: TimeInterval = 30, _ body: @escaping (HelperProtocol, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ReplyGate(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in gate.finish(.failure(ClientError.message("Helper 连接中断，请检查系统授权。"))) }) as? HelperProtocol else { gate.finish(.failure(ClientError.message("Helper 不可用。"))); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.finish(.failure(ClientError.message("Helper 操作超时，状态需要重新确认。"))) }
            body(proxy) { gate.finish($0) }
        }
    }
    public func prepare(configuration: Data, resources: [String: Data]) async throws -> String {
        let encoded = try JSONEncoder().encode(resources)
        return try await call { proxy, reply in proxy.prepare(configuration, resources: encoded) { path, error in
            if let path { reply(.success(path)) } else { reply(.failure(ClientError.message(error ?? "配置准备失败。"))) }
        } }
    }
    public func validate(kernel: URL, configuration: Data, resources: [String: Data]) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, data) in resources { let url = root.appendingPathComponent(path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try atomicWrite(data, to: url) }
        let file = root.appendingPathComponent("config.yaml"); try atomicWrite(configuration, to: file)
        let result = try await ProcessRunner.run(kernel, arguments: ["-t", "-d", root.path, "-f", file.path], timeout: 25)
        guard result.status == 0 else { throw ClientError.message("候选配置未通过内核验证。") }
    }
    public func start(kernel: URL, configurationPath: String) async throws {
        let data = try Data(contentsOf: kernel)
        let _: String = try await call(timeout: 180) { proxy, reply in proxy.start(data, expectedHash: sha256(data), configName: configurationPath) { version, error in
            if let version { reply(.success(version)) } else { reply(.failure(ClientError.message(error ?? "内核启动失败。"))) }
        } }
    }
    public func systemProxy(_ enabled: Bool) async throws {
        let _: Bool = try await call { proxy, reply in proxy.setSystemProxy(enabled) { error in if let error { reply(.failure(ClientError.message(error))) } else { reply(.success(true)) } } }
    }
    public func finalize(kernel: URL) async throws {
        let hash = sha256(try Data(contentsOf: kernel))
        let _: Bool = try await call { proxy, reply in proxy.commitKernel(hash) { error in
            if let error { reply(.failure(ClientError.message(error))) } else { reply(.success(true)) }
        } }
    }
    public func stop() async throws {
        let _: Bool = try await call { proxy, reply in proxy.stop { error in if let error { reply(.failure(ClientError.message(error))) } else { reply(.success(true)) } } }
    }
}
