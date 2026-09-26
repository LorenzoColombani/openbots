// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClaudeRuntimeProbe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ClaudeRuntimeProbeCore", targets: ["ClaudeRuntimeProbeCore"]),
        .executable(name: "claude-runtime-probe", targets: ["ClaudeRuntimeProbe"]),
        .executable(name: "claude-profile-bootstrap", targets: ["ClaudeProfileBootstrap"])
    ],
    targets: [
        .target(name: "ClaudeRuntimeProbeCore"),
        .executableTarget(
            name: "ClaudeRuntimeProbe",
            dependencies: ["ClaudeRuntimeProbeCore"]
        ),
        .executableTarget(
            name: "ClaudeProfileBootstrap",
            dependencies: ["ClaudeRuntimeProbeCore"]
        ),
        .testTarget(
            name: "ClaudeRuntimeProbeCoreTests",
            dependencies: ["ClaudeRuntimeProbeCore"]
        )
    ]
)
