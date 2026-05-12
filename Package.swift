// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Transcribe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Transcribe", path: "Sources/Transcribe"),
    ]
)
