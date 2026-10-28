// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SecondBrain",
    defaultLocalization: "es",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SecondBrain", targets: ["SecondBrain"]),
        .executable(name: "sb", targets: ["sb"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "BrainCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            resources: [.copy("Resources/vault-template")]
        ),
        .target(
            name: "Recorder",
            dependencies: ["BrainCore"]
        ),
        .target(
            name: "Transcription",
            dependencies: [
                "BrainCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ]
        ),
        .executableTarget(
            name: "SecondBrain",
            dependencies: [
                "BrainCore", "Recorder", "Transcription",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [.copy("Resources/web"), .copy("Resources/Brand"), .process("Resources/Localization")]
        ),
        .executableTarget(
            name: "sb",
            dependencies: [
                "BrainCore", "Recorder", "Transcription",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
