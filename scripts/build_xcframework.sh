#!/bin/bash
set -euo pipefail

# ============================================================================
# build_xcframework.sh
# Builds PROJ 9.8.0 (with libtiff dependency) as a .xcframework
# for iOS arm64, iOS Simulator arm64, and macOS arm64.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Configuration ---
PROJ_SOURCE_DIR="${PROJECT_ROOT}/PROJ"
BUILD_DIR="${PROJECT_ROOT}/build"
OUTPUT_DIR="${BUILD_DIR}/output"

LIBTIFF_VERSION="4.7.0"
LIBTIFF_URL="https://download.osgeo.org/libtiff/tiff-${LIBTIFF_VERSION}.tar.gz"
LIBTIFF_TARBALL="${BUILD_DIR}/tiff-${LIBTIFF_VERSION}.tar.gz"
LIBTIFF_SOURCE_DIR="${BUILD_DIR}/tiff-${LIBTIFF_VERSION}"

CMAKE_CMD=""
XCFRAMEWORK_OUTPUT="${BUILD_DIR}/PROJ.xcframework"

IOS_DEPLOYMENT_TARGET="16.0"
MACOS_DEPLOYMENT_TARGET="13.0"

PLATFORMS=("ios" "ios-simulator" "macos")

# ============================================================================
# Helper functions
# ============================================================================

log() {
    echo ""
    echo "===> $*"
    echo ""
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

check_prerequisites() {
    log "Checking prerequisites..."

    # Check for cmake
    if command -v cmake &>/dev/null; then
        CMAKE_CMD="cmake"
    elif [ -x "/opt/homebrew/bin/cmake" ]; then
        CMAKE_CMD="/opt/homebrew/bin/cmake"
    elif [ -x "/usr/local/bin/cmake" ]; then
        CMAKE_CMD="/usr/local/bin/cmake"
    else
        error "cmake not found. Install via: brew install cmake"
    fi

    # Check for Xcode command line tools
    if ! xcrun --find clang &>/dev/null; then
        error "Xcode command line tools not found. Run: xcode-select --install"
    fi

    # Check for sqlite3 (needed to build proj.db)
    if ! command -v sqlite3 &>/dev/null; then
        error "sqlite3 not found in PATH"
    fi

    # Check that PROJ submodule exists
    if [ ! -f "${PROJ_SOURCE_DIR}/CMakeLists.txt" ]; then
        error "PROJ submodule not found at ${PROJ_SOURCE_DIR}. Run: git submodule update --init"
    fi

    echo "  cmake: $(${CMAKE_CMD} --version | head -1)"
    echo "  sqlite3: $(which sqlite3)"
    echo "  clang: $(xcrun --find clang)"
    echo "  All prerequisites satisfied."
}

get_toolchain_file() {
    local platform="$1"
    echo "${SCRIPT_DIR}/toolchain-${platform}.cmake"
}

get_build_dir() {
    local component="$1"
    local platform="$2"
    echo "${BUILD_DIR}/${component}-${platform}"
}

get_install_dir() {
    local component="$1"
    local platform="$2"
    echo "${BUILD_DIR}/install/${component}-${platform}"
}

get_sdk_path() {
    local platform="$1"
    case "${platform}" in
        ios)
            xcrun --sdk iphoneos --show-sdk-path
            ;;
        ios-simulator)
            xcrun --sdk iphonesimulator --show-sdk-path
            ;;
        macos)
            xcrun --sdk macosx --show-sdk-path
            ;;
    esac
}

# ============================================================================
# Download libtiff
# ============================================================================

download_libtiff() {
    if [ -d "${LIBTIFF_SOURCE_DIR}" ]; then
        log "libtiff source already exists, skipping download"
        return 0
    fi

    log "Downloading libtiff ${LIBTIFF_VERSION}..."
    mkdir -p "${BUILD_DIR}"
    curl -L --fail --retry 3 -o "${LIBTIFF_TARBALL}" "${LIBTIFF_URL}"

    log "Extracting libtiff..."
    tar -xzf "${LIBTIFF_TARBALL}" -C "${BUILD_DIR}"

    if [ ! -d "${LIBTIFF_SOURCE_DIR}" ]; then
        error "Failed to extract libtiff. Expected directory: ${LIBTIFF_SOURCE_DIR}"
    fi

    log "libtiff source ready"
}

# ============================================================================
# Build libtiff (static) for one platform
# ============================================================================

