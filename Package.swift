// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "agency",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgencyKit", targets: ["AgencyKit"]),
    ],
    targets: [
        .target(name: "AgencyKit"),
        .executableTarget(name: "agency-cli", dependencies: ["AgencyKit"]),
        .executableTarget(name: "AgencyApp", dependencies: ["AgencyKit"]),
        .testTarget(name: "AgencyKitTests", dependencies: ["AgencyKit"]),
    ]
)
