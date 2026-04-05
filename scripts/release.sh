#!/bin/bash
set -euo pipefail

# ============================================================================
# release.sh — Build, package, and publish a SwiftPROJ release
#
# Usage:
#   ./scripts/release.sh <version> [--dry-run]
#
# Examples:
#   ./scripts/release.sh 0.1.0
#   ./scripts/release.sh 0.1.0 --dry-run
#
# The hosting platform (github/codeberg) is detected from git remote origin.
#
# Prerequisites:
#   GitHub:   'gh' CLI installed and authenticated
#   Codeberg: CODEBERG_TOKEN environment variable set
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_SWIFT="${PROJECT_ROOT}/Package.swift"
XCFRAMEWORK_DIR="${PROJECT_ROOT}/build/PROJ.xcframework"
ZIP_PATH="${PROJECT_ROOT}/build/PROJ.xcframework.zip"

DRY_RUN=false

# ============================================================================
# Helpers
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

run() {
    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

# ============================================================================
# Parse arguments
# ============================================================================

VERSION=""
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        -*)
            error "Unknown option: $arg"
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$arg"
            else
                error "Unexpected argument: $arg"
            fi
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [--dry-run]"
    echo ""
    echo "  version    Semantic version tag (e.g., 0.1.0)"
    echo "  --dry-run  Show what would happen without making changes"
    exit 1
fi

# ============================================================================
# Detect hosting platform from git remote
# ============================================================================

detect_platform() {
    local remote_url
    remote_url="$(git -C "${PROJECT_ROOT}" remote get-url origin 2>/dev/null || true)"

    if [ -z "$remote_url" ]; then
        error "No git remote 'origin' configured. Add one first:
  git remote add origin <url>"
    fi

    # Normalize SSH URLs to HTTPS for parsing
    local normalized
    normalized="$(echo "$remote_url" | sed -E \
        -e 's|^git@([^:]+):|https://\1/|' \
        -e 's|\.git$||')"

    local host
    host="$(echo "$normalized" | sed -E 's|https?://([^/]+)/.*|\1|')"

    local owner_repo
    owner_repo="$(echo "$normalized" | sed -E 's|https?://[^/]+/(.*)|\1|')"

    local owner repo
    owner="$(echo "$owner_repo" | cut -d/ -f1)"
    repo="$(echo "$owner_repo" | cut -d/ -f2)"

    case "$host" in
        github.com)
            PLATFORM="github"
            BASE_URL="https://github.com/${owner}/${repo}"
            ;;
        codeberg.org)
            PLATFORM="codeberg"
            BASE_URL="https://codeberg.org/${owner}/${repo}"
            API_URL="https://codeberg.org/api/v1/repos/${owner}/${repo}"
            ;;
        *)
            # Generic Gitea/Forgejo instance
            PLATFORM="gitea"
            BASE_URL="https://${host}/${owner}/${repo}"
            API_URL="https://${host}/api/v1/repos/${owner}/${repo}"
            ;;
    esac

    DOWNLOAD_URL="${BASE_URL}/releases/download/${VERSION}/PROJ.xcframework.zip"
    OWNER="$owner"
    REPO="$repo"

    echo "  Platform:     ${PLATFORM}"
    echo "  Remote:       ${remote_url}"
    echo "  Download URL: ${DOWNLOAD_URL}"
}

# ============================================================================
# Step 1: Validate
# ============================================================================

validate() {
    log "Validating..."

    if [ ! -d "$XCFRAMEWORK_DIR" ]; then
        error "XCFramework not found at ${XCFRAMEWORK_DIR}
Run ./scripts/build_xcframework.sh first."
    fi

    if git -C "${PROJECT_ROOT}" tag -l | grep -q "^${VERSION}$"; then
        error "Tag '${VERSION}' already exists"
    fi

    # Check for uncommitted changes (excluding Package.swift which we'll modify)
    local status
    status="$(git -C "${PROJECT_ROOT}" status --porcelain -- ':!Package.swift')"
    if [ -n "$status" ]; then
        echo "WARNING: Uncommitted changes detected (besides Package.swift):"
        echo "$status"
        echo ""
        if [ "$DRY_RUN" = false ]; then
            read -rp "Continue anyway? [y/N] " confirm
            if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                exit 1
            fi
        fi
    fi

    detect_platform
    echo "  Version:      ${VERSION}"
    echo "  All checks passed."
}

# ============================================================================
# Step 2: Zip the xcframework
# ============================================================================

zip_xcframework() {
    log "Zipping xcframework..."

    rm -f "$ZIP_PATH"
    (cd "${PROJECT_ROOT}/build" && zip -r -y "PROJ.xcframework.zip" "PROJ.xcframework")

    local size
    size="$(du -h "$ZIP_PATH" | cut -f1)"
    echo "  Created: ${ZIP_PATH} (${size})"
}

# ============================================================================
# Step 3: Compute checksum
# ============================================================================

