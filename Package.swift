// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Uptick",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UptickCore", targets: ["UptickCore"]),
        .executable(name: "uptick", targets: ["uptick"])
    ],
    targets: [
        .target(name: "UptickCore", path: "Sources/UptickCore"),
        .executableTarget(name: "uptick", dependencies: ["UptickCore"], path: "Sources/uptick"),
        .testTarget(name: "UptickCoreTests", dependencies: ["UptickCore"], path: "Tests/UptickCoreTests")
    ]
)
