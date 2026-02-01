#!/bin/bash
#
# build-bundle.sh - Download dependencies and build the ViaVoice TTS bundle
#
# This script:
# 1. Downloads ViaVoice RTK and SDK from archive.org
# 2. Extracts the RPMs and installs to a mini rootfs
# 3. Downloads required 32-bit runtime libraries from Debian archives
# 4. Builds the speech-dispatcher module
# 5. Uses inigen to generate eci.ini
# 6. Packages everything into a self-contained bundle
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

# Debian packages for 32-bit runtime
declare -A DEB_PACKAGES=(
    ["libc6"]="http://ftp.debian.org/debian/pool/main/g/glibc/libc6_2.31-13+deb11u11_i386.deb"
    ["libgcc-s1"]="http://ftp.debian.org/debian/pool/main/g/gcc-10/libgcc-s1_10.2.1-6_i386.deb"
    ["libstdc++2.10"]="http://archive.debian.org/debian/pool/main/g/gcc-2.95/libstdc++2.10-glibc2.2_2.95.4-27_i386.deb"
)

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
mkdir -p "$BUNDLE_DIR"/{usr/bin,etc,share}

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
# Step 2: Extract ViaVoice RTK and SDK to mini rootfs
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

# -----------------------------------------------------------------------------
# Step 3: Download Debian 32-bit runtime libraries
# -----------------------------------------------------------------------------
step "Downloading 32-bit runtime libraries..."

for pkg in "${!DEB_PACKAGES[@]}"; do
    url="${DEB_PACKAGES[$pkg]}"
    deb_file="$DEPS_DIR/debs/${pkg}.deb"
    
    if [[ ! -f "$deb_file" ]]; then
        info "Downloading $pkg..."
        curl -L -o "$deb_file" "$url" || warn "Failed to download $pkg"
    else
        info "Using cached $pkg"
    fi
    
    # Extract the deb
    if [[ -f "$deb_file" ]]; then
        mkdir -p "$DEPS_DIR/debs/${pkg}_extract"
        cd "$DEPS_DIR/debs/${pkg}_extract"
        ar x "$deb_file" 2>/dev/null || true
        tar -xf data.tar.* 2>/dev/null || tar -xf data.tar 2>/dev/null || true
        cd "$ROOT_DIR"
    fi
done

# Copy all files from debian packages to viavoice rootfs
step "Installing runtime libraries to rootfs..."

mkdir -p "$VIAVOICE_ROOT/usr/lib"

for pkg in "${!DEB_PACKAGES[@]}"; do
    extract_dir="$DEPS_DIR/debs/${pkg}_extract"
    if [[ -d "$extract_dir" ]]; then
        
        # Copy all shared libraries (.so files) to /usr/lib/ (flat)
        # This handles libs from /lib/, /usr/lib/, /lib/i386-linux-gnu/, etc.
        find "$extract_dir" -type f \( -name "*.so" -o -name "*.so.*" \) | while read -r lib; do
            cp -a "$lib" "$VIAVOICE_ROOT/usr/lib/" 2>/dev/null || true
            info "    $(basename "$lib")"
        done
        
        # Also copy symlinks to shared libraries
        find "$extract_dir" -type l \( -name "*.so" -o -name "*.so.*" -o -name "ld-*.so*" \) | while read -r link; do
            cp -a "$link" "$VIAVOICE_ROOT/usr/lib/" 2>/dev/null || true
        done
        
        # Copy ld-linux.so.2 (the dynamic linker) - it's often a regular file or symlink
        found_ld=$(find "$extract_dir" -name "ld-linux.so.2" -o -name "ld-linux*.so*" 2>/dev/null)
        for ld in $found_ld; do
            cp -a "$ld" "$VIAVOICE_ROOT/usr/lib/" 2>/dev/null || true
            info "    $(basename "$ld")"
        done
    fi
done