compute_checksum() {
    log "Computing checksum..."

    CHECKSUM="$(swift package --package-path "${PROJECT_ROOT}" compute-checksum "$ZIP_PATH")"
    echo "  SHA256: ${CHECKSUM}"
}

# ============================================================================
# Step 4: Update Package.swift
# ============================================================================

update_package_swift() {
    log "Updating Package.swift..."

    # Update the release URL
    sed -i '' -E "s|let releaseURL = \"[^\"]*\"|let releaseURL = \"${DOWNLOAD_URL}\"|" "$PACKAGE_SWIFT"

    # Update the checksum
    sed -i '' -E "s|let releaseChecksum = \"[^\"]*\"|let releaseChecksum = \"${CHECKSUM}\"|" "$PACKAGE_SWIFT"

    echo "  URL:      ${DOWNLOAD_URL}"
    echo "  Checksum: ${CHECKSUM}"

    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo "  [dry-run] Package.swift changes (not applied):"
        git -C "${PROJECT_ROOT}" diff -- Package.swift 2>/dev/null || true
    fi
}

# ============================================================================
# Step 5: Commit and tag
# ============================================================================

commit_and_tag() {
    log "Committing and tagging..."

    run git -C "${PROJECT_ROOT}" add Package.swift
    run git -C "${PROJECT_ROOT}" commit -m "Release ${VERSION}"
    run git -C "${PROJECT_ROOT}" tag "${VERSION}"

    echo "  Committed and tagged ${VERSION}"
}

# ============================================================================
# Step 6: Create release and upload asset
# ============================================================================

create_release() {
    log "Creating release on ${PLATFORM}..."

    case "$PLATFORM" in
        github)
            create_github_release
            ;;
        codeberg|gitea)
            create_gitea_release
            ;;
    esac
}

create_github_release() {
    if ! command -v gh &>/dev/null; then
        error "'gh' CLI not found. Install: brew install gh"
    fi

    run gh release create "${VERSION}" \
        "${ZIP_PATH}" \
        --repo "${OWNER}/${REPO}" \
        --title "${VERSION}" \
        --notes "SwiftPROJ ${VERSION} — PROJ 9.8.0 xcframework for iOS/macOS (arm64)"

    echo "  Release created: ${BASE_URL}/releases/tag/${VERSION}"
}

create_gitea_release() {
    local token_var
    if [ "$PLATFORM" = "codeberg" ]; then
        token_var="CODEBERG_TOKEN"
    else
        token_var="GITEA_TOKEN"
    fi

    local token="${!token_var:-}"
    if [ -z "$token" ]; then
        error "${token_var} environment variable not set"
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] Would create release via ${API_URL}/releases"
        echo "  [dry-run] Would upload ${ZIP_PATH} as attachment"
        return
    fi

    # Create the release
    local release_response
    release_response="$(curl -s -X POST \
        -H "Authorization: token ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"tag_name\": \"${VERSION}\", \"name\": \"${VERSION}\", \"body\": \"SwiftPROJ ${VERSION} — PROJ 9.8.0 xcframework for iOS/macOS (arm64)\"}" \
        "${API_URL}/releases")"

    local release_id
    release_id="$(echo "$release_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)"

    if [ -z "$release_id" ]; then
        echo "  Release response: ${release_response}"
        error "Failed to create release. Check your token and permissions."
    fi

    # Upload the zip as an attachment
    curl -s -X POST \
        -H "Authorization: token ${token}" \
        -F "attachment=@${ZIP_PATH}" \
        "${API_URL}/releases/${release_id}/assets?name=PROJ.xcframework.zip" > /dev/null

    echo "  Release created: ${BASE_URL}/releases/tag/${VERSION}"
}

# ============================================================================
# Step 7: Push
# ============================================================================

push() {
    log "Pushing to remote..."

    run git -C "${PROJECT_ROOT}" push
    run git -C "${PROJECT_ROOT}" push --tags

    echo "  Pushed commits and tags."
}

# ============================================================================
# Main
# ============================================================================

main() {
    log "SwiftPROJ Release ${VERSION}"

    if [ "$DRY_RUN" = true ]; then
        echo "  *** DRY RUN — no changes will be made ***"
    fi

    validate
    zip_xcframework
    compute_checksum

    if [ "$DRY_RUN" = true ]; then
        # Show what would change but don't modify files
        log "Package.swift would be updated with:"
        echo "  URL:      ${DOWNLOAD_URL}"
        echo "  Checksum: ${CHECKSUM}"
        log "DRY RUN COMPLETE — no changes made"
        return
    fi

    update_package_swift
    commit_and_tag
    create_release
    push

    log "RELEASE COMPLETE"
    echo "  Version:  ${VERSION}"
    echo "  URL:      ${DOWNLOAD_URL}"
    echo "  Checksum: ${CHECKSUM}"
    echo ""
    echo "  Consumers can now add this package:"
    echo "    .package(url: \"${BASE_URL}.git\", from: \"${VERSION}\")"
}

main
