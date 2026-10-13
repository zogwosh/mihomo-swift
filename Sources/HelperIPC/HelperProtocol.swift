import Foundation
import Security

public enum HelperIdentity {
    public static let app = "io.github.zogwosh.MihomoSwift"
    public static let service = "io.github.zogwosh.MihomoSwift.Helper"
    public static let plist = service + ".plist"
    public static func teamIdentifier() -> String? {
        var code: SecCode?; guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?; guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
    public static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
@objc public protocol HelperProtocol {
    func prepare(_ configuration: Data, resources: Data, reply: @escaping (String?, String?) -> Void)
    func start(_ kernel: Data, expectedHash: String, configName: String, reply: @escaping (String?, String?) -> Void)
    func setSystemProxy(_ enabled: Bool, reply: @escaping (String?) -> Void)
    func commitKernel(_ hash: String, reply: @escaping (String?) -> Void)
    func stop(reply: @escaping (String?) -> Void)
    func heartbeat(reply: @escaping (String?) -> Void)
}
