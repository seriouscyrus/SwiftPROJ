import Foundation
import PROJ

// MARK: - Response Box

/// Thread-safe container for URLSession completion handler results.
/// Avoids Swift 6 concurrency warnings from mutating captured vars in @Sendable closures.
private final class ResponseBox: @unchecked Sendable {
    var data: Data?
    var headers: [String: String] = [:]
    var errorMessage: String?
}

// MARK: - Network Handle

/// Wraps per-connection state for PROJ network callbacks.
/// Each open URL gets its own handle, bridged to C as an opaque PROJ_NETWORK_HANDLE*.
private final class NetworkHandle: @unchecked Sendable {
    let url: String
    let session: URLSession
    var headers: [String: String] = [:]
    /// Holds the last returned header value as a C string. Freed on dealloc or next call.
    var lastHeaderCString: UnsafeMutablePointer<CChar>?

    init(url: String, session: URLSession) {
        self.url = url
        self.session = session
    }

    deinit {
        lastHeaderCString?.deallocate()
    }

    /// Perform a synchronous HTTP range request and store response headers.
    func fetchRange(offset: UInt64, size: Int, buffer: UnsafeMutableRawPointer,
                    errorBuffer: UnsafeMutablePointer<CChar>?, errorBufferSize: Int) -> Int {
        guard let requestURL = URL(string: url) else {
            writeError("Invalid URL: \(url)", to: errorBuffer, maxSize: errorBufferSize)
            return 0
        }

        var request = URLRequest(url: requestURL)
        let endByte = offset + UInt64(size) - 1
        request.setValue("bytes=\(offset)-\(endByte)", forHTTPHeaderField: "Range")

        let semaphore = DispatchSemaphore(value: 0)
        let result = ResponseBox()

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                result.errorMessage = error.localizedDescription
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                result.errorMessage = "Non-HTTP response"
                return
            }

            // Accept 200 (full content) and 206 (partial content)
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
                result.errorMessage = "HTTP \(httpResponse.statusCode)"
                return
            }

            // Store all response headers (lowercased keys for case-insensitive lookup)
            for (key, value) in httpResponse.allHeaderFields {
                result.headers["\(key)".lowercased()] = "\(value)"
            }

            result.data = data
        }
        task.resume()
        semaphore.wait()

        if let errorMessage = result.errorMessage {
            writeError(errorMessage, to: errorBuffer, maxSize: errorBufferSize)
            return 0
        }

        guard let data = result.data else {
            writeError("No data received", to: errorBuffer, maxSize: errorBufferSize)
            return 0
        }

        self.headers = result.headers

        let bytesToCopy = min(data.count, size)
        data.withUnsafeBytes { rawBuffer in
            buffer.copyMemory(from: rawBuffer.baseAddress!, byteCount: bytesToCopy)
        }
        return bytesToCopy
    }

    private func writeError(_ message: String, to buffer: UnsafeMutablePointer<CChar>?,
                            maxSize: Int) {
        guard let buffer = buffer, maxSize > 0 else { return }
        message.withCString { src in
            let len = min(strlen(src), maxSize - 1)
            memcpy(buffer, src, len)
            buffer[len] = 0
        }
    }
}

// MARK: - C Callback Functions

/// Called when PROJ wants to open a network resource.
private func networkOpen(
    _ ctx: OpaquePointer?,
    _ url: UnsafePointer<CChar>?,
    _ offset: UInt64,
    _ sizeToRead: Int,
    _ buffer: UnsafeMutableRawPointer?,
    _ outSizeRead: UnsafeMutablePointer<Int>?,
    _ errorStringMaxSize: Int,
    _ outErrorString: UnsafeMutablePointer<CChar>?,
    _ userData: UnsafeMutableRawPointer?
) -> OpaquePointer? {
    guard let url = url, let buffer = buffer, let outSizeRead = outSizeRead else {
        return nil
    }

    let urlString = String(cString: url)
    let session = URLSession.shared
    let handle = NetworkHandle(url: urlString, session: session)

    let bytesRead = handle.fetchRange(
        offset: offset,
        size: sizeToRead,
        buffer: buffer,
        errorBuffer: outErrorString,
        errorBufferSize: errorStringMaxSize
    )

    if bytesRead == 0 {
        return nil
    }

    outSizeRead.pointee = bytesRead

    // Return a retained opaque pointer — PROJ will pass this back to us
    let opaqueHandle = Unmanaged.passRetained(handle).toOpaque()
    return OpaquePointer(opaqueHandle)
}

/// Called when PROJ is done with a network handle.
private func networkClose(
    _ ctx: OpaquePointer?,
    _ handle: OpaquePointer?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let handle = handle else { return }
    // Release the retained handle
    Unmanaged<NetworkHandle>.fromOpaque(UnsafeRawPointer(handle)).release()
}

