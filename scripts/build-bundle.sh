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

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "${BLUE}==>${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DEPS_DIR="$ROOT_DIR/deps"
BUILD_DIR="$ROOT_DIR/build"
BUNDLE_DIR="$ROOT_DIR/dist/viavoice-bundle"

# ViaVoice mini rootfs - this will have the full IBM layout
VIAVOICE_ROOT="$DEPS_DIR/viavoice-root"

# URLs for ViaVoice packages
VIAVOICE_BASE_URL="https://archive.org/download/mandrake-7.2-power-pack/Mandrake%207.2%20PowerPack%20CD%2004%20of%2007.iso/IBM-ViaVoice-SDK%2Ftar"
VIAVOICE_RTK_URL="${VIAVOICE_BASE_URL}/viavoice_tts_rtk_5.tar"
VIAVOICE_SDK_URL="${VIAVOICE_BASE_URL}/viavoice_tts_sdk_5.tar"

# download ancient libstdc++ - ViaVoice needs this, modern systems don't have it
LIBSTDCPP_URL="http://archive.debian.org/debian/pool/main/g/gcc-2.95/libstdc++2.10-glibc2.2_2.95.4-27_i386.deb"

cd "$ROOT_DIR"

echo ""
echo "========================================"
echo "  ViaVoice TTS Bundle Builder"
echo "========================================"
echo ""

# Create directories
mkdir -p "$DEPS_DIR"/{downloads,debs}
mkdir -p "$VIAVOICE_ROOT"
mkdir -p "$BUILD_DIR"
mkdir -p "$BUNDLE_DIR"/{usr/bin,usr/lib,etc,share}

# -----------------------------------------------------------------------------
# Step 1: Download ViaVoice RTK and SDK
# -----------------------------------------------------------------------------
step "Downloading ViaVoice packages..."

RTK_TAR="$DEPS_DIR/downloads/viavoice_tts_rtk_5.tar"
SDK_TAR="$DEPS_DIR/downloads/viavoice_tts_sdk_5.tar"

if [[ ! -f "$RTK_TAR" ]]; then
    info "Downloading RTK..."
    curl -L -o "$RTK_TAR" "$VIAVOICE_RTK_URL" || error "Failed to download RTK"
else
    info "Using cached RTK"
fi

if [[ ! -f "$SDK_TAR" ]]; then
    info "Downloading SDK..."
    curl -L -o "$SDK_TAR" "$VIAVOICE_SDK_URL" || error "Failed to download SDK"
else
    info "Using cached SDK"
fi

# -----------------------------------------------------------------------------
# Step 2: Extract ViaVoice RTK and SDK
# -----------------------------------------------------------------------------
step "Extracting ViaVoice packages..."

# Extract RTK tarball
mkdir -p "$DEPS_DIR/rtk-tmp"
tar -xf "$RTK_TAR" -C "$DEPS_DIR/rtk-tmp"

# Find and extract RTK RPM
RTK_RPM=$(find "$DEPS_DIR/rtk-tmp" -name "*.rpm" -type f | head -1)
if [[ -z "$RTK_RPM" ]]; then
    error "Could not find RTK RPM in tarball"
fi
info "Extracting RTK RPM: $(basename "$RTK_RPM")"
cd "$VIAVOICE_ROOT"
rpm2cpio "$RTK_RPM" | cpio -idm 2>/dev/null

# Extract SDK tarball
mkdir -p "$DEPS_DIR/sdk-tmp"
tar -xf "$SDK_TAR" -C "$DEPS_DIR/sdk-tmp"

# Find and extract SDK RPM
SDK_RPM=$(find "$DEPS_DIR/sdk-tmp" -name "*.rpm" -type f | head -1)
if [[ -z "$SDK_RPM" ]]; then
    error "Could not find SDK RPM in tarball"
fi
info "Extracting SDK RPM: $(basename "$SDK_RPM")"
cd "$VIAVOICE_ROOT"
rpm2cpio "$SDK_RPM" | cpio -idm 2>/dev/null

cd "$ROOT_DIR"

# Verify extraction
if [[ ! -f "$VIAVOICE_ROOT/usr/lib/libibmeci50.so" ]]; then
    error "RTK extraction failed - libibmeci50.so not found"
fi
if [[ ! -f "$VIAVOICE_ROOT/usr/lib/enu50.so" ]]; then
    error "RTK extraction failed - enu50.so not found"
fi
if [[ ! -f "$VIAVOICE_ROOT/usr/lib/ViaVoiceTTS/bin/inigen" ]]; then
    error "RTK extraction failed - inigen not found"
fi

info "ViaVoice extracted successfully"
info "  Core libs: libibmeci50.so, enu50.so"
info "  Tools: inigen"

# -----------------------------------------------------------------------------
# Step 3: Download ancient libstdc++ for ViaVoice compatibility
# -----------------------------------------------------------------------------
step "Downloading ancient libstdc++ (required by ViaVoice)..."

LIBSTDCPP_DEB="$DEPS_DIR/debs/libstdc++2.10.deb"
if [[ ! -f "$LIBSTDCPP_DEB" ]]; then
    info "Downloading libstdc++2.10..."
    curl -L -o "$LIBSTDCPP_DEB" "$LIBSTDCPP_URL" || error "Failed to download libstdc++2.10"
else
    info "Using cached libstdc++2.10"
