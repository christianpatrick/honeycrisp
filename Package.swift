// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Honeycrisp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HoneycrispCore", targets: ["HoneycrispCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "HoneycrispCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(name: "HoneycrispCoreTests", dependencies: ["HoneycrispCore"]),
    ]
)
