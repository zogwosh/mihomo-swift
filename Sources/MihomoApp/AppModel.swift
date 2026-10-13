import SwiftUI
import ServiceManagement
import MihomoCore
import HelperIPC
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    @Published var state = AppState()
    @Published var groups: [ProxyGroup] = []
    @Published var running = false
    @Published var busy = false
    @Published var operation = ""
    @Published var error: String?
    @Published var notice: String?
    @Published var latency: [String: Latency] = [:]
    @Published var testing = false
    @Published var loginEnabled = false
    @Published var kernelVersion = "未读取"
    @Published var release: KernelRelease?
    @Published var helperStatus = "未授权"
    private var engine: Engine?
    private var instanceLock: InstanceLock?
    private var latencyGeneration = UUID()
    private var monitor: Timer?
    private var testTask: Task<Void, Never>?
    func boot() async {
        busy = true; operation = "恢复上次状态"
        defer { sync(); busy = false }
        do {
            let store = try StateStore(); instanceLock = try InstanceLock(root: store.root)
            let bundle = Bundle.main.bundleURL
            let kernel = bundle.appendingPathComponent("Contents/Resources/mihomo")
            let helper = bundle.appendingPathComponent("Contents/Library/HelperTools/MihomoHelper")
            let runtime: KernelRuntime
            if HelperRuntime.service.status == .enabled, HelperIdentity.teamIdentifier() != nil { runtime = try HelperRuntime() }
            else { runtime = LocalRuntime(store: store, supervisor: helper) }
            engine = try Engine(store: store, bundledKernel: kernel, runtime: runtime, controller: Controller(secret: store.controllerSecret()))
            let result = try await ProcessRunner.run(try engine!.kernel, arguments: ["-v"])
            if let text = String(data: result.output, encoding: .utf8) { kernelVersion = text.split(separator: " ").first(where: { $0.hasPrefix("v") }).map(String.init) ?? "未知" }
            try await engine?.restore()
        } catch { show(error) }
        refreshRegistration()
        monitor = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy, self.running else { return }
                do { try await self.engine?.refresh(); self.sync(); self.refreshRegistration() }
                catch { self.busy = true; try? await self.engine?.shutdown(); self.sync(); self.busy = false; self.error = "内核或 Helper 连接异常；已尝试解除接管。请重试恢复。" }
            }
        }
    }
    private func sync() {
        if let engine { state = engine.state; groups = engine.groups; running = engine.running; kernelVersion = engine.state.kernelVersion ?? kernelVersion; if let warning = engine.warning { notice = warning } }
    }
    private func show(_ failure: Error) {
        // Only app-authored messages reach the UI. Foundation/network/core diagnostics can contain credentials.
        error = (failure as? ClientError)?.errorDescription ?? "操作未完成，请检查文件、网络或权限后重试。"
    }
    func perform(_ title: String, _ action: @escaping (Engine) async throws -> Void) {
        guard !busy, let engine else { return }
        busy = true; operation = title; error = nil; notice = nil
        cancelTests()
        Task {
            defer { sync(); busy = false }
            do { try await action(engine) } catch { show(error) }
        }
    }
    func activate(_ id: UUID) { perform("切换 Profile") { try await $0.activate(id) } }
    func network(_ mode: NetworkMode) { perform("切换网络模式") { try await $0.setNetwork(mode) } }
    func proxy(_ mode: ProxyMode) { perform("切换代理模式") { try await $0.setProxy(mode) } }
    func reload(_ id: UUID) { perform("重新加载") { try await $0.reload(id) } }
    func update(_ id: UUID) { perform("更新订阅") { try await $0.updateSubscription(id) } }
    func choose(group: String, member: String) { perform("选择节点") { try await $0.choose(group: group, member: member) } }
    func retry() { perform("恢复状态") { try await $0.restore() } }
    func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .data, UTType(filenameExtension: "yml") ?? .data]; panel.allowsMultipleSelection = false
        panel.message = "导入后保存副本；重新加载读取应用内副本。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("导入本地配置") { engine in
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            try await engine.importProfile(raw: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent, resourceSource: url.deletingLastPathComponent())
        }
    }
    func importSubscription(name: String, address: String) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { error = "订阅地址格式无效。"; return }
        perform("下载并验证订阅") { try await $0.importProfile(raw: Subscription.fetch(url), name: name, sourceURL: url) }
    }
    private func cancelTests() { testTask?.cancel(); testTask = nil; latencyGeneration = UUID(); testing = false; latency = [:] }
    func test(_ nodes: [String]) {
        guard !busy, !testing, running, let engine else { return }
        testing = true; let generation = latencyGeneration; let profileID = state.activeProfileID; let controller = engine.controller
        let unique = Array(NSOrderedSet(array: nodes)) as? [String] ?? []
        testTask = Task {
            defer { if latencyGeneration == generation { testing = false } }
            await withTaskGroup(of: (String, Latency).self) { group in
                var next = 0
                @MainActor func enqueue(_ node: String) {
                    latency[node] = .testing
                    group.addTask {
                        do { return (node, .value(try await controller.delay(node: node))) }
                        catch { if (error as? URLError)?.code == .timedOut || (error as? ClientError).map({ if case .timeout = $0 { return true }; return false }) == true { return (node, .timeout) }; return (node, .failed) }
                    }
                }
                while next < min(Limits.delayConcurrency, unique.count) { enqueue(unique[next]); next += 1 }
                for await (node, value) in group {
                    guard !Task.isCancelled, generation == latencyGeneration, profileID == state.activeProfileID else { group.cancelAll(); break }
                    latency[node] = value
                    if next < unique.count { enqueue(unique[next]); next += 1 }
                }
            }
        }
    }
    func refreshRegistration() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        switch HelperRuntime.service.status { case .enabled: helperStatus = "已授权"; case .requiresApproval: helperStatus = "等待系统批准"; case .notRegistered: helperStatus = "未注册"; default: helperStatus = "不可用" }
    }
    func setLogin(_ enabled: Bool) {
        perform("设置登录自启") { engine in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
                self.refreshRegistration(); try engine.setLogin(self.loginEnabled)
                if enabled && !self.loginEnabled { throw ClientError.message("登录自启等待系统批准，请检查系统设置。") }
            } catch { self.refreshRegistration(); throw error }
        }
    }
    func authorizeHelper() {
        guard !busy else { return }
        guard HelperIdentity.teamIdentifier() != nil else { error = "当前开发包未使用 Developer ID 签名，无法注册特权 Helper。Off 模式可用于配置、节点和延迟测试。"; return }
        do {
            if HelperRuntime.service.status != .enabled { try HelperRuntime.service.register() }
            refreshRegistration()
            if HelperRuntime.service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            notice = "批准 Helper 后重新启动应用，即可使用 TUN 与系统代理。"
        } catch { show(error) }
    }
    func checkUpdate() { perform("检查官方内核更新") { _ in self.release = try await KernelUpdates.latest(); self.notice = self.release?.version == self.kernelVersion ? "当前内核已是最新版本。" : "已找到更新，请确认后安装。" } }
    func installUpdate() { guard let release else { return }; perform("安装内核更新") { try await $0.install(release); self.release = nil; self.notice = "内核更新已完成。" } }
    func quit(completion: @escaping (Bool) -> Void) {
        guard !busy else { completion(false); return }
        busy = true; operation = "停止内核并恢复代理"; cancelTests(); monitor?.invalidate()
        Task {
            do { try await engine?.shutdown(); completion(true) }
            catch { show(error); busy = false; sync(); completion(false) }
        }
    }
}
