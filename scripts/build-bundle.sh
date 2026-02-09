#!/bin/bash
#
# build-bundle.sh - Download dependencies and build the ViaVoice TTS bundle
#
# This script:
# 1. Downloads ViaVoice RTK and SDK from archive.org
# 2. Extracts the RPMs
# 3. Downloads ancient libstdc++ that ViaVoice needs
# 4. Builds the speech-dispatcher module
# 5. Packages everything into a self-contained bundle
#
# NOTE: We do NOT bundle system libs (libc, pthread, etc.) - only ViaVoice-specific libs.
# The module binary uses the target system's libc for compatibility.
#

set -euo pipefail

# --- Output helpers (color suppressed when not on a terminal) ---
if [[ -t 2 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

info() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() { echo -e "${BLUE}==>${NC} $*" >&2; }

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DEPS_DIR="$ROOT_DIR/deps"
BUILD_DIR="$ROOT_DIR/build"
BUNDLE_DIR="$ROOT_DIR/dist/viavoice-bundle"
VIAVOICE_ROOT="$DEPS_DIR/viavoice-root"

# --- Download URLs ---
VIAVOICE_BASE_URL="https://archive.org/download/mandrake-7.2-power-pack/Mandrake%207.2%20PowerPack%20CD%2004%20of%2007.iso/IBM-ViaVoice-SDK%2Ftar"
VIAVOICE_RTK_URL="${VIAVOICE_BASE_URL}/viavoice_tts_rtk_5.tar"
VIAVOICE_SDK_URL="${VIAVOICE_BASE_URL}/viavoice_tts_sdk_5.tar"
LIBSTDCPP_URL="https://archive.debian.org/debian/pool/main/g/gcc-2.95/libstdc++2.10-glibc2.2_2.95.4-27_i386.deb"

# --- SHA256 checksums ---
RTK_SHA256="2cd5069a24b409862a88c4a086fbe03147e9f307541f501ba96dd37d6f854651"
SDK_SHA256="c03911146ee7faf0bd15fff05bed32516eeef2b2e79fe0a7d744aed002c4db9b"
LIBSTDCPP_SHA256="236ed073aa04d4d704d1664eb4bfc2d32f0c47c30f6c0fc5c7d62a4a03fa7317"

# --- Argument parsing ---
SKIP_VERIFY=false

for arg in "$@"; do
    case "$arg" in
        --skip-verify)  SKIP_VERIFY=true ;;
        --help|-h)
            echo "Usage: build-bundle.sh [--skip-verify] [--help]"
            echo ""
            echo "  --skip-verify  Skip SHA256 checksum verification"
            echo "  --help         Show this help message"
            exit 0
            ;;
        *)  die "Unknown option: $arg (try --help)" ;;
    esac
done

# --- Cleanup trap ---
CLEANUP_DIRS=()

cleanup() {
    for dir in "${CLEANUP_DIRS[@]}"; do
        rm -rf "$dir" 2>/dev/null || true
    done
}
trap cleanup EXIT

# --- Helper: download and verify ---
download_and_verify() {
    local url="$1" dest="$2" expected_sha="$3" label="$4"

    if [[ -f "$dest" ]]; then
        info "Using cached $label"
    else
        info "Downloading $label..."
        curl -fSL -o "$dest" "$url" || die "Failed to download $label from $url"
    fi

    if [[ "$SKIP_VERIFY" == true ]]; then
        warn "Skipping checksum verification for $label (--skip-verify)"
        return
    fi

    local actual_sha
    actual_sha=$(sha256sum "$dest" | cut -d' ' -f1)
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        die "Checksum mismatch for $label
  Expected: $expected_sha
  Actual:   $actual_sha
  File:     $dest
Use --skip-verify to bypass (for development only)"
    fi
    info "Checksum OK: $label"
}

