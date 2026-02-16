// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawVaultDaemon",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ClawVaultDaemon",
            path: "Sources/ClawVaultDaemon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClawVaultDaemonTests",
            dependencies: ["ClawVaultDaemon"],
            path: "Tests/ClawVaultDaemonTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
