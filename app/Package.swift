// swift-tools-version:5.9
import PackageDescription
import Foundation

// ci/build.sh builds the Rust engine staticlib (rust-spike/bfcore ->
// libbfcore.a) and exports its dir via BLOCKCORE_LIB_DIR. We link it as a
// prebuilt archive in place of the old C++ libblockcore.a. The C ABI header is
// copied into Sources/CBlockcore/include by ci/build.sh (single source of
// truth stays in /contract). See ci/build.sh.
let libDir = ProcessInfo.processInfo.environment["BLOCKCORE_LIB_DIR"]
    ?? "../rust-spike/bfcore/target/release"

let package = Package(
    name: "Blockfall",
    platforms: [.macOS(.v14)],
    targets: [
        // C interop shim exposing the frozen engine_c_api.h to Swift.
        .target(
            name: "CBlockcore",
            path: "Sources/CBlockcore"
        ),
        .executableTarget(
            name: "BlockfallApp",
            dependencies: ["CBlockcore"],
            path: "Sources/BlockfallApp",
            linkerSettings: [
                .unsafeFlags([
                    // Link the Rust engine staticlib. No -lc++ needed: the Rust
                    // archive pulls in nothing beyond libSystem (already linked).
                    "-L\(libDir)", "-lbfcore",
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