# --- Check build dependencies ---
check_build_deps() {
    step "Checking build dependencies..."

    local missing=()
    gcc -m32 -x c -c -o /dev/null /dev/null 2>/dev/null || missing+=("gcc-multilib (gcc -m32)")
    command -v curl   &>/dev/null || missing+=("curl")
    command -v rpm2cpio &>/dev/null || missing+=("rpm2cpio")
    command -v cpio   &>/dev/null || missing+=("cpio")
    command -v ar     &>/dev/null || missing+=("binutils (ar)")
    command -v make   &>/dev/null || missing+=("make")

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing build dependencies: ${missing[*]}
Install with: sudo apt install gcc-multilib curl rpm2cpio cpio binutils make"
    fi
    info "All build dependencies found"
}

# --- Download all dependencies ---
download_all() {
    step "Downloading ViaVoice packages..."

    mkdir -p "$DEPS_DIR/downloads" "$DEPS_DIR/debs"

    download_and_verify "$VIAVOICE_RTK_URL" "$DEPS_DIR/downloads/viavoice_tts_rtk_5.tar" "$RTK_SHA256" "ViaVoice RTK"
    download_and_verify "$VIAVOICE_SDK_URL" "$DEPS_DIR/downloads/viavoice_tts_sdk_5.tar" "$SDK_SHA256" "ViaVoice SDK"
    download_and_verify "$LIBSTDCPP_URL"    "$DEPS_DIR/debs/libstdc++2.10.deb"           "$LIBSTDCPP_SHA256" "libstdc++2.10"
}

# --- Extract ViaVoice RPMs ---
extract_viavoice_rpms() {
    step "Extracting ViaVoice packages..."

    local rtk_tar="$DEPS_DIR/downloads/viavoice_tts_rtk_5.tar"
    local sdk_tar="$DEPS_DIR/downloads/viavoice_tts_sdk_5.tar"
    local rtk_tmp="$DEPS_DIR/rtk-tmp"
    local sdk_tmp="$DEPS_DIR/sdk-tmp"

    mkdir -p "$VIAVOICE_ROOT"

    # Track temp dirs for cleanup
    CLEANUP_DIRS+=("$rtk_tmp" "$sdk_tmp")

    # Extract RTK
    mkdir -p "$rtk_tmp"
    tar -xf "$rtk_tar" -C "$rtk_tmp" || die "Failed to extract RTK tarball"
    local rtk_rpm
    rtk_rpm=$(find "$rtk_tmp" -name "*.rpm" -type f | head -1)
    [[ -n "$rtk_rpm" ]] || die "No RPM found in RTK tarball"
    info "Extracting RTK RPM: $(basename "$rtk_rpm")"
    (cd "$VIAVOICE_ROOT" && rpm2cpio "$rtk_rpm" | cpio -idm) || die "Failed to extract RTK RPM"

    # Extract SDK
    mkdir -p "$sdk_tmp"
    tar -xf "$sdk_tar" -C "$sdk_tmp" || die "Failed to extract SDK tarball"
    local sdk_rpm
    sdk_rpm=$(find "$sdk_tmp" -name "*.rpm" -type f | head -1)
    [[ -n "$sdk_rpm" ]] || die "No RPM found in SDK tarball"
    info "Extracting SDK RPM: $(basename "$sdk_rpm")"
    (cd "$VIAVOICE_ROOT" && rpm2cpio "$sdk_rpm" | cpio -idm) || die "Failed to extract SDK RPM"

    # Verify expected files exist
    [[ -f "$VIAVOICE_ROOT/usr/lib/libibmeci50.so" ]] || die "RTK extraction failed — libibmeci50.so not found"
    [[ -f "$VIAVOICE_ROOT/usr/lib/enu50.so" ]]       || die "RTK extraction failed — enu50.so not found"
    [[ -f "$VIAVOICE_ROOT/usr/lib/ViaVoiceTTS/bin/inigen" ]] || die "RTK extraction failed — inigen not found"

    info "ViaVoice extracted: libibmeci50.so, enu50.so, inigen"

    # Clean up temp dirs now (remove from cleanup list)
    rm -rf "$rtk_tmp" "$sdk_tmp"
    CLEANUP_DIRS=()
}

