// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Honeycrisp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HoneycrispCore", targets: ["HoneycrispCore"]),
        .executable(name: "honeycrisp", targets: ["HoneycrispCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
        // Sparkle drives in-app updates and links into the menu bar app only;
        // HoneycrispCore, the CLI, and the tests stay dependency-light.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0"),
    ],
    targets: [
        .target(
            name: "HoneycrispCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(name: "HoneycrispCLI", dependencies: ["HoneycrispCore"]),
        .executableTarget(
            name: "HoneycrispMenuBar",
            dependencies: ["HoneycrispCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "HoneycrispCoreTests", dependencies: ["HoneycrispCore"]),
    ]
)
