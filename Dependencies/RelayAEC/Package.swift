// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RelayAEC",
    platforms: [.macOS("26.0")],
    products: [.library(name: "RelayAEC", targets: ["RelayAEC"])],
    targets: [
        .binaryTarget(name: "RelayAECBinary", path: "RelayAEC.xcframework"),
        .target(
            name: "RelayAEC",
            dependencies: ["RelayAECBinary"],
            path: "Sources/RelayAEC",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation")
            ]
        )
    ]
)
