// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ncode",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ncode",
            path: "Sources/ncode"
        )
    ]
)
