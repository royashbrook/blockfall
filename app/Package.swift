// swift-tools-version:5.9
import PackageDescription
import Foundation

// The CMake build (ci/build.sh) produces libblockcore.a and exports its dir
// via BLOCKCORE_LIB_DIR. We link it as a prebuilt archive. The C ABI header is
// copied into Sources/CBlockcore/include by ci/build.sh (single source of
// truth stays in /contract). See ci/build.sh.
let libDir = ProcessInfo.processInfo.environment["BLOCKCORE_LIB_DIR"]
    ?? "../build/engine"

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
                    "-L\(libDir)", "-lblockcore", "-lc++",
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
