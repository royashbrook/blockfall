// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Blockfall",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // The same generated engine product is consumable by the macOS app and
        // the future iPadOS shell. Build it with ci/build-xcframework.sh.
        .library(name: "CBlockcore", targets: ["CBlockcore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .binaryTarget(
            name: "CBlockcore",
            path: "Artifacts/CBlockcore.xcframework"
        ),
        .executableTarget(
            name: "BlockfallApp",
            dependencies: [
                "CBlockcore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/BlockfallApp",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
