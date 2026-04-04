// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SwiftPROJ",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SwiftPROJ",
            targets: ["SwiftPROJ"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "PROJ",
            path: "build/PROJ.xcframework"
        ),
        .target(
            name: "SwiftPROJ",
            dependencies: ["PROJ"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
            ]
        ),
        .testTarget(
            name: "SwiftPROJTests",
            dependencies: ["SwiftPROJ"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
