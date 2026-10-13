// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FindFast",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FindFastCore", targets: ["FindFastCore"]),
        .executable(name: "findfast", targets: ["findfast"]),
        .executable(name: "findfast-tests", targets: ["findfast-tests"]),
        .executable(name: "FindFastApp", targets: ["FindFastApp"]),
    ],
    targets: [
        .target(name: "CFFBulk"),
        .target(
            name: "FindFastCore",
            dependencies: ["CFFBulk"],
            linkerSettings: [.linkedFramework("CoreServices")]
        ),
        .executableTarget(name: "findfast", dependencies: ["FindFastCore"]),
        // XCTest and the swift-testing macro plugin are both unavailable in a
        // CommandLineTools-only toolchain (no full Xcode), so this is a
        // minimal dependency-free assertion runner instead of a testTarget.
        .executableTarget(name: "findfast-tests", dependencies: ["FindFastCore"]),
        .executableTarget(name: "FindFastApp", dependencies: ["FindFastCore"]),
    ]
)