/// Called when PROJ needs an HTTP header value from the last response.
private func networkGetHeaderValue(
    _ ctx: OpaquePointer?,
    _ handle: OpaquePointer?,
    _ headerName: UnsafePointer<CChar>?,
    _ userData: UnsafeMutableRawPointer?
) -> UnsafePointer<CChar>? {
    guard let handle = handle, let headerName = headerName else { return nil }

    let networkHandle = Unmanaged<NetworkHandle>.fromOpaque(
        UnsafeRawPointer(handle)
    ).takeUnretainedValue()

    let name = String(cString: headerName).lowercased()
    guard let value = networkHandle.headers[name] else { return nil }

    // Free the previous value and store a new strdup'd copy
    networkHandle.lastHeaderCString?.deallocate()
    networkHandle.lastHeaderCString = strdup(value)
    return UnsafePointer(networkHandle.lastHeaderCString)
}

/// Called for subsequent byte-range reads on an already-opened handle.
private func networkReadRange(
    _ ctx: OpaquePointer?,
    _ handle: OpaquePointer?,
    _ offset: UInt64,
    _ sizeToRead: Int,
    _ buffer: UnsafeMutableRawPointer?,
    _ errorStringMaxSize: Int,
    _ outErrorString: UnsafeMutablePointer<CChar>?,
    _ userData: UnsafeMutableRawPointer?
) -> Int {
    guard let handle = handle, let buffer = buffer else { return 0 }

    let networkHandle = Unmanaged<NetworkHandle>.fromOpaque(
        UnsafeRawPointer(handle)
    ).takeUnretainedValue()

    return networkHandle.fetchRange(
        offset: offset,
        size: sizeToRead,
        buffer: buffer,
        errorBuffer: outErrorString,
        errorBufferSize: errorStringMaxSize
    )
}

// MARK: - Grid Info

/// Information about a grid file required by a coordinate operation.
public struct PROJGridInfo: Sendable {
    /// Short name of the grid file (e.g., "ch_swisstopo_CHENyx06a.tif").
    public let shortName: String
    /// Full name / path if available locally.
    public let fullName: String
    /// Package name the grid belongs to, if any.
    public let packageName: String
    /// URL to download the grid file from.
    public let url: String
    /// Whether the grid can be downloaded directly (vs. requiring a package download).
    public let directDownload: Bool
    /// Whether the grid is available under an open license.
    public let openLicense: Bool
    /// Whether the grid is currently available (already downloaded or embedded).
    public let available: Bool
}

// MARK: - Public API

/// Bridges PROJ's network callbacks to Swift's URLSession.
public enum PROJNetworkBridge {

    /// Enable network access on a PROJ context using URLSession-based callbacks.
    ///
    /// After calling this, PROJ will use URLSession to download grid files
    /// from the configured CDN endpoint on demand.
    ///
    /// - Parameters:
    ///   - context: A PROJ context created with `proj_context_create()`.
    ///   - endpoint: The CDN URL to fetch grid files from. Defaults to PROJ's official CDN.
    public static func enableNetworking(
        on context: OpaquePointer,
        endpoint: String = "https://cdn.proj.org/"
    ) {
        proj_context_set_network_callbacks(
            context,
            networkOpen,
            networkClose,
            networkGetHeaderValue,
            networkReadRange,
            nil
        )

        proj_context_set_enable_network(context, 1)
        proj_context_set_url_endpoint(context, endpoint)
    }

    /// Query which grid files are needed to transform between two CRS.
    ///
    /// Uses PROJ's operation factory to enumerate all candidate operations
    /// for the given source and target CRS, then collects grid requirements
    /// from each. Duplicate grid names are removed.
    ///
    /// - Parameters:
    ///   - context: A PROJ context.
    ///   - source: Source CRS identifier (e.g., "EPSG:4979").
    ///   - target: Target CRS identifier (e.g., "EPSG:2056+5728").
    /// - Returns: An array of grid info structs describing each required grid.
    public static func gridsUsed(
        context: OpaquePointer,
        source: String,
        target: String
    ) -> [PROJGridInfo] {
        guard let sourceCRS = proj_create(context, source) else { return [] }
        defer { proj_destroy(sourceCRS) }
        guard let targetCRS = proj_create(context, target) else { return [] }
        defer { proj_destroy(targetCRS) }

        guard let factoryCtx = proj_create_operation_factory_context(context, nil) else {
            return []
        }
        defer { proj_operation_factory_context_destroy(factoryCtx) }

        // Include operations even if their grids aren't locally available
        proj_operation_factory_context_set_grid_availability_use(
            context, factoryCtx, PROJ_GRID_AVAILABILITY_IGNORED
        )

        guard let opList = proj_create_operations(
            context, sourceCRS, targetCRS, factoryCtx
        ) else { return [] }
        defer { proj_list_destroy(opList) }

        let opCount = proj_list_get_count(opList)
        var seen = Set<String>()
        var grids: [PROJGridInfo] = []

        for i in 0..<opCount {
            guard let op = proj_list_get(context, opList, Int32(i)) else { continue }
            defer { proj_destroy(op) }

            for info in gridsForOperation(op, context: context) {
                if seen.insert(info.shortName).inserted {
                    grids.append(info)
                }
            }
        }

        return grids
    }