# --- Extract libstdc++ from deb ---
extract_libstdcpp() {
    step "Extracting ancient libstdc++ (required by ViaVoice)..."

    local deb="$DEPS_DIR/debs/libstdc++2.10.deb"
    local extract_dir="$DEPS_DIR/debs/libstdc++_extract"

    CLEANUP_DIRS+=("$extract_dir")

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    # ar x extracts control.tar.* and data.tar.* from the deb
    (cd "$extract_dir" && ar x "$deb") || die "Failed to extract deb with ar"

    # Find data.tar (could be .gz, .xz, .bz2, .zst)
    local data_tar
    data_tar=$(find "$extract_dir" -maxdepth 1 -name 'data.tar.*' -type f | head -1)
    [[ -n "$data_tar" ]] || die "No data.tar.* found in deb"

    # tar auto-detects compression
    tar xf "$data_tar" -C "$extract_dir" || die "Failed to extract $data_tar"

    # Find the libstdc++ shared object
    local found
    found=$(find "$extract_dir" -name 'libstdc++-libc6.1-1.so.2' -o -name 'libstdc++-3-*.so' | head -1)
    [[ -n "$found" ]] || die "libstdc++ .so not found in deb"

    local base
    base=$(basename "$found")
    cp "$found" "$VIAVOICE_ROOT/usr/lib/" || die "Failed to copy $base"
    ln -sf "$base" "$VIAVOICE_ROOT/usr/lib/libstdc++-libc6.1-1.so.2" || die "Failed to create libstdc++ symlink"

    info "Installed $base"
    info "Symlink: libstdc++-libc6.1-1.so.2 -> $base"

    rm -rf "$extract_dir"
    CLEANUP_DIRS=()
}

# --- Build the speech-dispatcher module ---
build_module() {
    step "Building sd_viavoice module..."

    # Prepare ViaVoice lib directory for linking
    mkdir -p "$DEPS_DIR/viavoice/lib"
    cp "$VIAVOICE_ROOT/usr/lib/libibmeci50.so" "$DEPS_DIR/viavoice/lib/" || die "Failed to copy libibmeci50.so for linking"

    make -C "$ROOT_DIR" clean || true
    make -C "$ROOT_DIR" || die "Build failed"

    [[ -f "$BUILD_DIR/sd_viavoice.bin" ]] || die "Build produced no binary at $BUILD_DIR/sd_viavoice.bin"
    info "Build successful"
}

