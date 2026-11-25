// swift-tools-version: 6.0
// Platform-independent logic for LiveSubs (Foundation only), tested on Linux with `swift test`.
import PackageDescription

let package = Package(
    name: "SubsCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SubsCore", targets: ["SubsCore"])],
    targets: [
        .target(name: "SubsCore"),
        .testTarget(name: "SubsCoreTests", dependencies: ["SubsCore"]),
    ]
)