    /// Extract grid info from a coordinate operation, handling concatenated operations.
    private static func gridsForOperation(
        _ operation: OpaquePointer,
        context: OpaquePointer
    ) -> [PROJGridInfo] {
        var grids: [PROJGridInfo] = []

        let objType = proj_get_type(operation)
        if objType == PJ_TYPE_CONCATENATED_OPERATION {
            let stepCount = proj_concatoperation_get_step_count(context, operation)
            for stepIdx in 0..<stepCount {
                guard let step = proj_concatoperation_get_step(
                    context, operation, Int32(stepIdx)
                ) else { continue }
                defer { proj_destroy(step) }
                grids.append(contentsOf: gridsForSingleStep(step, context: context))
            }
        } else {
            grids = gridsForSingleStep(operation, context: context)
        }

        return grids
    }

    /// Extract grid info from a single (non-concatenated) coordinate operation step.
    private static func gridsForSingleStep(
        _ operation: OpaquePointer,
        context: OpaquePointer
    ) -> [PROJGridInfo] {
        let count = proj_coordoperation_get_grid_used_count(context, operation)
        guard count > 0 else { return [] }

        var grids: [PROJGridInfo] = []
        for i in 0..<count {
            var shortName: UnsafePointer<CChar>?
            var fullName: UnsafePointer<CChar>?
            var packageName: UnsafePointer<CChar>?
            var url: UnsafePointer<CChar>?
            var directDownload: Int32 = 0
            var openLicense: Int32 = 0
            var available: Int32 = 0

            let ok = proj_coordoperation_get_grid_used(
                context, operation, Int32(i),
                &shortName, &fullName, &packageName, &url,
                &directDownload, &openLicense, &available
            )
            guard ok != 0 else { continue }

            grids.append(PROJGridInfo(
                shortName: shortName.map { String(cString: $0) } ?? "",
                fullName: fullName.map { String(cString: $0) } ?? "",
                packageName: packageName.map { String(cString: $0) } ?? "",
                url: url.map { String(cString: $0) } ?? "",
                directDownload: directDownload != 0,
                openLicense: openLicense != 0,
                available: available != 0
            ))
        }
        return grids
    }

    /// Check whether a grid file needs to be downloaded.
    ///
    /// - Parameters:
    ///   - context: A PROJ context with networking enabled.
    ///   - urlOrFilename: The grid URL or short filename.
    ///   - ignoreTTL: If true, ignores the cache TTL and always checks.
    /// - Returns: `true` if the file needs to be downloaded.
    public static func isDownloadNeeded(
        context: OpaquePointer,
        for urlOrFilename: String,
        ignoreTTL: Bool = false
    ) -> Bool {
        return proj_is_download_needed(context, urlOrFilename, ignoreTTL ? 1 : 0) != 0
    }

    /// Download a grid file to the user-writable directory.
    ///
    /// Networking must be enabled on the context before calling this.
    /// The download uses PROJ's built-in download mechanism which calls
    /// our URLSession-based network callbacks.
    ///
    /// - Parameters:
    ///   - context: A PROJ context with networking enabled.
    ///   - urlOrFilename: The grid URL or short filename to download.
    ///   - ignoreTTL: If true, re-downloads even if a cached copy exists within TTL.
    ///   - progress: Optional callback receiving download progress (0.0 to 1.0).
    ///               Return `false` from the callback to cancel the download.
    /// - Returns: `true` if the download succeeded.
    public static func downloadFile(
        context: OpaquePointer,
        urlOrFilename: String,
        ignoreTTL: Bool = false,
        progress: ((Double) -> Bool)? = nil
    ) -> Bool {
        if let progress = progress {
            // Box the closure so we can pass it through C void* user_data
            let boxed = ProgressBox(callback: progress)
            let userData = Unmanaged.passRetained(boxed).toOpaque()
            let result = proj_download_file(
                context, urlOrFilename, ignoreTTL ? 1 : 0,
                { _, pct, userData in
                    guard let userData = userData else { return 1 }
                    let box = Unmanaged<ProgressBox>.fromOpaque(userData)
                        .takeUnretainedValue()
                    return box.callback(pct) ? 1 : 0
                },
                userData
            )
            Unmanaged<ProgressBox>.fromOpaque(userData).release()
            return result != 0
        } else {
            return proj_download_file(
                context, urlOrFilename, ignoreTTL ? 1 : 0, nil, nil
            ) != 0
        }
    }
}

/// Boxes a Swift closure for passing through C void* user_data.
private final class ProgressBox: @unchecked Sendable {
    let callback: (Double) -> Bool
    init(callback: @escaping (Double) -> Bool) {
        self.callback = callback
    }
}
