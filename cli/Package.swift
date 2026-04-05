// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "simpilot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "simpilot", path: "Sources/simpilot")
    ]
)
