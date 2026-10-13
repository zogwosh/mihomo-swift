import Foundation
import Darwin
import Security
import MihomoCore
import HelperIPC

func terminate(_ process: Process?) {
    guard let process, process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}
if CommandLine.arguments.contains("--user-supervisor") {
    let args = CommandLine.arguments
    guard args.count == 6, let owner = Int32(args[2]), getuid() != 0 else { exit(64) }
    let core = Process(); core.executableURL = URL(fileURLWithPath: args[3]); core.arguments = ["-d", args[4], "-f", args[5]]
    core.standardOutput = FileHandle.nullDevice; core.standardError = FileHandle.nullDevice
    do { try core.run() } catch { exit(1) }
    let journal = URL(fileURLWithPath: args[4]).appendingPathComponent("user-process.plist")
    let record: [String: Any] = ["pid": core.processIdentifier, "executable": args[3]]
    do { try atomicWrite(PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0), to: journal) }
    catch { terminate(core); exit(1) }
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    signalSource.setEventHandler { terminate(core); try? FileManager.default.removeItem(at: journal); exit(0) }; signalSource.resume()
    let ownerSource = DispatchSource.makeProcessSource(identifier: owner, eventMask: .exit, queue: .main)
    ownerSource.setEventHandler { terminate(core); try? FileManager.default.removeItem(at: journal); exit(0) }; ownerSource.resume()
    let timer = DispatchSource.makeTimerSource(queue: .main); timer.schedule(deadline: .now(), repeating: 1)
    timer.setEventHandler { if !core.isRunning || kill(owner, 0) != 0 { terminate(core); try? FileManager.default.removeItem(at: journal); exit(0) } }; timer.resume()
    dispatchMain()
}

