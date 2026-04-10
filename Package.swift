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
let releaseURL = "https://github.com/seriouscyrus/SwiftPROJ/releases/download/0.1.0/PROJ.xcframework.zip"
let releaseChecksum = "648b01cd4a4473ee241308a03faf510615f8e0b2614e592e867d19627359e5e1"
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
