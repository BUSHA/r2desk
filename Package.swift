// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "R2Desk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "R2Desk", targets: ["R2Desk"])],
    targets: [
        .target(name: "R2Core"),
        .executableTarget(name: "R2Desk", dependencies: ["R2Core"]),
        .executableTarget(name: "R2CoreChecks", dependencies: ["R2Core"], path: "Tests/R2CoreTests")
    ]
)
