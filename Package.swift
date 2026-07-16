// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "local-ai-cli",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "local-ai-cli",
            path: "Sources/local-ai-cli"
        )
    ]
)
