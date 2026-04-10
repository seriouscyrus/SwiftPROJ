# SwiftPROJ

A Swift package wrapping the [PROJ](https://proj.org/) coordinate transformation library (v9.8.0) as an XCFramework for Apple platforms.

PROJ is the standard library for cartographic projections and coordinate transformations. SwiftPROJ makes it available to Swift projects via Swift Package Manager, with a built-in URLSession networking bridge for on-demand grid file downloads.

## Platforms

| Platform | Architecture | Minimum Version |
|----------|-------------|-----------------|
| iOS | arm64 | 16.0 |
| iOS Simulator | arm64 | 16.0 |
| macOS | arm64 | 13.0 |

## Installation

### Swift Package Manager

Add SwiftPROJ to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/user/SwiftPROJ.git", from: "0.1.0")
]
```

Then add `"SwiftPROJ"` to the target's dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: ["SwiftPROJ"]
)
```

Or in Xcode: **File > Add Package Dependencies...** and enter the repository URL.

## Usage

### Basic Coordinate Transformation

Use the PROJ C API directly for coordinate transformations:

```swift
import PROJ

// Create a PROJ context
let ctx = proj_context_create()
defer { proj_context_destroy(ctx) }

// WGS84 (EPSG:4326) -> Swiss LV95 (EPSG:2056)
let transform = proj_create_crs_to_crs(ctx, "EPSG:4326", "EPSG:2056", nil)
defer { proj_destroy(transform) }

// Normalize for (lon, lat) input order
let normalized = proj_normalize_for_visualization(ctx, transform)
defer { proj_destroy(normalized) }

// Transform a coordinate (longitude, latitude)
let coord = PJ_COORD(lp: PJ_LP(lam: 6.618, phi: 46.532))
let result = proj_trans(normalized, PJ_FWD, coord)

let easting = result.enu.e   // ~2533100
let northing = result.enu.n  // ~1151750
```

### Networking (Grid File Downloads)

PROJ uses grid files for high-accuracy transformations (e.g., geoid models). The `PROJNetworkBridge` enables downloading these on demand via URLSession:

```swift
import PROJ
import SwiftPROJ

let ctx = proj_context_create()!
defer { proj_context_destroy(ctx) }

// Enable networking — PROJ will fetch grids from cdn.proj.org as needed
PROJNetworkBridge.enableNetworking(on: ctx)
```

You can also specify a custom CDN endpoint:

```swift
PROJNetworkBridge.enableNetworking(on: ctx, endpoint: "https://my-cdn.example.com/proj/")
```

### Discovering Required Grids

Query which grid files a transformation needs:

```swift
let grids = PROJNetworkBridge.gridsUsed(
    context: ctx,
    source: "EPSG:4979",
    target: "EPSG:2056+5728"
)

for grid in grids {
    print("\(grid.shortName) — available: \(grid.available), url: \(grid.url)")
}
```

### Downloading Grid Files

Download missing grids with progress reporting:

```swift
for grid in grids where !grid.available {
    let success = PROJNetworkBridge.downloadFile(
        context: ctx,
        urlOrFilename: grid.url.isEmpty ? grid.shortName : grid.url,
        progress: { percent in
            print("Download: \(Int(percent))%")
            return true // return false to cancel
        }
    )
}
```

### 3D Transformation with Geoid Grid

Once grids are available, perform high-accuracy 3D transformations:

```swift
// WGS84 geographic 3D -> Swiss LV95 + LN02 height
let transform = proj_create_crs_to_crs(ctx, "EPSG:4979", "EPSG:2056+5728", nil)
let normalized = proj_normalize_for_visualization(ctx, transform)

// lon, lat, ellipsoidal height
let coord = PJ_COORD(lpz: PJ_LPZ(lam: 6.618, phi: 46.532, z: 500.0))
let result = proj_trans(normalized, PJ_FWD, coord)

let easting  = result.enu.e  // Swiss easting
let northing = result.enu.n  // Swiss northing
let height   = result.enu.u  // LN02 height (geoid-corrected)
```

## Module Structure

- **`PROJ`** — The C library binary target (XCFramework). Provides all PROJ C API functions (`proj_create`, `proj_trans`, etc.) and the geodesic library.
- **`SwiftPROJ`** — Swift wrapper target. Currently provides `PROJNetworkBridge` for URLSession-based grid file networking.

Import `PROJ` for direct C API access, or `SwiftPROJ` for the networking bridge (which re-exports `PROJ`).

## What's Included

The PROJ XCFramework is self-contained:

- **PROJ 9.8.0** — built as a dynamic framework
- **libtiff 4.7.0** — statically linked into PROJ (for TIFF-based grid files)
- **proj.db** — embedded as a resource (no external data files needed)
- **Bundled dependencies**: nlohmann/json (internal)

Runtime dependencies are system libraries only: `libz`, `libsqlite3`, `libc++`.

## Building from Source

### Prerequisites

- Xcode with command line tools
- CMake (`brew install cmake`)
- sqlite3 (included with macOS)

### Build the XCFramework

```bash
# Initialize the PROJ submodule
git submodule update --init

# Build everything
./scripts/build_xcframework.sh
```

This will:

1. Download and build libtiff (static) for all platforms
2. Build PROJ (dynamic, with libtiff linked in) for all platforms
3. Package each platform build into a `.framework`
4. Bundle all frameworks into `build/PROJ.xcframework`

### Release

```bash
# Dry run — shows what would happen
./scripts/release.sh 0.1.0 --dry-run

# Create a release
./scripts/release.sh 0.1.0
```

The release script:

1. Zips the XCFramework
2. Computes the SPM checksum
3. Updates `Package.swift` with the download URL and checksum
4. Commits, tags, and pushes
5. Creates a release on GitHub/Codeberg with the zip attached

The hosting platform is auto-detected from the git remote origin.

## License

PROJ is licensed under the [MIT License](https://github.com/OSGeo/PROJ/blob/master/COPYING).
