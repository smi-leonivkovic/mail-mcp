// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleMailMCP",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "apple-mail-mcp", targets: ["AppleMailMCP"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AppleMailMCP",
            dependencies: [],
            path: "Sources/AppleMailMCP"
        )
    ]
)
