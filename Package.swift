// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "OpenBotsNext",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenBotsDomain", targets: ["OpenBotsDomain"]),
        .library(name: "OpenBotsPersistence", targets: ["OpenBotsPersistence"]),
        .library(name: "OpenBotsContent", targets: ["OpenBotsContent"]),
        .library(name: "OpenBotsRuntime", targets: ["OpenBotsRuntime"]),
        .library(name: "OpenBotsSecurity", targets: ["OpenBotsSecurity"]),
        .library(name: "OpenBotsServices", targets: ["OpenBotsServices"]),
        .library(name: "OpenBotsUI", targets: ["OpenBotsUI"]),
        .library(name: "OpenBotsTestSupport", targets: ["OpenBotsTestSupport"])
    ],
    targets: [
        .target(name: "OpenBotsDomain"),
        .target(
            name: "OpenBotsPersistence",
            dependencies: ["OpenBotsDomain"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "OpenBotsContent",
            dependencies: ["OpenBotsDomain"],
            linkerSettings: [.linkedFramework("FileProvider")]
        ),
        .target(
            name: "OpenBotsRuntime",
            dependencies: ["OpenBotsDomain"]
        ),
        .target(
            name: "OpenBotsSecurity",
            dependencies: ["OpenBotsDomain"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "OpenBotsServices",
            dependencies: [
                "OpenBotsDomain",
                "OpenBotsPersistence",
                "OpenBotsContent",
                "OpenBotsRuntime",
                "OpenBotsSecurity"
            ]
        ),
        .target(
            name: "OpenBotsUI",
            dependencies: ["OpenBotsDomain", "OpenBotsServices"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "OpenBotsTestSupport",
            dependencies: [
                "OpenBotsDomain",
                "OpenBotsPersistence",
                "OpenBotsContent",
                "OpenBotsRuntime",
                "OpenBotsSecurity",
                "OpenBotsServices"
            ]
        ),
        .testTarget(
            name: "OpenBotsDomainTests",
            dependencies: ["OpenBotsDomain"]
        ),
        .testTarget(
            name: "OpenBotsPersistenceTests",
            dependencies: ["OpenBotsDomain", "OpenBotsPersistence", "OpenBotsTestSupport"]
        ),
        .testTarget(
            name: "OpenBotsContentTests",
            dependencies: ["OpenBotsDomain", "OpenBotsContent", "OpenBotsTestSupport"]
        ),
        .testTarget(
            name: "OpenBotsSecurityTests",
            dependencies: ["OpenBotsDomain", "OpenBotsSecurity", "OpenBotsTestSupport"]
        ),
        .testTarget(
            name: "OpenBotsRuntimeTests",
            dependencies: ["OpenBotsDomain", "OpenBotsRuntime"]
        ),
        .testTarget(
            name: "OpenBotsServicesTests",
            dependencies: ["OpenBotsDomain", "OpenBotsServices", "OpenBotsTestSupport"]
        ),
        .testTarget(
            name: "OpenBotsUITests",
            dependencies: ["OpenBotsDomain", "OpenBotsServices", "OpenBotsUI", "OpenBotsTestSupport"]
        )
    ],
    swiftLanguageModes: [.v6]
)
