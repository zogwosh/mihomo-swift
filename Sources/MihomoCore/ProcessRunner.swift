import Foundation
import Darwin

public struct CommandResult { public let status: Int32; public let output: Data }
public enum ProcessRunner {
    public static func run(_ executable: URL, arguments: [String], directory: URL? = nil, timeout: TimeInterval = 15, environment: [String: String]? = nil) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(); process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
                if let environment { process.environment = environment }
                // Use a private file rather than an undrained pipe: large diagnostic output cannot deadlock validation.
                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                defer { try? FileManager.default.removeItem(at: outputURL) }
                do {
                    let handle = try FileHandle(forWritingTo: outputURL); defer { try? handle.close() }
                    process.standardOutput = handle; process.standardError = handle
                    try process.run()
                    let deadline = Date().addingTimeInterval(timeout)
                    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.04) }
                    if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.2); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit(); throw ClientError.message("操作超时，请重试。") }
                    process.waitUntilExit()
                    let output = (try? Data(contentsOf: outputURL)) ?? Data()
                    continuation.resume(returning: CommandResult(status: process.terminationStatus, output: output))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
public final class InstanceLock {
    private var fd: Int32 = -1
    public init(root: URL) throws {
        fd = open(root.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd) }; fd = -1; throw ClientError.message("应用已经在运行。") }
    }
    deinit { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}