final class HelperSession: NSObject, HelperProtocol, @unchecked Sendable {
    let root: URL
    let proxy: SystemProxy
    let queue = DispatchQueue(label: "MihomoSwift.Helper.transactions")
    var process: Process?
    var lastHeartbeat = Date()
    var connected = true
    private var timer: DispatchSourceTimer?
    private let bundle: URL
    init(uid: uid_t, bundle: URL) throws {
        self.bundle = bundle
        root = URL(fileURLWithPath: "/Library/Application Support/MihomoSwift/\(uid)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for path in [root.deletingLastPathComponent(), root] {
            var st = stat(); guard lstat(path.path, &st) == 0, st.st_uid == 0, (st.st_mode & S_IFMT) == S_IFDIR, (st.st_mode & 0o022) == 0 else { throw ClientError.message("Helper 数据目录权限不安全。") }
        }
        proxy = SystemProxy(journal: root.appendingPathComponent("proxy-recovery.plist"))
        super.init()
        try recover()
        timer = DispatchSource.makeTimerSource(queue: queue); timer?.schedule(deadline: .now() + 3, repeating: 3)
        timer?.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastHeartbeat) > 12 || (self.process != nil && self.process?.isRunning != true) { try? self.cleanup() }
        }; timer?.resume()
    }
    func recover() throws {
        let file = root.appendingPathComponent("process.plist")
        if let data = try? Data(contentsOf: file), let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let pid = record["pid"] as? Int32, let executable = record["executable"] as? String {
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == executable, executable.hasPrefix(root.path + "/kernel-") {
                kill(pid, SIGTERM); Thread.sleep(forTimeInterval: 0.3)
                if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == executable { kill(pid, SIGKILL) }
            }
            try FileManager.default.removeItem(at: file)
        }
        try proxy.restore()
    }
    func cleanup() throws {
        var failure: Error?
        do { try proxy.restore() } catch { failure = error }
        terminate(process); process = nil
        let file = root.appendingPathComponent("process.plist"); if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        if let failure { throw failure }
    }
    func prepare(_ configuration: Data, resources: Data, reply: @escaping (String?, String?) -> Void) {
        queue.async {
            do {
                _ = try Configuration.parse(configuration)
                let files = try JSONDecoder().decode([String: Data].self, from: resources)
                guard files.count <= 1000, files.values.reduce(0, { $0 + $1.count }) <= 100 * 1024 * 1024 else { throw ClientError.message("资源集合过大。") }
                for (path, data) in files {
                    guard path.hasPrefix("resources/"), !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw ClientError.message("资源路径不被允许。") }
                    let file = self.root.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try atomicWrite(data, to: file)
                }
                let file = self.root.appendingPathComponent("config-\(UUID().uuidString).yaml"); try atomicWrite(configuration, to: file)
                reply(file.path, nil)
            } catch { reply(nil, "Helper 无法准备配置，请检查资源与权限。") }
        }
    }
    func start(_ kernel: Data, expectedHash: String, configName: String, reply: @escaping (String?, String?) -> Void) {
        queue.async {
            guard KernelUpdates.isARM64MachO(kernel), sha256(kernel) == expectedHash, expectedHash.count == 64, configName.hasPrefix(self.root.path + "/config-"), !configName.contains("..") else { reply(nil, "内核或配置路径校验失败。"); return }
            Task {
                do {
                    let file = self.root.appendingPathComponent("kernel-\(expectedHash)")
                    if !FileManager.default.fileExists(atPath: file.path) {
                        let bundled = self.bundle.appendingPathComponent("Contents/Resources/mihomo")
                        var code: SecStaticCode?
                        guard SecStaticCodeCreateWithPath(self.bundle as CFURL, [], &code) == errSecSuccess, let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { throw ClientError.message("App 签名无效。") }
                        if sha256(try Data(contentsOf: bundled)) != expectedHash {
                            // Independently fetch the official asset and verify its published compressed digest.
                            // Never trust an arbitrary executable/hash merely because the caller supplied it.
                            let release = try await KernelUpdates.latest()
                            let staging = try StateStore(root: self.root.appendingPathComponent("verification"))
                            let verified = try await KernelUpdates.download(release, store: staging)
                            defer { try? staging.remove(verified) }
                            guard sha256(try staging.read(verified)) == expectedHash else { throw ClientError.message("候选内核来源无法确认。") }
                        }
                        try atomicWrite(kernel, to: file, permissions: 0o700)
                    }
                    guard sha256(try Data(contentsOf: file)) == expectedHash else { throw ClientError.message("受控内核完整性校验失败。") }
                    let validated = try await ProcessRunner.run(file, arguments: ["-t", "-d", self.root.path, "-f", configName], timeout: 25)
                    guard validated.status == 0 else { throw ClientError.message("特权内核配置验证失败。") }
                    self.queue.async {
                        do {
                            guard self.connected else { throw ClientError.message("调用方已退出。") }
                            terminate(self.process)
                            let core = Process(); core.executableURL = file; core.arguments = ["-d", self.root.path, "-f", configName]
                            core.standardOutput = FileHandle.nullDevice; core.standardError = FileHandle.nullDevice
                            try core.run(); self.process = core; self.lastHeartbeat = Date()
                            let record: [String: Any] = ["pid": core.processIdentifier, "executable": file.path]
                            do { try atomicWrite(PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0), to: self.root.appendingPathComponent("process.plist")) }
                            catch { terminate(core); self.process = nil; throw error }
                            reply("started", nil)
                        } catch { reply(nil, "受管理内核启动失败。"); }
                    }
                } catch { reply(nil, "Helper 拒绝启动未经验证的内核或无效配置。") }
            }
        }
    }
    func setSystemProxy(_ enabled: Bool, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                if enabled {
                    guard self.process?.isRunning == true else { throw ClientError.message("内核未就绪。") }
                    try self.proxy.enable(port: Limits.proxyPort)
                } else { try self.proxy.restore() }
                reply(nil)
            } catch { reply("系统代理操作未完成，恢复记录已保留，请重试。") }
        }
    }
    func commitKernel(_ hash: String, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                guard let executable = self.process?.executableURL, self.process?.isRunning == true, executable.lastPathComponent == "kernel-" + hash, sha256(try Data(contentsOf: executable)) == hash else { throw ClientError.message("当前内核未确认。") }
                for file in try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("kernel-") && file != executable { try FileManager.default.removeItem(at: file) }
                reply(nil)
            } catch { reply("更新已生效，但事务旧内核清理尚未完成；下次恢复时重试。") }
        }
    }
    func stop(reply: @escaping (String?) -> Void) { queue.async { do { try self.cleanup(); reply(nil) } catch { reply("代理清理未完成，请重试退出。") } } }
    func heartbeat(reply: @escaping (String?) -> Void) { queue.async { self.lastHeartbeat = Date(); reply(nil) } }
    func disconnected() { queue.async { self.connected = false; try? self.cleanup() } }
}
final class Listener: NSObject, NSXPCListenerDelegate {
    let bundle: URL
    var session: HelperSession?
    weak var owner: NSXPCConnection?
    init(bundle: URL) { self.bundle = bundle }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard getuid() == 0, connection.effectiveUserIdentifier != 0, let team = HelperIdentity.teamIdentifier(), owner == nil else { return false }
        do {
            connection.setCodeSigningRequirement(HelperIdentity.requirement(identifier: HelperIdentity.app, team: team))
            let session = try HelperSession(uid: connection.effectiveUserIdentifier, bundle: bundle)
            self.session = session; owner = connection
            connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self); connection.exportedObject = session
            connection.invalidationHandler = { [weak self, weak session] in session?.disconnected(); DispatchQueue.main.async { self?.owner = nil } }
            connection.interruptionHandler = { [weak session] in session?.disconnected() }
            connection.resume(); return true
        } catch { return false }
    }
}
// The helper refuses ad-hoc signing for privileged operation. No developer backdoor is compiled in.
guard getuid() == 0, HelperIdentity.teamIdentifier() != nil else { exit(77) }
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
// Eager recovery on launchd restart also works before the app reconnects.
let recoveryRoot = URL(fileURLWithPath: "/Library/Application Support/MihomoSwift")
if let directories = try? FileManager.default.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil) {
    for directory in directories {
        if let uid = UInt32(directory.lastPathComponent) { if let recovery = try? HelperSession(uid: uid, bundle: bundle) { try? recovery.cleanup() } }
    }
}
let listener = NSXPCListener(machServiceName: HelperIdentity.service)
let delegate = Listener(bundle: bundle); listener.delegate = delegate; listener.resume(); RunLoop.main.run()
