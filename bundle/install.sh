#!/bin/bash
#
# ViaVoice TTS Bundle Installer
# =============================
#
# Installs the ViaVoice TTS module for speech-dispatcher.
# Requires: speech-dispatcher, 32-bit lib support (libc6:i386 on Debian/Ubuntu)
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()    { echo -e "${BLUE}[STEP]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default install locations
SYSTEM_INSTALL="/opt/ViaVoiceTTS"
USER_INSTALL="$HOME/.local/ViaVoiceTTS"

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     ViaVoice TTS - Speech Dispatcher Module Installer     ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if we're running from the bundle directory
if [[ ! -f "$SCRIPT_DIR/usr/bin/sd_viavoice.bin" ]]; then
    error "This script must be run from the bundle directory"
fi

# Check for 32-bit support
if ! /lib/ld-linux.so.2 --version &>/dev/null 2>&1; then
    if [[ -f /lib32/ld-linux.so.2 ]]; then
        : # OK, different path
    else
        warn "32-bit support may not be installed"
        echo "  On Debian/Ubuntu: sudo dpkg --add-architecture i386 && sudo apt install libc6:i386"
        echo "  On Arch: sudo pacman -S lib32-glibc"
        echo ""
    fi
fi

# Detect if running as root
if [[ $EUID -eq 0 ]]; then
    INSTALL_PATH="$SYSTEM_INSTALL"
    SYSTEM_MODE=true
    info "Running as root - will install to $INSTALL_PATH"
else
    INSTALL_PATH="$USER_INSTALL"
    SYSTEM_MODE=false
    info "Running as user - will install to $INSTALL_PATH"
    echo ""
    echo -e "  ${YELLOW}Tip:${NC} Run with sudo for system-wide install to /opt/ViaVoiceTTS"
    echo ""
fi

# Allow override
if [[ -n "$1" ]]; then
    INSTALL_PATH="$1"
    info "Custom install path: $INSTALL_PATH"
fi

# Determine speech-dispatcher paths based on install mode
if [[ $SYSTEM_MODE == true ]]; then
    # System install: use pkg-config to find the correct module path
    if command -v pkg-config &>/dev/null; then
        SPD_MODULE_DIR=$(pkg-config --variable=modulebindir speech-dispatcher 2>/dev/null || true)
    fi
    # Fallback if pkg-config doesn't work
    if [[ -z "$SPD_MODULE_DIR" || ! -d "$SPD_MODULE_DIR" ]]; then
        for path in /usr/lib/speech-dispatcher-modules /usr/libexec/speech-dispatcher-modules; do
            if [[ -d "$path" ]]; then
                SPD_MODULE_DIR="$path"
                break
            fi
        done
    fi
    SPD_CONFIG_DIR="/etc/speech-dispatcher/modules"
else
    # User install: use XDG-compliant paths
    SPD_MODULE_DIR="$HOME/.local/libexec/speech-dispatcher-modules"
    SPD_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/speech-dispatcher/modules"
fi

# Verify we found a module directory
if [[ -z "$SPD_MODULE_DIR" ]]; then
    error "Could not determine speech-dispatcher module directory. Is speech-dispatcher installed?"
fi

# Confirm
echo ""
echo "Installation summary:"
echo "  Bundle install path: $INSTALL_PATH"
echo "  SPD module symlink:  $SPD_MODULE_DIR/sd_viavoice"
echo "  SPD config path:     $SPD_CONFIG_DIR/viavoice.conf"
echo ""
read -p "Continue? [Y/n] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]?$ ]]; then
    echo "Aborted."
    exit 0
fi

# Step 1: Copy bundle to install location
step "Copying files to $INSTALL_PATH..."
mkdir -p "$INSTALL_PATH"
cp -r "$SCRIPT_DIR"/* "$INSTALL_PATH/"

# Step 2: Fix eci.ini path
step "Configuring eci.ini..."

ENU_LIB="$INSTALL_PATH/usr/lib/enu50.so"
ECI_INI="$INSTALL_PATH/usr/lib/ViaVoiceTTS/eci.ini"

if [[ -f "$ECI_INI" ]]; then
    # Replace placeholder or old path with actual install path
    sed -i "s|^Path=.*|Path=$ENU_LIB|" "$ECI_INI"
    success "eci.ini configured: Path=$ENU_LIB"
else
    warn "eci.ini not found - creating minimal config"
    mkdir -p "$(dirname "$ECI_INI")"
    cat > "$ECI_INI" << EOF
[1.0]
Path=$ENU_LIB
Version=5.0
Voice1=0 50 65 30 0 0 50 92
Voice2=1 50 81 30 0 50 50 95
Voice3=1 22 93 35 0 0 50 95
Voice7=1 45 68 30 3 40 50 90
Voice8=0 30 61 44 18 20 50 89
Voice4=0 89 52 43 0 0 50 93
Voice5=0 50 69 34 0 0 70 92
Voice6=1 56 89 35 0 40 70 95
EOF
    success "Created eci.ini"
fi

# Step 3: Set permissions
step "Setting permissions..."
chmod +x "$INSTALL_PATH/sd_viavoice"
chmod +x "$INSTALL_PATH/usr/bin/sd_viavoice.bin"
chmod +x "$INSTALL_PATH/usr/lib/ViaVoiceTTS/bin/"* 2>/dev/null || true

# Step 4: Create speech-dispatcher module symlink
step "Creating symlink in speech-dispatcher modules directory..."

mkdir -p "$SPD_MODULE_DIR"
SYMLINK_PATH="$SPD_MODULE_DIR/sd_viavoice"

if [[ -e "$SYMLINK_PATH" || -L "$SYMLINK_PATH" ]]; then
    warn "Existing sd_viavoice found, backing up..."
    mv "$SYMLINK_PATH" "$SYMLINK_PATH.backup.$(date +%s)" 2>/dev/null || rm -f "$SYMLINK_PATH"
fi

ln -sf "$INSTALL_PATH/sd_viavoice" "$SYMLINK_PATH"
success "Symlink created: $SYMLINK_PATH"

# Step 5: Install module config file
step "Installing module configuration..."

mkdir -p "$SPD_CONFIG_DIR"
if [[ -f "$INSTALL_PATH/etc/viavoice.conf" ]]; then
    cp "$INSTALL_PATH/etc/viavoice.conf" "$SPD_CONFIG_DIR/viavoice.conf"
    success "Config installed: $SPD_CONFIG_DIR/viavoice.conf"
fi

# Step 6: Restart speech-dispatcher
step "Restarting speech-dispatcher..."
if pgrep -x speech-dispatch >/dev/null 2>&1; then
    pkill speech-dispatch 2>/dev/null || true
    sleep 1
    info "speech-dispatcher stopped (will restart on next use)"
else
    info "speech-dispatcher not running"
fi

# Quick sanity check
echo ""
echo -e "${CYAN}Verifying installation...${NC}"

# Check library dependencies
if ldd "$INSTALL_PATH/usr/bin/sd_viavoice.bin" 2>&1 | grep -q "not found"; then
    warn "Some libraries may be missing:"
    ldd "$INSTALL_PATH/usr/bin/sd_viavoice.bin" 2>&1 | grep "not found"
    echo ""
    echo "Try installing 32-bit libraries:"
    echo "  Debian/Ubuntu: sudo apt install libc6:i386 libpthread-stubs0-dev:i386"
    echo "  Arch: sudo pacman -S lib32-glibc"
else
    success "All library dependencies satisfied"
fi

# Check if ViaVoice libs are found
if LD_LIBRARY_PATH="$INSTALL_PATH/usr/lib" ldd "$INSTALL_PATH/usr/bin/sd_viavoice.bin" 2>&1 | grep -q "libibmeci50.so.*not found"; then
    error "ViaVoice library not found - installation may be incomplete"
else
    success "ViaVoice libraries OK"
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
