// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "R2Desk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "R2Desk", targets: ["R2Desk"])],
    targets: [
        .target(name: "R2Core"),
        .target(name: "R2FinderShared", dependencies: ["R2Core"]),
        .executableTarget(name: "R2Desk", dependencies: ["R2Core", "R2FinderShared"]),
        .target(name: "R2FileProvider", dependencies: ["R2Core", "R2FinderShared"],
                swiftSettings: [.unsafeFlags(["-enable-testing"], .when(configuration: .debug))]),
        .executableTarget(name: "R2FinderChecks", dependencies: ["R2FileProvider", "R2Core", "R2FinderShared"], path: "Tests/R2FinderTests"),
        .executableTarget(name: "R2CoreChecks", dependencies: ["R2Core"], path: "Tests/R2CoreTests")
    ]
)