fi

# Extract
mkdir -p "$DEPS_DIR/debs/libstdc++_extract"
cd "$DEPS_DIR/debs/libstdc++_extract"
ar x "$LIBSTDCPP_DEB" 2>/dev/null || true
tar -xf data.tar.* 2>/dev/null || tar -xf data.tar 2>/dev/null || true
cd "$ROOT_DIR"

# Find and copy the libstdc++ library
found_stdcpp=$(find "$DEPS_DIR/debs/libstdc++_extract" -name "libstdc++-3-*.so" -type f 2>/dev/null | head -1)
if [[ -n "$found_stdcpp" ]]; then
    cp "$found_stdcpp" "$VIAVOICE_ROOT/usr/lib/"
    base=$(basename "$found_stdcpp")
    # Create the symlink ViaVoice expects
    ln -sf "$base" "$VIAVOICE_ROOT/usr/lib/libstdc++-libc6.1-1.so.2"
    info "Installed $base"
    info "Created symlink: libstdc++-libc6.1-1.so.2 -> $base"
else
    error "Could not find libstdc++ in downloaded package"
fi

# -----------------------------------------------------------------------------
# Step 4: Build the speech-dispatcher module
# -----------------------------------------------------------------------------
step "Building sd_viavoice module..."

# Check for 32-bit build tools
if ! gcc -m32 -x c -c -o /dev/null /dev/null 2>/dev/null; then
    error "32-bit compilation not available. Install gcc-multilib."
fi

# Create a lib directory with the ViaVoice lib for linking
mkdir -p "$DEPS_DIR/viavoice/lib"
cp "$VIAVOICE_ROOT/usr/lib/libibmeci50.so" "$DEPS_DIR/viavoice/lib/"

# Build
cd "$ROOT_DIR"
make clean 2>/dev/null || true
make || error "Build failed"

info "Build successful"

# -----------------------------------------------------------------------------
# Step 5: Assemble the bundle
# -----------------------------------------------------------------------------
step "Assembling bundle..."

# Copy our module binary
cp "$BUILD_DIR/sd_viavoice.bin" "$BUNDLE_DIR/usr/bin/"

# Copy ONLY ViaVoice-specific libraries (not system libs!)
# These are the libs that won't exist on modern systems:
cp "$VIAVOICE_ROOT/usr/lib/libibmeci50.so" "$BUNDLE_DIR/usr/lib/"
cp "$VIAVOICE_ROOT/usr/lib/enu50.so" "$BUNDLE_DIR/usr/lib/"
cp "$VIAVOICE_ROOT/usr/lib/libstdc++-3-libc6.2-2-2.10.0.so" "$BUNDLE_DIR/usr/lib/" 2>/dev/null || true
cp -a "$VIAVOICE_ROOT/usr/lib/libstdc++-libc6.1-1.so.2" "$BUNDLE_DIR/usr/lib/"

# Copy ViaVoice tools and data
mkdir -p "$BUNDLE_DIR/usr/lib/ViaVoiceTTS"
cp -r "$VIAVOICE_ROOT/usr/lib/ViaVoiceTTS/bin" "$BUNDLE_DIR/usr/lib/ViaVoiceTTS/"
cp -r "$VIAVOICE_ROOT/usr/lib/ViaVoiceTTS/samples" "$BUNDLE_DIR/usr/lib/ViaVoiceTTS/" 2>/dev/null || true

# Copy documentation
if [[ -d "$VIAVOICE_ROOT/usr/doc" ]]; then
    cp -r "$VIAVOICE_ROOT/usr/doc" "$BUNDLE_DIR/usr/"
fi

# Copy header file (for potential development)
if [[ -f "$VIAVOICE_ROOT/usr/include/eci.h" ]]; then
    mkdir -p "$BUNDLE_DIR/usr/include"
    cp "$VIAVOICE_ROOT/usr/include/eci.h" "$BUNDLE_DIR/usr/include/"
fi

# Copy our config and scripts
cp "$ROOT_DIR/config/viavoice.conf" "$BUNDLE_DIR/etc/"
cp "$ROOT_DIR/bundle/install.sh" "$BUNDLE_DIR/"
cp "$ROOT_DIR/bundle/uninstall.sh" "$BUNDLE_DIR/"
cp "$ROOT_DIR/bundle/sd_viavoice.in" "$BUNDLE_DIR/sd_viavoice"
cp "$ROOT_DIR/README.md" "$BUNDLE_DIR/" 2>/dev/null || true

# Create a placeholder eci.ini that install.sh will regenerate
# This is necessary because eci.ini contains absolute paths
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
chmod +x "$BUNDLE_DIR/usr/lib/ViaVoiceTTS/bin/"* 2>/dev/null || true

# -----------------------------------------------------------------------------
# Step 6: Create tarball
# -----------------------------------------------------------------------------
step "Creating distribution tarball..."

cd "$ROOT_DIR/dist"
tar -czvf viavoice-tts-bundle.tar.gz viavoice-bundle/

TARBALL="$ROOT_DIR/dist/viavoice-tts-bundle.tar.gz"
info "Bundle created: $TARBALL"

echo ""
echo "========================================"
echo "  Build Complete!"
echo "========================================"
echo ""

# Cleanup temp files
rm -rf "$DEPS_DIR/rtk-tmp" "$DEPS_DIR/sdk-tmp"