# Fix ld-linux.so.2 symlink (may be broken due to deb directory structure)
# The deb has /lib/ld-linux.so.2 -> i386-linux-gnu/ld-2.31.so which breaks when copied flat
ld_real=$(find "$VIAVOICE_ROOT/usr/lib" -name "ld-*.so" -type f 2>/dev/null | head -1)
if [[ -n "$ld_real" ]]; then
    ln -sf "$(basename "$ld_real")" "$VIAVOICE_ROOT/usr/lib/ld-linux.so.2"
    info "Fixed ld-linux.so.2 symlink -> $(basename "$ld_real")"
fi

# Create expected symlink for ancient libstdc++ if needed
found_stdcpp=$(find "$VIAVOICE_ROOT/usr/lib" -name "libstdc++*.so.*" -type f 2>/dev/null | head -1)
if [[ -n "$found_stdcpp" ]]; then
    base=$(basename "$found_stdcpp")
    ln -sf "$base" "$VIAVOICE_ROOT/usr/lib/libstdc++-libc6.1-1.so.2" 2>/dev/null || true
    info "  Created libstdc++ compatibility symlink -> $base"
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
# Step 5: Generate eci.ini using inigen
# -----------------------------------------------------------------------------
step "Generating eci.ini with inigen..."

# inigen needs to run with the ViaVoice libs available
cd "$VIAVOICE_ROOT"
export LD_LIBRARY_PATH="$VIAVOICE_ROOT/usr/lib"

# Run inigen - it takes the path to enu50.so and generates eci.ini
# We'll generate it with the final install path placeholder, then fix it
"$VIAVOICE_ROOT/usr/lib/ViaVoiceTTS/bin/inigen" "$VIAVOICE_ROOT/usr/lib/enu50.so" 2>/dev/null || \
    "$VIAVOICE_ROOT/usr/lib/ld-linux.so.2" --library-path "$VIAVOICE_ROOT/usr/lib" \
        "$VIAVOICE_ROOT/usr/lib/ViaVoiceTTS/bin/inigen" "$VIAVOICE_ROOT/usr/lib/enu50.so"

if [[ ! -f "$VIAVOICE_ROOT/eci.ini" ]]; then
    error "inigen failed to create eci.ini"
fi

# Move eci.ini to proper location
mkdir -p "$VIAVOICE_ROOT/usr/lib/ViaVoiceTTS"
mv "$VIAVOICE_ROOT/eci.ini" "$VIAVOICE_ROOT/usr/lib/ViaVoiceTTS/"

info "eci.ini generated successfully"

cd "$ROOT_DIR"

# -----------------------------------------------------------------------------
# Step 6: Assemble the bundle
# -----------------------------------------------------------------------------
step "Assembling bundle..."

# Copy our module
cp "$BUILD_DIR/sd_viavoice.bin" "$BUNDLE_DIR/usr/bin/"

# Copy the entire ViaVoice rootfs (everything is in /usr)
cp -r "$VIAVOICE_ROOT/usr" "$BUNDLE_DIR/"

# Copy our config and scripts
cp "$ROOT_DIR/config/viavoice.conf" "$BUNDLE_DIR/etc/"
cp "$ROOT_DIR/bundle/install.sh" "$BUNDLE_DIR/"
cp "$ROOT_DIR/bundle/uninstall.sh" "$BUNDLE_DIR/"
cp "$ROOT_DIR/bundle/sd_viavoice.in" "$BUNDLE_DIR/sd_viavoice"
cp "$ROOT_DIR/README.md" "$BUNDLE_DIR/" 2>/dev/null || true

# Set permissions
chmod +x "$BUNDLE_DIR/install.sh"
chmod +x "$BUNDLE_DIR/uninstall.sh"
chmod +x "$BUNDLE_DIR/sd_viavoice"
chmod +x "$BUNDLE_DIR/usr/bin/sd_viavoice.bin"
chmod +x "$BUNDLE_DIR/usr/lib/ld-linux.so.2"
chmod +x "$BUNDLE_DIR/usr/lib/ViaVoiceTTS/bin/"* 2>/dev/null || true

# -----------------------------------------------------------------------------
# Step 7: Create tarball
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
