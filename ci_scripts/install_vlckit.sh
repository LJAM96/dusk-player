#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build"
IOS_FRAMEWORK_DIR="${ROOT_DIR}/Frameworks/MobileVLCKit.xcframework"
TVOS_FRAMEWORK_DIR="${ROOT_DIR}/Frameworks/TVVLCKit.xcframework"
LICENSE_PATH="${ROOT_DIR}/Frameworks/VLCKit-LICENSE.txt"
VERSION_PATH="${ROOT_DIR}/Frameworks/VLCKit-VERSION.txt"
EXTRACT_DIR="${BUILD_DIR}/vlckit-prebuilt"

# Installs the pinned VLCKit binaries into Frameworks/. The xcframeworks are not
# committed to git: CI fetches them via ci_scripts/ci_post_clone.sh, and this
# script must be run once locally after cloning (and to refresh the pinned
# version). It is idempotent — a no-op when the expected version is already in
# place (see has_expected_vlckit).
#
# Dusk vendors its OWN build of the stable MobileVLCKit/TVVLCKit line
# (VLCKit 3.7.3, libvlc 3.0.23) with the patches in ci_scripts/vlc-patches/:
# ffmpeg's TrueHD/MLP decoders re-enabled and tvOS multichannel output fixed.
# ci_scripts/build_vlckit.sh builds the archives from source (arm64 device +
# arm64 simulator slices only); they are published as assets of the GitHub
# release vlckit-<version> and pinned here by name and checksum. See
# docs/development-workflow.md → "VLCKit build".
#
# Shipping the TrueHD decoder is a deliberate licensing decision; see
# docs/playback.md → "Dolby TrueHD decoding".
VLCKIT_VERSION="3.7.3-dusk1"
DOWNLOAD_BASE_URL="https://github.com/marvinvr/dusk-player/releases/download/vlckit-${VLCKIT_VERSION}"
IOS_ARCHIVE="MobileVLCKit-${VLCKIT_VERSION}.tar.xz"
IOS_ARCHIVE_SHA256="430058379927262a22331c2a24f36904ccb3d055baa73ce4a90bcab2b68910a8"
TVOS_ARCHIVE="TVVLCKit-${VLCKIT_VERSION}.tar.xz"
TVOS_ARCHIVE_SHA256="dd1f6964a6d5c30bb3382042241c15c8dcbe64b629283f1f883b73f0a3287d2e"

# Optional: point at a directory that already holds the archives (matching
# names + checksums) to skip the download, e.g. build_vlckit.sh's output:
#   DUSK_VLCKIT_CACHE_DIR=.build/vlckit/out ci_scripts/install_vlckit.sh
CACHE_DIR="${DUSK_VLCKIT_CACHE_DIR:-}"

cleanup() {
    local exit_code=$?
    rm -rf "${EXTRACT_DIR}"
    rmdir "${BUILD_DIR}" >/dev/null 2>&1 || true
    exit "${exit_code}"
}

trap cleanup EXIT

# The build stamp build_vlckit.sh writes into a framework slice's Info.plist.
framework_build() {
    /usr/libexec/PlistBuddy -c "Print :DuskVLCKitBuild" "$1/Info.plist" 2>/dev/null || true
}

# Checks the installed binaries themselves, not Frameworks/VLCKit-VERSION.txt:
# that file is tracked in git, so it already names the new version right after
# a pull, while the git-ignored frameworks (and the copies scripts/testflight.sh
# takes from the checkout) can still be an older or stock build.
has_expected_vlckit() {
    [ "$(framework_build "${IOS_FRAMEWORK_DIR}/ios-arm64/MobileVLCKit.framework")" = "${VLCKIT_VERSION}" ] &&
    [ "$(framework_build "${IOS_FRAMEWORK_DIR}/ios-arm64-simulator/MobileVLCKit.framework")" = "${VLCKIT_VERSION}" ] &&
    [ "$(framework_build "${TVOS_FRAMEWORK_DIR}/tvos-arm64/TVVLCKit.framework")" = "${VLCKIT_VERSION}" ] &&
    [ "$(framework_build "${TVOS_FRAMEWORK_DIR}/tvos-arm64-simulator/TVVLCKit.framework")" = "${VLCKIT_VERSION}" ]
}

