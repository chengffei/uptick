// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Renew",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RenewCore", targets: ["RenewCore"]),
        .executable(name: "renew", targets: ["renew"])
    ],
    targets: [
        .target(name: "RenewCore", path: "Sources/RenewCore"),
        .executableTarget(name: "renew", dependencies: ["RenewCore"], path: "Sources/renew"),
        .testTarget(name: "RenewCoreTests", dependencies: ["RenewCore"], path: "Tests/RenewCoreTests")
    ]
)
