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
        .library(name: "OpenBotsExecutionRules", targets: ["OpenBotsExecutionRules"]),
        .library(name: "OpenBotsAgenticRuntime", targets: ["OpenBotsAgenticRuntime"]),
        .library(name: "OpenBotsServices", targets: ["OpenBotsServices"]),
        .library(name: "OpenBotsUI", targets: ["OpenBotsUI"]),
        .library(name: "OpenBotsTestSupport", targets: ["OpenBotsTestSupport"]),
        .executable(name: "openbots-calendar-read", targets: ["openbots-calendar-read"]),
        .executable(name: "openbots-google-helper", targets: ["openbots-google-helper"])
    ],
    dependencies: [
        .package(path: "Tools/ClaudeRuntimeProbe")
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
                "OpenBotsSecurity",
                "OpenBotsExecutionRules",
                "OpenBotsAgenticRuntime"
            ],
            resources: [.process("Resources")]
        ),
        // The app's own read-only window onto Calendar, and the one piece of a
        // connector that cannot be JavaScript. Apple Events cannot expand a
        // recurring series at all — it misses most occurrences across a year —
        // and can take tens of seconds for any window where EventKit costs
        // milliseconds. The reasons are in the file's own header.
        .executableTarget(name: "openbots-calendar-read"),
        // Owns Google OAuth and REST calls so tokens stay in one Keychain item
        // visible only to this same bundled executable. The node MCP server
        // receives results, never credentials.
        .executableTarget(
            name: "openbots-google-helper",
            dependencies: ["OpenBotsSecurity", "OpenBotsServices"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .target(name: "OpenBotsExecutionRules"),
        .target(
            name: "OpenBotsAgenticRuntime",
            dependencies: [
                "OpenBotsExecutionRules",
                "OpenBotsContent",
                "OpenBotsSecurity",
                .product(name: "ClaudeRuntimeProbeCore", package: "ClaudeRuntimeProbe")
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
            dependencies: ["OpenBotsDomain", "OpenBotsRuntime"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OpenBotsAgenticRuntimeTests",
            dependencies: [
                "OpenBotsAgenticRuntime", "OpenBotsExecutionRules", "OpenBotsSecurity",
                .product(name: "ClaudeRuntimeProbeCore", package: "ClaudeRuntimeProbe")
            ]
        ),
        .testTarget(
            name: "OpenBotsServicesTests",
            dependencies: ["OpenBotsDomain", "OpenBotsPersistence", "OpenBotsServices", "OpenBotsTestSupport", "OpenBotsAgenticRuntime", "OpenBotsExecutionRules"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "OpenBotsExecutionRulesTests",
            dependencies: ["OpenBotsExecutionRules"]
        ),
        // The calendar reader's wait for access. An executable
        // target is testable in SwiftPM; its top-level code never runs here.
        .testTarget(
            name: "OpenBotsCalendarReadTests",
            dependencies: ["openbots-calendar-read"]
        ),
        .testTarget(
            name: "OpenBotsUITests",
            dependencies: ["OpenBotsDomain", "OpenBotsServices", "OpenBotsUI", "OpenBotsTestSupport"]
        )
    ],
    swiftLanguageModes: [.v6]
)
