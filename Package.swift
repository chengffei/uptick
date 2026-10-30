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
        // Bundled as Uptick.app by scripts/bundle.sh. A different binary name than the CLI,
        // since "Uptick" and "uptick" collide on a case-insensitive disk.
        .executableTarget(name: "UptickApp", dependencies: ["UptickCore"], path: "Sources/UptickApp"),
        .testTarget(name: "UptickCoreTests", dependencies: ["UptickCore"], path: "Tests/UptickCoreTests")
    ]
)