build_libtiff() {
    local platform="$1"
    local build_dir install_dir toolchain_file

    build_dir="$(get_build_dir libtiff "${platform}")"
    install_dir="$(get_install_dir libtiff "${platform}")"
    toolchain_file="$(get_toolchain_file "${platform}")"

    log "Building libtiff (static) for ${platform}..."

    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    "${CMAKE_CMD}" -S "${LIBTIFF_SOURCE_DIR}" -B "${build_dir}" \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${install_dir}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -Dtiff-tools=OFF \
        -Dtiff-tests=OFF \
        -Dtiff-contrib=OFF \
        -Dtiff-docs=OFF \
        -Dtiff-deprecated=OFF \
        -Dtiff-install=ON \
        -Djpeg=OFF \
        -Djbig=OFF \
        -Dlerc=OFF \
        -Dlzma=OFF \
        -Dwebp=OFF \
        -Dzstd=OFF \
        -Dlibdeflate=OFF \
        -Dpixarlog=OFF \
        -Dzlib=ON \
        -Dcxx=OFF \
        -DCMAKE_C_VISIBILITY_PRESET=hidden

    "${CMAKE_CMD}" --build "${build_dir}" --config Release --parallel "$(sysctl -n hw.ncpu)"
    "${CMAKE_CMD}" --install "${build_dir}" --config Release

    log "libtiff for ${platform} installed to ${install_dir}"
}

# ============================================================================
# Build PROJ (dynamic) for one platform
# ============================================================================

build_proj() {
    local platform="$1"
    local build_dir install_dir tiff_install_dir toolchain_file sdk_path

    build_dir="$(get_build_dir proj "${platform}")"
    install_dir="$(get_install_dir proj "${platform}")"
    tiff_install_dir="$(get_install_dir libtiff "${platform}")"
    toolchain_file="$(get_toolchain_file "${platform}")"
    sdk_path="$(get_sdk_path "${platform}")"

    log "Building PROJ (dynamic) for ${platform}..."

    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    # Find the libtiff cmake config directory
    local tiff_cmake_dir="${tiff_install_dir}/lib/cmake/tiff"
    if [ ! -d "${tiff_cmake_dir}" ]; then
        error "libtiff cmake config not found at ${tiff_cmake_dir}. Build libtiff first."
    fi

    "${CMAKE_CMD}" -S "${PROJ_SOURCE_DIR}" -B "${build_dir}" \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${install_dir}" \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TESTING=OFF \
        -DBUILD_APPS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DENABLE_CURL=OFF \
        -DENABLE_TIFF=ON \
        -DEMBED_RESOURCE_FILES=ON \
        -DUSE_ONLY_EMBEDDED_RESOURCE_FILES=ON \
        -DEMBED_PROJ_DATA_PATH=OFF \
        -DNLOHMANN_JSON_ORIGIN=internal \
        -DTIFF_INCLUDE_DIR="${tiff_install_dir}/include" \
        -DTIFF_LIBRARY_RELEASE="${tiff_install_dir}/lib/libtiff.a" \
        -DTIFF_LIBRARY="${tiff_install_dir}/lib/libtiff.a" \
        -DSQLite3_INCLUDE_DIR="${sdk_path}/usr/include" \
        -DSQLite3_LIBRARY="${sdk_path}/usr/lib/libsqlite3.tbd" \
        -DEXE_SQLITE3="$(which sqlite3)" \
        -DCMAKE_INSTALL_NAME_DIR="@rpath" \
        -DCMAKE_SHARED_LINKER_FLAGS="-lz"

    "${CMAKE_CMD}" --build "${build_dir}" --config Release --parallel "$(sysctl -n hw.ncpu)"
    "${CMAKE_CMD}" --install "${build_dir}" --config Release

    log "PROJ for ${platform} installed to ${install_dir}"
}

# ============================================================================
# Create .framework structure for one platform
# ============================================================================

