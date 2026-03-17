// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenClawMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OpenClawMonitor",
            path: "Sources/OpenClawMonitor"
        )
    ]
)
