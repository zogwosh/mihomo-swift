import Foundation
import CryptoKit

public struct KernelRelease: Identifiable, Sendable {
    public var id: String { version }
    public let version: String
    public let downloadURL: URL
    public let digest: String
    public init(version: String, downloadURL: URL, digest: String) { self.version = version; self.downloadURL = downloadURL; self.digest = digest }
}
public enum KernelUpdates {
    public static func latest() async throws -> KernelRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")!)
        request.setValue("MihomoSwift", forHTTPHeaderField: "User-Agent"); request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let version = json["tag_name"] as? String, let assets = json["assets"] as? [[String: Any]], let asset = assets.first(where: { $0["name"] as? String == "mihomo-darwin-arm64-\(version).gz" }), let link = asset["browser_download_url"] as? String, let url = URL(string: link), let digest = asset["digest"] as? String, digest.hasPrefix("sha256:"), digest.count == 71, url.host == "github.com", url.path.hasPrefix("/MetaCubeX/mihomo/releases/download/") else { throw ClientError.message("官方发行中没有可校验的 macOS ARM64 资产。") }
        return KernelRelease(version: version, downloadURL: url, digest: String(digest.dropFirst(7)))
    }
    public static func download(_ release: KernelRelease, store: StateStore) async throws -> String {
        let request = URLRequest(url: release.downloadURL, timeoutInterval: 120)
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClientError.message("内核下载失败；现有内核继续运行。") }
        let data = try Data(contentsOf: temporary)
        guard data.count < 100 * 1024 * 1024, sha256(data) == release.digest else { throw ClientError.message("下载文件完整性校验失败；现有内核继续运行。") }
        let compressed = try store.writeImmutable(data, folder: "kernels", suffix: "gz")
        defer { try? store.remove(compressed) }
        let input = try store.url(compressed)
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-dc", input.path], timeout: 30)
        guard result.status == 0, isARM64MachO(result.output) else { throw ClientError.message("下载的内核不是 macOS ARM64 可执行文件。") }
        let path = try store.writeImmutable(result.output, folder: "kernels", suffix: "mihomo")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.url(path).path)
        return path
    }
    public static func isARM64MachO(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        return Array(data.prefix(8)) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]
    }
}
public func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public enum Subscription {
    public static func fetch(_ url: URL) async throws -> Data {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw ClientError.message("请输入有效的 HTTP 或 HTTPS 订阅地址。") }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        let (temporary, response) = try await URLSession(configuration: config).download(for: URLRequest(url: url))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ClientError.message("订阅下载失败，请检查地址或稍后重试。") }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Limits.maxProfileBytes else { throw ClientError.message("订阅配置过大。") }
        let raw = try Data(contentsOf: temporary); _ = try Configuration.parse(raw); return raw
    }
}
