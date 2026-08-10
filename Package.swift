// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoveItKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "MoveItKit", targets: ["MoveItKit"]),
    ],
    targets: [
        .target(
            name: "MoveItKit",
            path: "Sources/MoveItKit",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                // Deliberately NOT -Ounchecked. It was here for speed, and it was
                // the wrong call twice over: it strips array-bounds and integer
                // overflow checks from code whose entire job is parsing untrusted
                // input (ZIP headers, CSV from an agency, protobuf off the
                // network), turning a clean crash into a memory-safety bug; and
                // SwiftPM rejects `unsafeFlags` in a package consumed as a
                // dependency, which is exactly how the app target consumes this.
                // The router's cost is memory bandwidth, not bounds checks.
            ]
        ),
        .testTarget(
            name: "MoveItKitTests",
            dependencies: ["MoveItKit"],
            path: "Tests/MoveItKitTests"
        ),
    ]
)
