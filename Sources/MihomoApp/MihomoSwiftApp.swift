import SwiftUI
import MihomoCore
import UniformTypeIdentifiers

// Explicit alias keeps the property-wrapper API compatible with command-line SDKs
// that ship SwiftUI headers without the new State macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.quit { sender.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true })?.makeKeyAndOrderFront(nil) }; return true
    }
}
@main struct MihomoSwiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Mihomo", id: "main") {
            MainView().environmentObject(model)
                .task { delegate.model = model; if !model.busy && model.kernelVersion == "未读取" { await model.boot() } }
        }
        .defaultSize(width: 980, height: 680)
        .commands { CommandGroup(replacing: .newItem) { Button("导入 YAML…") { model.importFile() }.keyboardShortcut("o").disabled(model.busy) } }
        MenuBarExtra { TrayView().environmentObject(model) } label: { Image(systemName: model.running ? "network" : "network.slash") }
    }
}
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var selection: UUID?
    @ViewState private var settings = false
    @ViewState private var subscription = false
    @ViewState private var groupName: String?
    @ViewState private var sortByLatency = false
    private var profile: Profile? { model.state.profiles.first { $0.id == selection } ?? model.state.activeProfile }
    private var group: ProxyGroup? { model.groups.first { $0.name == groupName } ?? model.groups.first }
    private var visibleNodes: [String] { let nodes = group?.members ?? []; return sortByLatency ? Latency.sorted(nodes, values: model.latency) : nodes }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "network").font(.title2).foregroundStyle(.teal).frame(width: 36, height: 36).background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) { Text("Mihomo").font(.headline); Text("轻一点，连接更简单").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }.padding(20)
                HStack { Text("PROFILES").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Menu { Button("本地 YAML…", action: model.importFile); Button("订阅 URL…") { subscription = true } } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy) }.padding(.horizontal, 20).padding(.bottom, 8)
                List(selection: $selection) {
                    ForEach(model.state.profiles) { p in
                        HStack(spacing: 10) {
                            Image(systemName: p.sourceURL == nil ? "doc.text" : "link").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) { Text(p.name).lineLimit(1); Text(p.sourceURL == nil ? "本地配置" : "订阅配置").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if p.id == model.state.activeProfileID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal).help("当前 Profile") }
                        }.padding(.vertical, 5).tag(p.id)
                    }
                }.listStyle(.sidebar)
                Divider()
                Button { settings = true } label: { HStack { Image(systemName: "gearshape"); Text("设置"); Spacer(); Text(model.kernelVersion).font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain).padding(20)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                statusHeader
                if let error = model.error { message(error, symbol: "exclamationmark.triangle", color: .orange) }
                if let notice = model.notice { message(notice, symbol: "info.circle", color: .teal) }
                if model.state.profiles.isEmpty { emptyState }
                else {
                    profileHeader
                    modes
                    Divider().padding(.horizontal, 24)
                    if model.running && profile?.id == model.state.activeProfileID { nodesView }
                    else if model.running { ContentUnavailableView("尚未激活此 Profile", systemImage: "doc.text", description: Text("点击激活后查看该配置的节点。当前运行配置继续生效。")) }
                    else { ContentUnavailableView { Label("内核尚未运行", systemImage: "pause.circle") } description: { Text("激活一个 Profile，或重试恢复上次状态。") } actions: { Button("重试恢复", action: model.retry).disabled(model.busy) } }
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: $subscription) { SubscriptionView().environmentObject(model) }
        .sheet(isPresented: $settings) { SettingsView().environmentObject(model) }
        .onChange(of: model.state.activeProfileID) { _, id in selection = id; groupName = nil }
    }
    private var statusHeader: some View {
        HStack {
            Circle().fill(model.running ? Color.teal : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text(model.running ? "内核运行中" : "未运行 · 未接管网络").font(.subheadline)
            if model.running { Text("/ \(model.state.networkMode.title)").font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
            if model.busy { ProgressView().controlSize(.small); Text(model.operation).font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }
    private var profileHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(profile?.name ?? "选择 Profile").font(.system(size: 27, weight: .semibold))
                if let p = profile { Text("\(p.sourceURL == nil ? "本地副本" : "订阅") · 更新于 \(p.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let p = profile {
                if p.id != model.state.activeProfileID || !model.running { Button("激活") { model.activate(p.id) }.buttonStyle(.borderedProminent).tint(.teal) }
                Menu {
                    Button("重新加载") { model.reload(p.id) }
                    if p.sourceURL != nil { Button("更新订阅") { model.update(p.id) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
        }.disabled(model.busy).padding(.horizontal, 24).padding(.top, 5).padding(.bottom, 22)
    }
    private var modes: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) { Text("网络模式").font(.caption).foregroundStyle(.secondary); Picker("网络模式", selection: Binding(get: { model.state.networkMode }, set: model.network)) { ForEach(NetworkMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented) }
            VStack(alignment: .leading, spacing: 8) { Text("代理模式").font(.caption).foregroundStyle(.secondary); Picker("代理模式", selection: Binding(get: { model.state.proxyMode }, set: model.proxy)) { ForEach(ProxyMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented) }
        }.disabled(model.busy || !model.running || profile?.id != model.state.activeProfileID).padding(.horizontal, 24).padding(.bottom, 24)
    }
    private var nodesView: some View {
        VStack(spacing: 0) {
            HStack {
                if !model.groups.isEmpty {
                    Picker("代理组", selection: Binding(get: { group?.name ?? "" }, set: { groupName = $0 })) { ForEach(model.groups) { Text($0.name).tag($0.name) } }.labelsHidden().frame(maxWidth: 210)
                }
                Text(group?.type ?? "无代理组").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $sortByLatency) { Image(systemName: "arrow.up.arrow.down"); Text("延迟排序") }.toggleStyle(.button).controlSize(.small)
                Button { model.test(visibleNodes) } label: { Label("批量测速", systemImage: "bolt") }.controlSize(.small).disabled(model.testing || model.busy || visibleNodes.isEmpty)
            }.padding(24)
            if visibleNodes.isEmpty { ContentUnavailableView("无可展示节点", systemImage: "square.stack", description: Text("当前 Profile 没有可展示的代理组。")) }
            else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(visibleNodes, id: \.self) { node in
                            HStack(spacing: 12) {
                                Button { if let group { model.choose(group: group.name, member: node) } } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: group?.selected == node ? "checkmark.circle.fill" : "circle").foregroundStyle(group?.selected == node ? Color.teal : Color.secondary.opacity(0.4))
                                        Text(node).foregroundStyle(.primary).lineLimit(1); Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(model.busy || group?.canSelect != true)
                                Text(model.latency[node]?.title ?? "未测试").font(.system(.caption, design: .monospaced)).foregroundStyle(latencyColor(model.latency[node])).frame(minWidth: 66, alignment: .trailing)
                                Button { model.test([node]) } label: { Image(systemName: "bolt") }.buttonStyle(.borderless).disabled(model.busy || model.testing).help("测试连接延迟")
                            }.padding(.horizontal, 15).padding(.vertical, 13).background(group?.selected == node ? Color.teal.opacity(0.07) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
                HStack { Text("\(visibleNodes.count) 个节点"); Spacer(); Text("测速只测连接延迟，不改变节点选择") }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 13)
            }
        }
    }
    private var emptyState: some View {
        ContentUnavailableView { Label("从一个 Profile 开始", systemImage: "doc.badge.plus") } description: { Text("导入本地 YAML 或订阅地址。\n配置保存在本机，首次启动不会接管网络。") } actions: {
            HStack { Button("导入 YAML…", action: model.importFile); Button("添加订阅…") { subscription = true }.buttonStyle(.borderedProminent).tint(.teal) }.disabled(model.busy)
        }
    }
    private func message(_ text: String, symbol: String, color: Color) -> some View { HStack(alignment: .top) { Image(systemName: symbol).foregroundStyle(color); Text(text).font(.callout); Spacer(); Button { model.error = nil; model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(12).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 24).padding(.bottom, 12) }
    private func latencyColor(_ latency: Latency?) -> Color {
        switch latency { case .value(let n): n < 150 ? .green : n < 400 ? .orange : .red; case .failed, .timeout: .red; default: .secondary }
    }
}
struct SubscriptionView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var address = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加订阅").font(.title2.weight(.semibold))
            TextField("Profile 名称", text: $name)
            SecureField("订阅 URL（HTTP / HTTPS）", text: $address)
            Text("地址仅保存在本机；更新由你手动触发。导入成功后可选择激活。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("导入") { model.importSubscription(name: name, address: address); dismiss() }.keyboardShortcut(.defaultAction).disabled(address.isEmpty) }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 440)
    }
}
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("设置").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            Toggle("登录后自动启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin)).disabled(model.busy)
            Divider()
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Mihomo 内核").font(.headline); Text("当前版本 \(model.kernelVersion)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("检查更新", action: model.checkUpdate).disabled(model.busy) }
            if let release = model.release, release.version != model.kernelVersion { HStack { Text("可安装 \(release.version)"); Spacer(); Button("安装更新", action: model.installUpdate).disabled(model.busy) } }
            Divider()
            HStack { VStack(alignment: .leading, spacing: 5) { Text("特权 Helper").font(.headline); Text(model.helperStatus).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("授权 / 修复", action: model.authorizeHelper).disabled(model.busy) }
            Text("TUN 和系统代理需要系统批准 Helper。开发包未签名时，Off 下仍可管理配置、选择节点并测速。").font(.caption).foregroundStyle(.secondary)
            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.operation).font(.caption) } }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange) }
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
        }.padding(24).frame(width: 470).onAppear { model.refreshRegistration() }
    }
}
struct TrayView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.running ? "运行中 · \(model.state.networkMode.title)" : "未运行 · 未接管网络")
        if let p = model.state.activeProfile { Text(p.name) }
        if model.busy { Text(model.operation) }
        Divider()
        Button("打开主窗口") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
        Menu("Profile") { ForEach(model.state.profiles) { p in Button { model.activate(p.id) } label: { if p.id == model.state.activeProfileID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) } } } }.disabled(model.busy)
        Menu("网络模式") { ForEach(NetworkMode.allCases) { mode in Button { model.network(mode) } label: { if mode == model.state.networkMode { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) } } } }.disabled(model.busy || !model.running)
        Menu("代理模式") { ForEach(ProxyMode.allCases) { mode in Button { model.proxy(mode) } label: { if mode == model.state.proxyMode { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) } } } }.disabled(model.busy || !model.running)
        Divider()
        Button("退出 Mihomo") { NSApp.terminate(nil) }.keyboardShortcut("q").disabled(model.busy)
    }
}