# --- Assemble the bundle ---
assemble_bundle() {
    step "Assembling bundle..."

    # Start fresh
    rm -rf "$BUNDLE_DIR"
    mkdir -p "$BUNDLE_DIR"/{usr/bin,usr/lib/ViaVoiceTTS,etc}

    # Module binary
    cp "$BUILD_DIR/sd_viavoice.bin" "$BUNDLE_DIR/usr/bin/" || die "Failed to copy sd_viavoice.bin"

    # ViaVoice-specific libraries (not system libs)
    cp "$VIAVOICE_ROOT/usr/lib/libibmeci50.so" "$BUNDLE_DIR/usr/lib/" || die "Failed to copy libibmeci50.so"
    cp "$VIAVOICE_ROOT/usr/lib/enu50.so" "$BUNDLE_DIR/usr/lib/" || die "Failed to copy enu50.so"

    # Ancient libstdc++
    local stdcpp
    stdcpp=$(find "$VIAVOICE_ROOT/usr/lib" -maxdepth 1 -name 'libstdc++-3-*.so' -type f | head -1)
    if [[ -n "$stdcpp" ]]; then
        cp "$stdcpp" "$BUNDLE_DIR/usr/lib/" || die "Failed to copy $(basename "$stdcpp")"
    fi
    cp -a "$VIAVOICE_ROOT/usr/lib/libstdc++-libc6.1-1.so.2" "$BUNDLE_DIR/usr/lib/" || die "Failed to copy libstdc++ symlink"

    # ViaVoice tools and data
    cp -r "$VIAVOICE_ROOT/usr/lib/ViaVoiceTTS/bin" "$BUNDLE_DIR/usr/lib/ViaVoiceTTS/" || die "Failed to copy ViaVoiceTTS/bin"
    if [[ -d "$VIAVOICE_ROOT/usr/lib/ViaVoiceTTS/samples" ]]; then
        cp -r "$VIAVOICE_ROOT/usr/lib/ViaVoiceTTS/samples" "$BUNDLE_DIR/usr/lib/ViaVoiceTTS/"
    fi

    # Documentation
    if [[ -d "$VIAVOICE_ROOT/usr/doc" ]]; then
        cp -r "$VIAVOICE_ROOT/usr/doc" "$BUNDLE_DIR/usr/"
    fi

    # Header file (for potential development)
    if [[ -f "$VIAVOICE_ROOT/usr/include/eci.h" ]]; then
        mkdir -p "$BUNDLE_DIR/usr/include"
        cp "$VIAVOICE_ROOT/usr/include/eci.h" "$BUNDLE_DIR/usr/include/"
    fi

    # Config and scripts from our repo
    cp "$ROOT_DIR/config/viavoice.conf" "$BUNDLE_DIR/etc/" || die "Failed to copy viavoice.conf"
    cp "$ROOT_DIR/bundle/install.sh"    "$BUNDLE_DIR/"     || die "Failed to copy install.sh"
    cp "$ROOT_DIR/bundle/uninstall.sh"  "$BUNDLE_DIR/"     || die "Failed to copy uninstall.sh"
    cp "$ROOT_DIR/bundle/sd_viavoice.in" "$BUNDLE_DIR/sd_viavoice" || die "Failed to copy sd_viavoice wrapper"
    if [[ -f "$ROOT_DIR/README.md" ]]; then
        cp "$ROOT_DIR/README.md" "$BUNDLE_DIR/"
    fi

    # Placeholder eci.ini (install.sh will fix Path=)
    cat > "$BUNDLE_DIR/usr/lib/ViaVoiceTTS/eci.ini" << 'ECIEOF'
[1.0]
Path=@VIAVOICE_LIB@/enu50.so
Version=5.0
Voice1=0 50 65 30 0 0 50 92
Voice2=1 50 81 30 0 50 50 95
Voice3=1 22 93 35 0 0 50 95
Voice7=1 45 68 30 3 40 50 90
Voice8=0 30 61 44 18 20 50 89
Voice4=0 89 52 43 0 0 50 93
Voice5=0 50 69 34 0 0 70 92
Voice6=1 56 89 35 0 40 70 95
ECIEOF
    info "Created placeholder eci.ini (install.sh will fix paths)"

    # Set permissions
    chmod +x "$BUNDLE_DIR/install.sh"
    chmod +x "$BUNDLE_DIR/uninstall.sh"
    chmod +x "$BUNDLE_DIR/sd_viavoice"
    chmod +x "$BUNDLE_DIR/usr/bin/sd_viavoice.bin"
    find "$BUNDLE_DIR/usr/lib/ViaVoiceTTS/bin/" -type f -exec chmod +x {} + 2>/dev/null || true

    info "Bundle assembled"
}

# --- Create tarball ---
create_tarball() {
    step "Creating distribution tarball..."

    tar -czf "$ROOT_DIR/dist/viavoice-tts-bundle.tar.gz" -C "$ROOT_DIR/dist" viavoice-bundle/ \
        || die "Failed to create tarball"

    info "Bundle created: $ROOT_DIR/dist/viavoice-tts-bundle.tar.gz"
}

# --- Main ---
main() {
    echo ""
    echo "========================================"
    echo "  ViaVoice TTS Bundle Builder"
    echo "========================================"
    echo ""

    check_build_deps
    download_all
    extract_viavoice_rpms
    extract_libstdcpp
    build_module
    assemble_bundle
    create_tarball

    echo ""
    echo "========================================"
    echo "  Build Complete!"
    echo "========================================"
    echo ""
}

main "$@"
