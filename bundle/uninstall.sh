#!/bin/bash
#
# ViaVoice TTS Bundle Uninstaller
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo "ViaVoice TTS Bundle Uninstaller"
echo "================================"
echo ""

# Find installation
INSTALL_PATH=""
for path in /opt/ViaVoiceTTS "$HOME/.local/ViaVoiceTTS"; do
    if [[ -d "$path" && -f "$path/usr/bin/sd_viavoice.bin" ]]; then
        INSTALL_PATH="$path"
        break
    fi
done

if [[ -z "$INSTALL_PATH" ]]; then
    error "ViaVoice bundle installation not found"
fi

info "Found installation at: $INSTALL_PATH"

# Determine if this was a system or user install
if [[ "$INSTALL_PATH" == "/opt/ViaVoiceTTS" ]]; then
    SYSTEM_MODE=true
    if command -v pkg-config &>/dev/null; then
        SPD_MODULE_DIR=$(pkg-config --variable=modulebindir speech-dispatcher 2>/dev/null || true)
    fi
    if [[ -z "$SPD_MODULE_DIR" ]]; then
        for path in /usr/lib/speech-dispatcher-modules /usr/libexec/speech-dispatcher-modules; do
            if [[ -d "$path" ]]; then
                SPD_MODULE_DIR="$path"
                break
            fi
        done
    fi
    SPD_CONFIG_DIR="/etc/speech-dispatcher/modules"
else
    SYSTEM_MODE=false
    SPD_MODULE_DIR="$HOME/.local/libexec/speech-dispatcher-modules"
    SPD_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/speech-dispatcher/modules"
fi

echo ""
echo "Will remove:"
echo "  - $INSTALL_PATH"
[[ -n "$SPD_MODULE_DIR" ]] && echo "  - $SPD_MODULE_DIR/sd_viavoice (symlink)"
[[ -n "$SPD_CONFIG_DIR" ]] && echo "  - $SPD_CONFIG_DIR/viavoice.conf"
echo ""

read -p "Continue? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Remove symlink
if [[ -n "$SPD_MODULE_DIR" && -L "$SPD_MODULE_DIR/sd_viavoice" ]]; then
    rm -f "$SPD_MODULE_DIR/sd_viavoice" 2>/dev/null && info "Removed module symlink" || warn "Could not remove symlink (need sudo?)"
fi

# Remove config
if [[ -n "$SPD_CONFIG_DIR" && -f "$SPD_CONFIG_DIR/viavoice.conf" ]]; then
    rm -f "$SPD_CONFIG_DIR/viavoice.conf" 2>/dev/null && info "Removed config file" || warn "Could not remove config (need sudo?)"
fi

# Remove installation directory
info "Removing $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"

echo ""
info "Uninstallation complete"