create_framework() {
    local platform="$1"
    local install_dir framework_dir

    install_dir="$(get_install_dir proj "${platform}")"
    framework_dir="${OUTPUT_DIR}/${platform}/PROJ.framework"

    log "Creating PROJ.framework for ${platform}..."

    rm -rf "${framework_dir}"
    mkdir -p "${framework_dir}/Headers"
    mkdir -p "${framework_dir}/Modules"

    # --- Find and copy the dylib ---
    local dylib_path=""
    # Look for the major-versioned symlink first (e.g., libproj.25.dylib)
    if [ -f "${install_dir}/lib/libproj.dylib" ]; then
        # Follow the symlink to get the actual file
        dylib_path="$(readlink -f "${install_dir}/lib/libproj.dylib" 2>/dev/null || realpath "${install_dir}/lib/libproj.dylib")"
    fi

    if [ -z "${dylib_path}" ] || [ ! -f "${dylib_path}" ]; then
        # Fallback: find any libproj dylib
        dylib_path="$(find "${install_dir}/lib" -name "libproj*.dylib" -not -type l | head -1)"
    fi

    if [ -z "${dylib_path}" ] || [ ! -f "${dylib_path}" ]; then
        error "Could not find libproj dylib in ${install_dir}/lib"
    fi

    cp "${dylib_path}" "${framework_dir}/PROJ"

    # --- Fix the install name ---
    install_name_tool -id "@rpath/PROJ.framework/PROJ" "${framework_dir}/PROJ"

    # --- Verify no unexpected dependencies ---
    echo "  Library dependencies for ${platform}:"
    otool -L "${framework_dir}/PROJ" | grep -v "PROJ:" | sed 's/^/    /'

    # --- Copy public C headers ---
    for header in proj.h proj_experimental.h proj_constants.h proj_symbol_rename.h geodesic.h; do
        if [ -f "${install_dir}/include/${header}" ]; then
            cp "${install_dir}/include/${header}" "${framework_dir}/Headers/"
        fi
    done

    # --- Create module.modulemap ---
    cat > "${framework_dir}/Modules/module.modulemap" <<'MODULEMAP'
framework module PROJ {
    header "proj.h"
    header "geodesic.h"
    header "proj_experimental.h"
    header "proj_constants.h"

    export *
}
MODULEMAP

    # --- Create Info.plist ---
    local bundle_version="9.8.0"
    local min_os_version platform_name

    case "${platform}" in
        ios)
            min_os_version="${IOS_DEPLOYMENT_TARGET}"
            platform_name="iPhoneOS"
            ;;
        ios-simulator)
            min_os_version="${IOS_DEPLOYMENT_TARGET}"
            platform_name="iPhoneSimulator"
            ;;
        macos)
            min_os_version="${MACOS_DEPLOYMENT_TARGET}"
            platform_name="MacOSX"
            ;;
    esac

    cat > "${framework_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>PROJ</string>
    <key>CFBundleIdentifier</key>
    <string>org.osgeo.proj</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PROJ</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>${bundle_version}</string>
    <key>CFBundleVersion</key>
    <string>${bundle_version}</string>
    <key>MinimumOSVersion</key>
    <string>${min_os_version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${platform_name}</string>
    </array>
</dict>
</plist>
PLIST

    log "Framework created at ${framework_dir}"
}

# ============================================================================
# Create XCFramework
# ============================================================================

create_xcframework() {
    log "Creating PROJ.xcframework..."

    rm -rf "${XCFRAMEWORK_OUTPUT}"

    xcodebuild -create-xcframework \
        -framework "${OUTPUT_DIR}/ios/PROJ.framework" \
        -framework "${OUTPUT_DIR}/ios-simulator/PROJ.framework" \
        -framework "${OUTPUT_DIR}/macos/PROJ.framework" \
        -output "${XCFRAMEWORK_OUTPUT}"

    log "XCFramework created at ${XCFRAMEWORK_OUTPUT}"
}

# ============================================================================
# Main
# ============================================================================

main() {
    log "Starting PROJ XCFramework build"
    echo "  Project root: ${PROJECT_ROOT}"
    echo "  Build dir:    ${BUILD_DIR}"

    check_prerequisites

    # Clean output directory
    rm -rf "${OUTPUT_DIR}"
    mkdir -p "${OUTPUT_DIR}"

    # Step 1: Download libtiff source
    download_libtiff

    # Step 2: Build libtiff (static) for all platforms
    for platform in "${PLATFORMS[@]}"; do
        build_libtiff "${platform}"
    done

    # Step 3: Build PROJ (dynamic) for all platforms
    for platform in "${PLATFORMS[@]}"; do
        build_proj "${platform}"
    done

    # Step 4: Create .framework for each platform
    for platform in "${PLATFORMS[@]}"; do
        create_framework "${platform}"
    done

    # Step 5: Bundle into xcframework
    create_xcframework

    log "BUILD COMPLETE"
    echo "  Output: ${XCFRAMEWORK_OUTPUT}"
    echo ""
    echo "  Next steps:"
    echo "    1. Update Package.swift to add the binary target"
    echo "    2. Import PROJ in your Swift code"
}

main "$@"
