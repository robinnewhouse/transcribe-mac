// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Transcribe",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "TranscribeCore",
            path: "Sources/TranscribeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Transcribe",
            dependencies: ["TranscribeCore"],
            path: "Sources/Transcribe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TranscribeCLI",
            dependencies: ["TranscribeCore"],
            path: "Sources/TranscribeCLI",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
