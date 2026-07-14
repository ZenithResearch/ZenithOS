// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZenithOS",
    platforms: [
        .macOS(.v13)   // ScreenCaptureKit per-process audio filtering requires macOS 13+
    ],
    dependencies: [
        .package(
            url: "https://github.com/matrix-org/matrix-rust-components-swift",
            exact: "26.06.06"
        ),
    ],
    targets: [
        // Menu bar daemon — no dock icon
        .executableTarget(
            name: "ZenithOS",
            path: "Sources/ZenithOS",
            swiftSettings: [
                .unsafeFlags(["-framework", "ScreenCaptureKit"], .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // Dock app — transcript viewer / dashboard
        .executableTarget(
            name: "ZenithOSUI",
            dependencies: [
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ],
            path: "Sources/ZenithOSUI",
            exclude: [
                "Markdown/Resources",
            ],
            resources: [
                .copy("MarkdownResources"),
            ]
        ),
        .testTarget(
            name: "ZenithOSUITests",
            dependencies: ["ZenithOSUI"],
            path: "Tests/ZenithOSUITests"
        ),
    ]
)
