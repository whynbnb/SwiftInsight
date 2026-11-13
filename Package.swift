// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftInsight",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "SwiftInsight", targets: ["SwiftInsight"]),
        .executable(name: "SwiftInsightHelper", targets: ["SwiftInsightHelper"]),
    ],
    targets: [
        .executableTarget(
            name: "SwiftInsight",
            path: "Sources/SwiftInsight",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "SwiftInsightHelper",
            path: "Sources/SwiftInsightHelper"
        ),
    ]
)
