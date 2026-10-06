// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "R2Man",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "R2Man", targets: ["R2Man"])],
    targets: [
        .target(name: "R2Core"),
        .executableTarget(name: "R2Man", dependencies: ["R2Core"]),
        .executableTarget(name: "R2CoreChecks", dependencies: ["R2Core"], path: "Tests/R2CoreTests")
    ]
)
