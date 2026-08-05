// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexRemote",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CodexRemoteCore", targets: ["CodexRemoteCore"]),
        .library(name: "CodexRemoteMac", targets: ["CodexRemoteMac"]),
        .executable(name: "codex-remote-helper", targets: ["codex-remote-helper"]),
        .executable(name: "codex-remote-app", targets: ["CodexRemoteApp"]),
    ],
    targets: [
        .target(name: "CodexRemoteCore"),
        .target(name: "CodexRemoteMac", dependencies: ["CodexRemoteCore"]),
        .executableTarget(name: "codex-remote-helper", dependencies: ["CodexRemoteCore", "CodexRemoteMac"]),
        .executableTarget(name: "CodexRemoteApp", dependencies: ["CodexRemoteCore", "CodexRemoteMac"]),
        .testTarget(name: "CodexRemoteCoreTests", dependencies: ["CodexRemoteCore"]),
        .testTarget(name: "CodexRemoteMacTests", dependencies: ["CodexRemoteMac", "CodexRemoteCore"]),
    ]
)