verify_sha256() {
    local file_path="$1"
    local expected="$2"
    local actual

    actual="$(shasum -a 256 "${file_path}" | awk '{print $1}')"
    if [ "${actual}" != "${expected}" ]; then
        echo "ERROR: checksum mismatch for ${file_path}" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        return 1
    fi
}

fetch_archive() {
    local archive_name="$1"
    local expected_sha="$2"
    local destination="${EXTRACT_DIR}/${archive_name}"

    if [ -n "${CACHE_DIR}" ] && [ -f "${CACHE_DIR}/${archive_name}" ]; then
        cp "${CACHE_DIR}/${archive_name}" "${destination}"
    else
        # The two archives are large enough that transient CDN/TLS resets are
        # common on Xcode Cloud. curl's plain --retry only covers a narrow set
        # of errors and does not include the observed CURLE_SSL_CONNECT_ERROR.
        # Retry every transfer failure and resume the partial archive rather
        # than restarting hundreds of megabytes from zero.
        curl \
            --fail \
            --location \
            --retry 8 \
            --retry-all-errors \
            --retry-delay 3 \
            --continue-at - \
            --output "${destination}" \
            "${DOWNLOAD_BASE_URL}/${archive_name}"
    fi
    verify_sha256 "${destination}" "${expected_sha}"
}

remove_debug_symbol_paths() {
    local framework_dir="$1"
    local plist_path="${framework_dir}/Info.plist"
    local index=0

    while /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:${index}" "${plist_path}" >/dev/null 2>&1; do
        /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:${index}:DebugSymbolsPath" "${plist_path}" >/dev/null 2>&1 || true
        index=$((index + 1))
    done
}

install_framework() {
    local source_dir="$1"
    local destination_dir="$2"

    rm -rf "${destination_dir}"
    cp -R "${source_dir}" "${destination_dir}"
    find "${destination_dir}" -type d -name dSYMs -prune -exec rm -rf {} +
    remove_debug_symbol_paths "${destination_dir}"
}

if has_expected_vlckit; then
    echo "Pinned MobileVLCKit/TVVLCKit ${VLCKIT_VERSION} frameworks already present."
    exit 0
fi

echo "Installing Dusk's MobileVLCKit/TVVLCKit ${VLCKIT_VERSION}..."

rm -rf "${EXTRACT_DIR}"
mkdir -p "${ROOT_DIR}/Frameworks" "${EXTRACT_DIR}"

fetch_archive "${IOS_ARCHIVE}" "${IOS_ARCHIVE_SHA256}"
fetch_archive "${TVOS_ARCHIVE}" "${TVOS_ARCHIVE_SHA256}"

tar -xf "${EXTRACT_DIR}/${IOS_ARCHIVE}" -C "${EXTRACT_DIR}"
tar -xf "${EXTRACT_DIR}/${TVOS_ARCHIVE}" -C "${EXTRACT_DIR}"

install_framework "${EXTRACT_DIR}/MobileVLCKit-binary/MobileVLCKit.xcframework" "${IOS_FRAMEWORK_DIR}"
install_framework "${EXTRACT_DIR}/TVVLCKit-binary/TVVLCKit.xcframework" "${TVOS_FRAMEWORK_DIR}"

if ! has_expected_vlckit; then
    echo "ERROR: the installed frameworks are not stamped as Dusk VLCKit ${VLCKIT_VERSION}." >&2
    exit 1
fi

cp "${EXTRACT_DIR}/MobileVLCKit-binary/COPYING.txt" "${LICENSE_PATH}"
printf '%s\n' "${VLCKIT_VERSION}" > "${VERSION_PATH}"

echo "Pinned MobileVLCKit installed at ${IOS_FRAMEWORK_DIR}."
echo "Pinned TVVLCKit installed at ${TVOS_FRAMEWORK_DIR}."
