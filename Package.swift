// swift-tools-version: 6.0
// LiveSubs: live English subtitles for Hebrew audio playing on a Mac.
// The app target needs macOS (AppKit, ScreenCaptureKit); shared logic lives in SubsCore/,
// which also builds and tests on Linux.
import PackageDescription

let package = Package(
    name: "LiveSubs",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "SubsCore")],
    targets: [
        .executableTarget(
            name: "LiveSubs",
            dependencies: [.product(name: "SubsCore", package: "SubsCore")],
            path: "App/Sources/LiveSubs"
        ),
    ]
)
