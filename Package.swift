// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MihomoSwift", platforms: [.macOS("26.0")],
    products: [.library(name: "MihomoCore", targets: ["MihomoCore"]), .executable(name: "MihomoSwift", targets: ["MihomoApp"]), .executable(name: "MihomoHelper", targets: ["MihomoHelper"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")],
    targets: [
        .target(name: "HelperIPC"),
        .target(name: "MihomoCore", dependencies: ["Yams", "HelperIPC"]),
        .executableTarget(name: "MihomoApp", dependencies: ["MihomoCore", "HelperIPC"]),
        .executableTarget(name: "MihomoHelper", dependencies: ["MihomoCore", "HelperIPC"]),
        .executableTarget(name: "MihomoChecks", dependencies: ["MihomoCore"], path: "Tests/MihomoCoreTests")
    ], swiftLanguageModes: [.v5]
)
