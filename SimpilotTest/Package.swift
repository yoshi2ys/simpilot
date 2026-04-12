// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimpilotTest",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SimpilotTest", targets: ["SimpilotTest"]),
    ],
    targets: [
        .target(name: "SimpilotTest", path: "Sources/SimpilotTest"),
        .testTarget(
            name: "SimpilotTestTests",
            dependencies: ["SimpilotTest"],
            path: "Tests/SimpilotTestTests"
        ),
    ]
)
