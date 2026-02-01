#!/bin/bash
#
# ViaVoice TTS Bundle Installer
# =============================
#
# Self-contained installation - no system dependencies required.
# Works on any Linux distro with speech-dispatcher installed.
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
echo -e "${CYAN}║     ViaVoice TTS - Self-Contained Bundle Installer        ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if we're running from the bundle directory
if [[ ! -f "$SCRIPT_DIR/usr/bin/sd_viavoice.bin" ]]; then
    error "This script must be run from the bundle directory"
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
    error "Could not determine speech-dispatcher module directory"
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

# Step 2: Regenerate eci.ini with correct paths using inigen
step "Generating eci.ini for this install location..."

INIGEN="$INSTALL_PATH/usr/lib/ViaVoiceTTS/bin/inigen"
ENU_LIB="$INSTALL_PATH/usr/lib/enu50.so"
ECI_INI="$INSTALL_PATH/usr/lib/ViaVoiceTTS/eci.ini"

if [[ -x "$INIGEN" ]] && [[ -f "$ENU_LIB" ]]; then
    cd "$INSTALL_PATH/usr/lib/ViaVoiceTTS"
    
    # Always use bundled ld-linux.so.2 to avoid system library paths
    # This ensures we use ONLY bundled libs, not /usr/lib on the host
    if "$INSTALL_PATH/usr/lib/ld-linux.so.2" --library-path "$INSTALL_PATH/usr/lib" "$INIGEN" "$ENU_LIB" 2>/dev/null; then
        success "eci.ini generated with inigen"
    else
        warn "inigen failed, using existing eci.ini"
        if [[ -f "$ECI_INI" ]]; then
            sed -i "s|^Path=.*|Path=$ENU_LIB|" "$ECI_INI"
        fi
    fi
    
    # Move generated eci.ini to correct location if needed
    if [[ -f "$INSTALL_PATH/usr/lib/ViaVoiceTTS/eci.ini" ]]; then
        : # Already in place
    elif [[ -f "$INSTALL_PATH/eci.ini" ]]; then
        mv "$INSTALL_PATH/eci.ini" "$ECI_INI"
    fi
    
    cd "$INSTALL_PATH"
else
    warn "inigen not found, using existing eci.ini"
    if [[ -f "$ECI_INI" ]]; then
        sed -i "s|^Path=.*|Path=$ENU_LIB|" "$ECI_INI"
    fi
fi

# Step 3: Set permissions
step "Setting permissions..."
chmod +x "$INSTALL_PATH/sd_viavoice"
chmod +x "$INSTALL_PATH/usr/bin/sd_viavoice.bin"
chmod +x "$INSTALL_PATH/usr/lib/ld-linux.so.2"
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
if pkill -0 speech-dispatch 2>/dev/null; then
    pkill speech-dispatch 2>/dev/null || true
    sleep 1
    info "speech-dispatcher stopped (will restart on next use)"
else
    info "speech-dispatcher not running"
fi

# Quick test
echo -e "${CYAN}Quick sanity check...${NC}"
if LD_LIBRARY_PATH="$INSTALL_PATH/usr/lib" "$INSTALL_PATH/usr/lib/ld-linux.so.2" --list "$INSTALL_PATH/usr/bin/sd_viavoice.bin" &>/dev/null; then
    success "Module binary and libraries OK"
else
    warn "Module may have issues - check library dependencies"
fi
