// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FileConverter",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "FileConverterContracts",
            targets: ["FileConverterContracts"]
        ),
        .library(
            name: "FileConverterCore",
            targets: ["FileConverterCore"]
        ),
        .library(
            name: "FileConverterNativeBackends",
            targets: ["FileConverterNativeBackends"]
        ),
        .library(
            name: "FileConverterExternalBackends",
            targets: ["FileConverterExternalBackends"]
        ),
        .library(
            name: "FileConverterFinderSupport",
            targets: ["FileConverterFinderSupport"]
        ),
        .executable(
            name: "FileConverterApp",
            targets: ["FileConverterApp"]
        ),
        .executable(
            name: "FileConverterFinderSync",
            targets: ["FileConverterFinderSync"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "FileConverterContracts",
            dependencies: [],
            path: "Sources/FileConverterContracts"
        ),
        .target(
            name: "FileConverterCore",
            dependencies: [
                "FileConverterContracts"
            ],
            path: "Sources/FileConverterCore",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
        .target(
            name: "FileConverterNativeBackends",
            dependencies: ["FileConverterCore"],
            path: "Sources/FileConverterNativeBackends"
        ),
        .target(
            name: "FileConverterExternalBackends",
            dependencies: ["FileConverterCore"],
            path: "Sources/FileConverterExternalBackends"
        ),
        .target(
            name: "FileConverterFinderSupport",
            dependencies: ["FileConverterContracts"],
            path: "Sources/FileConverterFinderSupport"
        ),
        .executableTarget(
            name: "FileConverterApp",
            dependencies: [
                "FileConverterContracts",
                "FileConverterCore",
                "FileConverterNativeBackends",
                "FileConverterExternalBackends",
                "FileConverterFinderSupport"
            ],
            path: "Sources/FileConverterApp",
            exclude: [
                "Assets.xcassets",
                "FileConverter.entitlements",
                "FileConverterDebug.entitlements",
                "Info.plist",
                "Resources"
            ]
        ),
        .executableTarget(
            name: "FileConverterFinderSync",
            dependencies: [
                "FileConverterContracts",
                "FileConverterFinderSupport"
            ],
            path: "Sources/FileConverterFinderSync",
            exclude: [
                "FileConverterFinder.entitlements",
                "FileConverterFinderDebug.entitlements",
                "Info.plist"
            ]
        ),
        .testTarget(
            name: "FileConverterTests",
            dependencies: [
                "FileConverterCore",
                "FileConverterContracts",
                "FileConverterNativeBackends",
                "FileConverterExternalBackends"
            ],
            path: "Tests/FileConverterTests"
        ),
        .testTarget(
            name: "FileConverterFinderSupportTests",
            dependencies: [
                "FileConverterContracts",
                "FileConverterFinderSupport"
            ],
            path: "Tests/FileConverterFinderSupportTests"
        )
    ]
)
