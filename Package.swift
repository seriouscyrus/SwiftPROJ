// swift-tools-version: 6.3
import PackageDescription
import Foundation

// Auto-detect: use local xcframework if available (developer), otherwise remote (consumer).
let localXCFramework = "build/PROJ.xcframework"
let useLocalBinary = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent(localXCFramework).path
)

// --- Release coordinates (updated by scripts/release.sh) ---
let releaseURL = "https://github.com/user/SwiftPROJ/releases/download/0.0.0/PROJ.xcframework.zip"
let releaseChecksum = "0000000000000000000000000000000000000000000000000000000000000000"
// --- End release coordinates ---

let projTarget: Target = useLocalBinary
    ? .binaryTarget(name: "PROJ", path: localXCFramework)
    : .binaryTarget(name: "PROJ", url: releaseURL, checksum: releaseChecksum)

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
        projTarget,
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
