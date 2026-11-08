// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TidyCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TidyCore", targets: ["TidyCore"]),
        .executable(name: "tidyctl", targets: ["tidyctl"]),
    ],
    targets: [
        .target(
            name: "TidyCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "tidyctl", dependencies: ["TidyCore"]),
        .testTarget(name: "TidyCoreTests", dependencies: ["TidyCore"]),
    ],
    swiftLanguageModes: [.v5]
)
