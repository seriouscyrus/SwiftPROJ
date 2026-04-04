import Testing
import PROJ

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
