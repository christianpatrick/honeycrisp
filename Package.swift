// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Honeycrisp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HoneycrispCore", targets: ["HoneycrispCore"]),
    ],
    targets: [
        .target(name: "HoneycrispCore"),
    ]
)
