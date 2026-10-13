import Foundation

@MainActor public final class Engine {
    public private(set) var state: AppState
    public private(set) var groups: [ProxyGroup] = []
    public private(set) var running = false
    public private(set) var warning: String?
    public let store: StateStore
    public let controller: any ControllerAPI
    private var runtime: KernelRuntime
    private let bundledKernel: URL
    public init(store: StateStore, bundledKernel: URL, runtime: KernelRuntime, controller: any ControllerAPI) throws {
        self.store = store; self.state = try store.load(); self.bundledKernel = bundledKernel; self.runtime = runtime; self.controller = controller
    }
    public var kernel: URL { get throws { if let file = state.kernelFile { return try store.url(file) }; return bundledKernel } }
    private func resources(_ profile: Profile) throws -> [String: Data] {
        guard !profile.resourceDirectory.isEmpty else { return [:] }
        let root = try store.url(profile.resourceDirectory)
        let paths = Configuration.resourcePaths(try Configuration.parse(store.read(profile.rawFile)))
        var result: [String: Data] = [:]
        for path in paths { result[profile.resourceDirectory.replacingOccurrences(of: "work/", with: "") + "/" + path] = try Data(contentsOf: root.appendingPathComponent(path)) }
        return result
    }
    private func composed(_ profile: Profile, network: NetworkMode, proxy: ProxyMode) throws -> Data {
        try Configuration.compose(raw: store.read(profile.rawFile), network: network, proxy: proxy, secret: store.controllerSecret(), controllerPort: controller.port, resourcePrefix: profile.resourceDirectory.replacingOccurrences(of: "work/", with: "")).data
    }
    private func ready(network: NetworkMode, proxy: ProxyMode) async throws {
        let deadline = Date().addingTimeInterval(15)
        var last: Error = ClientError.message("内核未就绪。")
        repeat {
            do { _ = try await controller.version(); try await controller.confirm(network: network, proxy: proxy); return }
            catch { last = error; try await Task.sleep(for: .milliseconds(150)) }
        } while Date() < deadline
        throw last
    }
    private func restoreSelections(_ profile: Profile) async throws {
        let actual = try await controller.groups()
        // Reset automatic groups' inherited fixed values by full reload + disabled selection cache.
        for group in actual where group.canSelect {
            if let member = profile.selections[group.name], group.members.contains(member) {
                try await controller.select(group: group.name, member: member)
                let after = try await controller.groups()
                guard let read = after.first(where: { $0.name == group.name }), (read.type == "Selector" ? read.selected : read.fixed ?? read.selected) == member else { throw ClientError.message("节点选择恢复回读失败。") }
            }
        }
        groups = try await controller.groups()
        let source = try Configuration.parse(store.read(profile.rawFile))
        for definition in source["proxy-groups"] as? [[String: Any]] ?? [] where definition["hidden"] as? Bool != true {
            guard let name = definition["name"] as? String, let actual = groups.first(where: { $0.name == name }) else { throw ClientError.message("目标 Profile 的代理组未生效。") }
            let expectedMembers = definition["proxies"] as? [String] ?? []
            guard expectedMembers.allSatisfy({ actual.members.contains($0) }) else { throw ClientError.message("目标 Profile 的节点集合回读不一致。") }
        }
    }
    public func restore() async throws {
        // state.json is the only commit point. Any pre-commit work is rolled back by loading this snapshot.
        try await runtime.systemProxy(false)
        guard let profile = state.activeProfile else {
            if state.activeProfileID != nil { throw ClientError.message("上次 Profile 缺失，请重新导入或选择 Profile。") }
            try store.finish(); return
        }
        if state.networkMode != .off && !runtime.usesHelper { throw ClientError.message("已保存的网络模式需要 Helper 授权；当前尚未恢复接管。") }
        let data = try composed(profile, network: state.networkMode, proxy: state.proxyMode)
        try await runtime.validate(kernel: kernel, configuration: data, resources: resources(profile))
        let path = try await runtime.prepare(configuration: data, resources: resources(profile))
        do {
            try await runtime.start(kernel: kernel, configurationPath: path)
            try await ready(network: state.networkMode, proxy: state.proxyMode)
            try await restoreSelections(profile)
            try await runtime.systemProxy(state.networkMode == .systemProxy)
            running = true
            var next = state; next.kernelVersion = try await controller.version(); next.runtimeFile = try store.writeImmutable(data, folder: "runtime", suffix: "yaml"); next.revision = UUID()
            try store.save(next); state = next
            await finalizeCommit()
        } catch {
            try? await runtime.systemProxy(false); try? await runtime.stop(); running = false; throw error
        }
    }
    public func importProfile(raw: Data, name: String, sourceURL: URL? = nil, resourceSource: URL? = nil) async throws {
        let doc = try Configuration.parse(raw)
        let id = UUID(); let directory = "work/resources/\(UUID().uuidString)"
        let target = try store.url(directory); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for path in Configuration.resourcePaths(doc) {
            guard let resourceSource else { throw ClientError.message("配置引用了本地文件资源，订阅导入无法访问该文件。") }
            let root = resourceSource.resolvingSymlinksInPath(); let source = root.appendingPathComponent(path).resolvingSymlinksInPath()
            guard source.path.hasPrefix(root.path + "/") else { throw ClientError.message("本地资源路径超出了配置目录。") }
            let data = try Data(contentsOf: source); guard data.count < 50 * 1024 * 1024 else { throw ClientError.message("配置资源过大。") }
            let destination = target.appendingPathComponent(path); try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true); try atomicWrite(data, to: destination)
        }
        let rawFile = try store.writeImmutable(raw, folder: "profiles", suffix: "yaml")
        let profile = Profile(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名 Profile" : name, sourceURL: sourceURL, rawFile: rawFile, resourceDirectory: directory)
        let data = try composed(profile, network: .off, proxy: state.proxyMode)
        try await runtime.validate(kernel: kernel, configuration: data, resources: resources(profile))
        var next = state; next.profiles.append(profile); next.revision = UUID(); try store.save(next); state = next
    }
    public func activate(_ id: UUID) async throws {
        guard let profile = state.profiles.first(where: { $0.id == id }) else { throw ClientError.message("Profile 不存在。") }
        try await transition(to: profile, network: state.networkMode, proxy: state.proxyMode)
    }
    public func reload(_ id: UUID) async throws {
        guard let profile = state.profiles.first(where: { $0.id == id }) else { throw ClientError.message("Profile 不存在。") }
        if state.activeProfileID == id { try await transition(to: profile, network: state.networkMode, proxy: state.proxyMode) }
        else { try await runtime.validate(kernel: kernel, configuration: composed(profile, network: .off, proxy: state.proxyMode), resources: resources(profile)) }
    }
    public func updateSubscription(_ id: UUID) async throws {
        guard var profile = state.profiles.first(where: { $0.id == id }), let url = profile.sourceURL else { throw ClientError.message("此 Profile 不是订阅。") }
        let raw = try await Subscription.fetch(url); profile.rawFile = try store.writeImmutable(raw, folder: "profiles", suffix: "yaml"); profile.updatedAt = Date()
        if state.activeProfileID == id { try await transition(to: profile, network: state.networkMode, proxy: state.proxyMode) }
        else {
            try await runtime.validate(kernel: kernel, configuration: composed(profile, network: .off, proxy: state.proxyMode), resources: resources(profile))
            var next = state; next.profiles[next.profiles.firstIndex(where: { $0.id == id })!] = profile; next.revision = UUID(); try store.save(next); state = next
        }
    }
    public func setNetwork(_ mode: NetworkMode) async throws {
        guard let profile = state.activeProfile else { throw ClientError.message("请先激活 Profile。") }
        if mode != .off && !runtime.usesHelper { throw ClientError.message("此功能需要 Developer ID 签名与 Helper 授权。当前开发包保持 Off。") }
        try await transition(to: profile, network: mode, proxy: state.proxyMode)
    }
    public func setProxy(_ mode: ProxyMode) async throws {
        guard running else { throw ClientError.message("请先激活 Profile。") }
        let old = state
        try store.begin(old)
        do {
            try await controller.setMode(mode); try await controller.confirm(network: state.networkMode, proxy: mode)
            guard let profile = state.activeProfile else { throw ClientError.message("没有当前 Profile。") }
            let data = try composed(profile, network: state.networkMode, proxy: mode)
            var next = state; next.proxyMode = mode; next.runtimeFile = try store.writeImmutable(data, folder: "runtime", suffix: "yaml"); next.revision = UUID()
            try store.save(next); state = next; try? store.finish()
        } catch {
            do { try await controller.setMode(old.proxyMode); try await controller.confirm(network: old.networkMode, proxy: old.proxyMode); try store.finish() }
            catch { await invalidate(); throw ClientError.message("代理模式切换和恢复均失败，已解除失效接管。请重试恢复。") }
            throw ClientError.message("代理模式切换失败；旧模式仍然生效。")
        }
    }
    private func transition(to profile: Profile, network: NetworkMode, proxy: ProxyMode) async throws {
        let old = state; let wasRunning = running
        let data = try composed(profile, network: network, proxy: proxy)
        try await runtime.validate(kernel: kernel, configuration: data, resources: resources(profile))
        let runtimeFile = try store.writeImmutable(data, folder: "runtime", suffix: "yaml")
        let path = try await runtime.prepare(configuration: data, resources: resources(profile))
        try store.begin(old)
        do {
            if old.networkMode == .systemProxy && network != .systemProxy { try await runtime.systemProxy(false) }
            if wasRunning { try await controller.reload(path: path) }
            else { try await runtime.start(kernel: kernel, configurationPath: path) }
            try await ready(network: network, proxy: proxy)
            try await restoreSelections(profile)
            try await runtime.systemProxy(network == .systemProxy)
            var next = state; next.activeProfileID = profile.id; next.networkMode = network; next.proxyMode = proxy; next.runtimeFile = runtimeFile; next.kernelVersion = try await controller.version(); next.revision = UUID()
            next.profiles[next.profiles.firstIndex(where: { $0.id == profile.id })!] = profile
            try store.save(next); state = next; running = true
            await finalizeCommit()
        } catch {
            do {
                try await runtime.systemProxy(false)
                if wasRunning, let previous = old.activeProfile {
                    let fallback = try composed(previous, network: old.networkMode, proxy: old.proxyMode)
                    let fallbackPath = try await runtime.prepare(configuration: fallback, resources: resources(previous))
                    // A timeout can mean partial success: always reload and verify the committed snapshot.
                    try await controller.reload(path: fallbackPath); try await ready(network: old.networkMode, proxy: old.proxyMode)
                    try await restoreSelections(previous); try await runtime.systemProxy(old.networkMode == .systemProxy); running = true
                } else { try await runtime.stop(); running = false; groups = [] }
                try store.finish()
            } catch { await invalidate(); throw ClientError.message("配置切换失败，旧配置恢复也失败；已解除失效接管。请手动重试恢复。") }
            throw ClientError.message(wasRunning ? "配置切换失败；原 Profile 与模式继续生效，可重试。" : "配置加载失败；当前未接管网络，可重试。")
        }
    }
    public func choose(group: String, member: String) async throws {
        guard running, let activeID = state.activeProfileID, let actual = groups.first(where: { $0.name == group }), actual.canSelect, actual.members.contains(member) else { throw ClientError.message("此组不支持选择或节点已不存在。") }
        let oldMember = actual.fixed ?? actual.selected
        try store.begin(state)
        do {
            try await controller.select(group: group, member: member)
            let current = try await controller.groups()
            guard let read = current.first(where: { $0.name == group }), (read.type == "Selector" ? read.selected : read.fixed ?? read.selected) == member else { throw ClientError.message("节点选择未生效。") }
            var next = state; next.profiles[next.profiles.firstIndex(where: { $0.id == activeID })!].selections[group] = member; next.revision = UUID()
            try store.save(next); state = next; groups = current; try? store.finish()
        } catch {
            do {
                if actual.type != "Selector" && actual.fixed == nil { try await controller.clearSelection(group: group) }
                else if let oldMember { try await controller.select(group: group, member: oldMember) }
                groups = try await controller.groups()
                guard let restored = groups.first(where: { $0.name == group }), (actual.type == "Selector" ? restored.selected == actual.selected : restored.fixed == actual.fixed) else { throw ClientError.message("选择恢复失败。") }
                try store.finish()
            } catch { await invalidate(); throw ClientError.message("节点选择与恢复均失败，已解除接管；请重试恢复。") }
            throw ClientError.message("节点选择未完成；已恢复原选择，可重试。")
        }
    }
    public func setLogin(_ enabled: Bool) throws { var next = state; next.loginAtStartup = enabled; next.revision = UUID(); try store.save(next); state = next }
    public func refresh() async throws { guard running else { return }; try await controller.confirm(network: state.networkMode, proxy: state.proxyMode); groups = try await controller.groups() }
    public func shutdown() async throws { try await runtime.systemProxy(false); try await runtime.stop(); running = false; groups = [] }
    private func invalidate() async { try? await runtime.systemProxy(false); try? await runtime.stop(); running = false; groups = [] }
    private func finalizeCommit() async {
        do {
            if running { try await runtime.finalize(kernel: kernel) }
            try store.finish(); try store.garbageCollect(state); warning = nil
        } catch { warning = "新状态已生效，事务清理尚未完成；下次恢复时重试。" }
    }
    public func install(_ release: KernelRelease) async throws {
        let candidate = try await KernelUpdates.download(release, store: store)
        let candidateURL = try store.url(candidate)
        let version = try await ProcessRunner.run(candidateURL, arguments: ["-v"])
        guard version.status == 0, String(data: version.output, encoding: .utf8)?.contains(release.version) == true else { throw ClientError.message("候选内核版本不匹配；旧内核继续运行。") }
        let old = state; let wasRunning = running; let previousKernel = try kernel
        if let profile = state.activeProfile { try await runtime.validate(kernel: candidateURL, configuration: composed(profile, network: state.networkMode, proxy: state.proxyMode), resources: resources(profile)) }
        try store.begin(old)
        do {
            if wasRunning, let profile = state.activeProfile {
                try await runtime.systemProxy(false); try await runtime.stop(); running = false
                let path = try await runtime.prepare(configuration: composed(profile, network: old.networkMode, proxy: old.proxyMode), resources: resources(profile))
                try await runtime.start(kernel: candidateURL, configurationPath: path); try await ready(network: old.networkMode, proxy: old.proxyMode); try await restoreSelections(profile)
                guard try await controller.version() == release.version else { throw ClientError.message("更新后的内核版本回读不匹配。") }
                // Continuous confirmation across a three-second observation window.
                for _ in 0..<6 { try await Task.sleep(for: .milliseconds(500)); try await controller.confirm(network: old.networkMode, proxy: old.proxyMode) }
                try await runtime.systemProxy(old.networkMode == .systemProxy); running = true
            }
            var next = old; next.kernelFile = candidate; next.kernelVersion = release.version; next.revision = UUID(); try store.save(next); state = next
            await finalizeCommit()
        } catch {
            do {
                try await runtime.systemProxy(false); try await runtime.stop()
                if wasRunning, let profile = old.activeProfile {
                    let path = try await runtime.prepare(configuration: composed(profile, network: old.networkMode, proxy: old.proxyMode), resources: resources(profile))
                    try await runtime.start(kernel: previousKernel, configurationPath: path); try await ready(network: old.networkMode, proxy: old.proxyMode); try await restoreSelections(profile); try await runtime.systemProxy(old.networkMode == .systemProxy); running = true
                }
                try store.finish(); try? store.remove(candidate)
            } catch { await invalidate(); throw ClientError.message("内核更新与自动回滚均失败；已解除失效接管，请重试恢复。") }
            throw ClientError.message("内核更新失败，已自动恢复旧内核与原状态。")
        }
    }
}
