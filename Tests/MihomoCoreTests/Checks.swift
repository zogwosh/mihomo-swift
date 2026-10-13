import Foundation
import MihomoCore
import Darwin

struct CheckFailure: Error, CustomStringConvertible { let description: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(description: message) }
}
func rejects(_ label: String, _ block: () throws -> Void) throws {
    do { try block() } catch { return }; throw CheckFailure(description: "Expected rejection: \(label)")
}
let yamlA = Data("""
# preserved comment
mode: direct
tun:
  enable: true
  stack: gvisor
  mtu: 9000
dns:
  enable: false
  nameserver: [1.1.1.1]
proxies: []
proxy-groups:
  - name: Route
    type: select
    proxies: [DIRECT, REJECT]
rules: ["MATCH,Route"]
""".utf8)
let yamlB = Data("""
mode: global
tun: {enable: true}
proxies: []
proxy-groups:
  - name: Route
    type: select
    proxies: [DIRECT, REJECT]
rules: ["MATCH,Route"]
""".utf8)
final class FakeController: ControllerAPI, @unchecked Sendable {
    let port = 29090
    var network: NetworkMode = .off
    var mode: ProxyMode = .rule
    var selected = "DIRECT"
    var failNextReload = false
    var failEveryReload = false
    var failNextSelection = false
    var reloadCount = 0
    let store: StateStore
    init(store: StateStore) { self.store = store }
    func version() async throws -> String { "v1.19.32" }
    func configuration() async throws -> [String: Any] { ["mode": mode.rawValue, "tun": ["enable": network == .tun]] }
    func groups() async throws -> [ProxyGroup] { [ProxyGroup(name: "Route", type: "Selector", members: ["DIRECT", "REJECT"], selected: selected)] }
    func reload(path: String) async throws {
        reloadCount += 1
        let parsed = try Configuration.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        mode = ProxyMode(rawValue: parsed["mode"] as! String)!
        network = (parsed["tun"] as? [String: Any])?["enable"] as? Bool == true ? .tun : .off
        selected = "DIRECT"
        if failEveryReload || failNextReload { failNextReload = false; throw ClientError.timeout }
    }
    func setMode(_ mode: ProxyMode) async throws { self.mode = mode }
    func select(group: String, member: String) async throws { selected = member; if failNextSelection { failNextSelection = false; throw ClientError.timeout } }
    func clearSelection(group: String) async throws {}
    func delay(node: String) async throws -> Int { 20 }
    func confirm(network: NetworkMode, proxy: ProxyMode) async throws { try check(network == self.network && proxy == mode, "Controller mode mismatch") }
}
final class FakeRuntime: KernelRuntime {
    let usesHelper = false
    let controller: FakeController
    let root: URL
    var starts = 0
    var stops = 0
    init(controller: FakeController, root: URL) { self.controller = controller; self.root = root }
    func prepare(configuration: Data, resources: [String: Data]) async throws -> String { let u = root.appendingPathComponent(UUID().uuidString + ".yaml"); try atomicWrite(configuration, to: u); return u.path }
    func validate(kernel: URL, configuration: Data, resources: [String: Data]) async throws { _ = try Configuration.parse(configuration) }
    func start(kernel: URL, configurationPath: String) async throws { starts += 1; try await controller.reload(path: configurationPath) }
    func systemProxy(_ enabled: Bool) async throws { try check(!enabled, "Unexpected system takeover") }
    func stop() async throws { stops += 1 }
}
final class CountingRuntime: KernelRuntime {
    let local: LocalRuntime
    let usesHelper = false
    var starts = 0
    var failNextStart = false
    init(_ local: LocalRuntime) { self.local = local }
    func prepare(configuration: Data, resources: [String: Data]) async throws -> String { try await local.prepare(configuration: configuration, resources: resources) }
    func validate(kernel: URL, configuration: Data, resources: [String: Data]) async throws { try await local.validate(kernel: kernel, configuration: configuration, resources: resources) }
    func start(kernel: URL, configurationPath: String) async throws { starts += 1; if failNextStart { failNextStart = false; throw ClientError.message("Injected start failure") }; try await local.start(kernel: kernel, configurationPath: configurationPath) }
    func systemProxy(_ enabled: Bool) async throws { try await local.systemProxy(enabled) }
    func stop() async throws { try await local.stop() }
}
@main struct Checks {
    @MainActor static func main() async {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("MihomoChecks-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try StateStore(root: root)
            let composed = try Configuration.compose(raw: yamlA, network: .off, proxy: .global, secret: "private")
            let original = try Configuration.parse(yamlA)
            try check(composed.document["mode"] as? String == "global", "Global override")
            try check((composed.document["tun"] as? [String: Any])?["enable"] as? Bool == false, "TUN disabled")
            try check((composed.document["tun"] as? [String: Any])?["mtu"] as? Int == 9000, "Preserve TUN MTU")
            try check(NSDictionary(dictionary: composed.document["dns"] as! [String: Any]).isEqual(to: original["dns"] as! [String: Any]), "Preserve DNS semantics")
            try check(yamlA.starts(with: Data("# preserved comment".utf8)), "Original YAML bytes untouched")
            for input in ["", "<html>error</html>", "abc: 1", "proxies: [", "proxies: []\n---\nproxies: []", "proxies: []\ntun: true", "proxies: []\nrule-providers: {bad: {type: file, path: ../secret}}"] {
                try rejects(input) { _ = try Configuration.parse(Data(input.utf8)) }
            }
            let sorted = Latency.sorted(["failed", "same1", "fast", "same2", "untested", "timeout"], values: ["failed": .failed, "same1": .value(150), "fast": .value(5), "same2": .value(150), "timeout": .timeout])
            try check(sorted == ["fast", "same1", "same2", "failed", "untested", "timeout"], "Stable latency sorting")
            try rejects("escaped store path") { _ = try store.url("../bad") }
            let secret = try store.controllerSecret(); try check(secret == store.controllerSecret(), "Stable private secret")
            let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("controller.key").path)[.posixPermissions] as! NSNumber
            try check(permissions.intValue == 0o600, "Private controller key permissions")
            var saved = AppState(); saved.networkMode = .tun; try store.save(saved); try store.begin(saved)
            var committed = saved; committed.networkMode = .off; try store.save(committed)
            try check(try store.load().networkMode == .off, "Commit point wins over stale journal")
            try store.finish(); try store.save(AppState())
            print("PASS: parsing, minimum overrides, privacy, atomic commit and stable sort")
            let controller = FakeController(store: store); let runtime = FakeRuntime(controller: controller, root: root)
            let engine = try Engine(store: store, bundledKernel: URL(fileURLWithPath: "/unused"), runtime: runtime, controller: controller)
            try await engine.importProfile(raw: yamlA, name: "A"); try await engine.importProfile(raw: yamlB, name: "B")
            let a = engine.state.profiles[0], b = engine.state.profiles[1]
            try check(engine.state.activeProfileID == nil, "Import does not auto-activate")
            try await engine.activate(a.id); try await engine.choose(group: "Route", member: "REJECT"); try await engine.setProxy(.global)
            try await engine.activate(b.id)
            try check(controller.selected == "DIRECT", "No same-name selection leak across profiles")
            try await engine.activate(a.id)
            try check(controller.selected == "REJECT", "Profile-specific selection restored")
            try check(engine.state.proxyMode == .global && engine.state.networkMode == .off, "Global modes invariant")
            try check(runtime.starts == 1, "Profile switching never restarts kernel")
            try check(try store.read(a.rawFile) == yamlA, "Raw YAML byte-for-byte preserved")
            controller.failNextSelection = true
            do { try await engine.choose(group: "Route", member: "DIRECT"); throw CheckFailure(description: "Selection should fail") } catch is ClientError {}
            try check(controller.selected == "REJECT" && engine.state.activeProfile?.selections["Route"] == "REJECT", "Uncertain selection compensated")
            controller.failNextReload = true
            do { try await engine.activate(b.id); throw CheckFailure(description: "Reload should fail") } catch is ClientError {}
            try check(engine.running && engine.state.activeProfileID == a.id && controller.selected == "REJECT", "Partial reload restores prior profile and selections")
            try check(try store.load().activeProfileID == a.id, "Failed reload never commits")
            controller.failEveryReload = true
            do { try await engine.activate(b.id); throw CheckFailure(description: "Recovery should fail") } catch is ClientError {}
            try check(!engine.running && engine.state.activeProfileID == a.id && runtime.stops > 0, "Failed recovery releases takeover and preserves intent")
            try check(store.hasPendingTransaction, "Failed recovery keeps journal")
            controller.failEveryReload = false; try await engine.restore()
            try check(engine.running && controller.selected == "REJECT" && !store.hasPendingTransaction, "Startup recovers unfinished transaction")
            try await engine.shutdown(); try check(engine.state.proxyMode == .global && engine.state.networkMode == .off, "Quit does not overwrite preference")
            print("PASS: profile isolation, hot reload, uncertain outcomes, rollback failure and startup recovery")
            if CommandLine.arguments.contains("--real") {
                let realStore = try StateStore(root: root.appendingPathComponent("real"))
                let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/mihomo")
                let supervisor = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("MihomoHelper")
                let realRuntime = CountingRuntime(LocalRuntime(store: realStore, supervisor: supervisor))
                let realController = Controller(port: 29192, secret: try realStore.controllerSecret())
                let real = try Engine(store: realStore, bundledKernel: core, runtime: realRuntime, controller: realController)
                do {
                    try await real.importProfile(raw: yamlA, name: "Real A")
                    try await real.importProfile(raw: yamlB, name: "Real B")
                    let first = real.state.profiles[0], second = real.state.profiles[1]
                    try await real.activate(first.id); try await real.choose(group: "Route", member: "REJECT")
                    try await real.setProxy(.global); try await real.activate(second.id)
                    try check(real.groups.first(where: { $0.name == "Route" })?.selected == "DIRECT", "Real core must not leak selection between same-name groups")
                    try await real.activate(first.id)
                    try check(real.groups.first(where: { $0.name == "Route" })?.selected == "REJECT", "Real profile selection restores")
                    try check(realRuntime.starts == 1, "Real Engine hot reload keeps one process")
                    try check(try realStore.read(first.rawFile) == yamlA, "Real core validation preserves original bytes")
                    try await real.shutdown(); try await real.restore()
                    try check(real.state.proxyMode == .global && real.groups.first(where: { $0.name == "Route" })?.selected == "REJECT", "Real startup restores modes and selection")
                    if CommandLine.arguments.contains("--updates") {
                        let release = KernelRelease(version: "v1.19.32", downloadURL: URL(string: "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-darwin-arm64-v1.19.32.gz")!, digest: "3312a6780652c622890fd4357c6a853bbf865464fd047ac7b7f52dab8de18652")
                        try await real.install(release)
                        let installed = real.state.kernelFile!
                        let startsBeforeFailure = realRuntime.starts
                        let wrong = KernelRelease(version: "v0.invalid", downloadURL: release.downloadURL, digest: release.digest)
                        do { try await real.install(wrong); throw CheckFailure(description: "Wrong version must fail before stopping old core") } catch is ClientError {}
                        try check(realRuntime.starts == startsBeforeFailure && real.running && real.state.kernelFile == installed, "Invalid downloaded candidate preserves running core")
                        realRuntime.failNextStart = true
                        do { try await real.install(release); throw CheckFailure(description: "Injected replacement failure should roll back") } catch is ClientError {}
                        try check(real.running && real.state.kernelFile == installed && real.state.proxyMode == .global && real.groups.first(where: { $0.name == "Route" })?.selected == "REJECT", "Update rollback restores old binary, modes and selections")
                        try check(FileManager.default.fileExists(atPath: realStore.url(installed).path), "Rollback keeps only available old binary")
                        try await real.install(release)
                        try check(!FileManager.default.fileExists(atPath: realStore.url(installed).path), "Successful commit removes previous transaction kernel")
                        print("PASS: real kernel update, invalid candidate without stopping core, failed replacement rollback, selection restoration and old-binary cleanup")
                    }
                    try await real.shutdown()
                    print("PASS: real Engine same-name profile isolation, global mode invariants, API hot reload and startup restoration")
                } catch { try? await real.shutdown(); throw error }
            }
            print("ALL CHECKS PASSED")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
