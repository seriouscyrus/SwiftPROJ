import Testing
import PROJ
import SwiftPROJ

@Test func wgs84ToSwissLV95() throws {
    // Create a PROJ context
    let ctx = proj_context_create()
    defer { proj_context_destroy(ctx) }

    // WGS84 (EPSG:4326) -> Swiss CH1903+ / LV95 (EPSG:2056)
    let transform = proj_create_crs_to_crs(
        ctx,
        "EPSG:4326",
        "EPSG:2056",
        nil
    )
    #expect(transform != nil, "Failed to create CRS-to-CRS transformation")
    defer { proj_destroy(transform) }

    // proj_create_crs_to_crs respects CRS axis order (lat, lon for EPSG:4326).
    // Use proj_normalize_for_visualization for consistent (lon, lat) input order.
    let normalized = proj_normalize_for_visualization(ctx, transform)
    #expect(normalized != nil, "Failed to normalize transformation")
    defer { proj_destroy(normalized) }

    // Input: longitude 6.6180459095579325, latitude 46.53234416429708
    let coord = PJ_COORD(
        lp: PJ_LP(lam: 6.6180459095579325, phi: 46.53234416429708)
    )

    let result = proj_trans(normalized, PJ_FWD, coord)

    let easting = result.enu.e
    let northing = result.enu.n

    // Swiss LV95 coordinates for this location (Lausanne area) should be approximately:
    // Easting ~2533100, Northing ~1151750
    #expect(easting > 2_500_000 && easting < 2_600_000,
            "Easting \(easting) outside expected Swiss LV95 range")
    #expect(northing > 1_100_000 && northing < 1_200_000,
            "Northing \(northing) outside expected Swiss LV95 range")

    print("WGS84 (46.5323, 6.6180) -> Swiss LV95: E=\(easting), N=\(northing)")
}

@Test func networkBridgeEnablesNetworking() throws {
    let ctx = proj_context_create()
    defer { proj_context_destroy(ctx) }

    // Network should be disabled by default (built without CURL)
    #expect(proj_context_is_network_enabled(ctx) == 0,
            "Network should be disabled before enabling bridge")

    // Enable networking via our URLSession bridge
    PROJNetworkBridge.enableNetworking(on: ctx!)

    // Verify network is now enabled
    #expect(proj_context_is_network_enabled(ctx) == 1,
            "Network should be enabled after enabling bridge")

    // Verify the endpoint is set
    let endpoint = String(cString: proj_context_get_url_endpoint(ctx))
    #expect(endpoint == "https://cdn.proj.org/",
            "Endpoint should be the default PROJ CDN")
}

@Test func networkBridgeCustomEndpoint() throws {
    let ctx = proj_context_create()
    defer { proj_context_destroy(ctx) }

    let customEndpoint = "https://example.com/proj/"
    PROJNetworkBridge.enableNetworking(on: ctx!, endpoint: customEndpoint)

    let endpoint = String(cString: proj_context_get_url_endpoint(ctx))
    #expect(endpoint == customEndpoint,
            "Endpoint should match the custom value")
}

@Test func gridDiscoveryForSwissTransformation() throws {
    let ctx = proj_context_create()
    defer { proj_context_destroy(ctx) }

    // Enable networking so PROJ knows grids are potentially available
    PROJNetworkBridge.enableNetworking(on: ctx!)

    // Query which grids are needed for WGS84 3D -> Swiss LV95 + LN02 height
    let grids = PROJNetworkBridge.gridsUsed(
        context: ctx!,
        source: "EPSG:4979",
        target: "EPSG:2056+5728"
    )
    print("Grids required for EPSG:4979 -> EPSG:2056+5728:")
    for grid in grids {
        print("  - \(grid.shortName) (available: \(grid.available), url: \(grid.url))")
    }

    // There should be at least one grid (the Swiss geoid model)
    #expect(!grids.isEmpty, "Expected at least one grid for Swiss 3D transformation")

    // Verify the Swiss geoid grid is in the list
    let swissGrid = grids.first { $0.shortName.contains("chgeo") }
    #expect(swissGrid != nil, "Expected Swiss CHGeo geoid grid in the list")

    // Check that we can identify grids that need downloading
    let missingGrids = grids.filter { !$0.available }
    print("Missing grids that need downloading: \(missingGrids.count)")
    for grid in missingGrids {
        let needsDownload = PROJNetworkBridge.isDownloadNeeded(
            context: ctx!, for: grid.shortName
        )
        print("  - \(grid.shortName): download needed = \(needsDownload)")
    }
}

@Test func downloadAndUseSwissGeoidGrid() throws {
    let ctx = proj_context_create()
    defer { proj_context_destroy(ctx) }

    // Enable networking
    PROJNetworkBridge.enableNetworking(on: ctx!)

    // Create 3D transformation: WGS84 geographic 3D -> Swiss LV95 + LN02 height
    let transform = proj_create_crs_to_crs(
        ctx,
        "EPSG:4979",
        "EPSG:2056+5728",
        nil
    )
    #expect(transform != nil, "Failed to create 3D transformation")
    defer { proj_destroy(transform) }

    // Find missing grids and download them
    let grids = PROJNetworkBridge.gridsUsed(
        context: ctx!, source: "EPSG:4979", target: "EPSG:2056+5728"
    )
    for grid in grids where !grid.available {
        print("Downloading grid: \(grid.shortName)...")
        let success = PROJNetworkBridge.downloadFile(
            context: ctx!,
            urlOrFilename: grid.url.isEmpty ? grid.shortName : grid.url,
            progress: { pct in
                if pct.truncatingRemainder(dividingBy: 25) < 1 {
                    print("  Progress: \(Int(pct))%")
                }
                return true // continue downloading
            }
        )
        #expect(success, "Failed to download grid \(grid.shortName)")
    }

    // Now perform the transformation with the grid available
    let normalized = proj_normalize_for_visualization(ctx, transform)
    #expect(normalized != nil, "Failed to normalize transformation")
    defer { proj_destroy(normalized) }

    // Lausanne: lon=6.618, lat=46.532, ellipsoidal height=500m
    let coord = PJ_COORD(
        lpz: PJ_LPZ(lam: 6.6180459095579325, phi: 46.53234416429708, z: 500.0)
    )

    let result = proj_trans(normalized, PJ_FWD, coord)

    let easting = result.enu.e
    let northing = result.enu.n
    let height = result.enu.u

    print("WGS84 3D (46.5323, 6.6180, 500m) -> Swiss LV95+LN02:")
    print("  E=\(easting), N=\(northing), H=\(height)")

    // Verify horizontal coordinates are in expected Swiss range
    #expect(easting > 2_500_000 && easting < 2_600_000,
            "Easting \(easting) outside expected range")
    #expect(northing > 1_100_000 && northing < 1_200_000,
            "Northing \(northing) outside expected range")

    // The LN02 height should differ from ellipsoidal height due to geoid undulation.
    // Swiss geoid undulation in the Lausanne area is roughly 48-50m,
    // so LN02 height ≈ 500 - ~49 ≈ ~451m
    #expect(height > 400 && height < 500,
            "Height \(height) outside expected LN02 range (geoid correction should apply)")
    print("  Geoid undulation applied: ellipsoidal 500m -> LN02 \(height)m")
}

