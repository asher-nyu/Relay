// swift-tools-version: 6.0
import PackageDescription

// Argmax OSS Swift v1.1.1, vendored from the publisher's release archive.
// Only the two targets required for local language detection are included.
let package = Package(
    name: "ArgmaxOSS",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WhisperKit", targets: ["WhisperKit"])],
    targets: [
        .target(name: "ArgmaxCore"),
        .target(name: "WhisperKit", dependencies: ["ArgmaxCore"])
    ],
    swiftLanguageModes: [.v5]
)
