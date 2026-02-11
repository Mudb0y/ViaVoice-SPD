#!/bin/bash
#
# ViaVoice TTS Bundle Installer
#
# Installs the ViaVoice TTS module for speech-dispatcher.
# Requires: speech-dispatcher, 32-bit lib support (libc6:i386 on Debian/Ubuntu)
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
step() { echo -e "${BLUE}[STEP]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default install locations
SYSTEM_INSTALL="/opt/ViaVoiceTTS"
USER_INSTALL="$HOME/.local/ViaVoiceTTS"

# --- Argument parsing ---
YES=false
PREFIX=""

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install the ViaVoice TTS speech-dispatcher module.

Options:
  --yes              Skip confirmation prompt
  --prefix=PATH      Custom install path (default: /opt/ViaVoiceTTS as root,
                     ~/.local/ViaVoiceTTS as user)
  --help             Show this help message

Examples:
  sudo ./install.sh                      # System-wide install
  ./install.sh                           # User install
  ./install.sh --prefix=/tmp/test --yes  # Custom path, non-interactive
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --yes)         YES=true ;;
        --prefix=*)    PREFIX="${arg#--prefix=}" ;;
        --help|-h)     usage ;;
        *)             die "Unknown option: $arg (try --help)" ;;
    esac
done

# --- Prerequisites ---

# Check that we're running from the bundle directory
if [[ ! -f "$SCRIPT_DIR/usr/bin/sd_viavoice.bin" ]]; then
    die "This script must be run from the bundle directory (usr/bin/sd_viavoice.bin not found)"
fi

# Check for 32-bit support
check_32bit_support() {
    local candidates=(
        /lib/ld-linux.so.2
        /lib32/ld-linux.so.2
        /lib/i386-linux-gnu/ld-linux.so.2
    )
    for ld in "${candidates[@]}"; do
        [[ -f "$ld" ]] && return 0
    done
    return 1
}

if ! check_32bit_support; then
    warn "32-bit support may not be installed"
    # Detect package manager and give targeted advice
    if command -v apt &>/dev/null; then
        echo "  Fix: sudo dpkg --add-architecture i386 && sudo apt install libc6:i386" >&2
    elif command -v pacman &>/dev/null; then
        echo "  Fix: sudo pacman -S lib32-glibc" >&2
    elif command -v dnf &>/dev/null; then
        echo "  Fix: sudo dnf install glibc.i686" >&2
    else
        echo "  Install 32-bit libc for your distribution" >&2
    fi
    echo "" >&2
fi

# --- Detect install mode ---
if [[ -n "$PREFIX" ]]; then
    INSTALL_PATH="$PREFIX"
    if [[ "$INSTALL_PATH" == /opt/* || "$INSTALL_PATH" == /usr/* ]]; then
        SYSTEM_MODE=true
    else
        SYSTEM_MODE=false
    fi
    info "Custom install path: $INSTALL_PATH"
elif [[ $EUID -eq 0 ]]; then
    INSTALL_PATH="$SYSTEM_INSTALL"
    SYSTEM_MODE=true
    info "Running as root — will install to $INSTALL_PATH"
else
    INSTALL_PATH="$USER_INSTALL"
    SYSTEM_MODE=false
    info "Running as user — will install to $INSTALL_PATH"
    echo "  Tip: Run with sudo for system-wide install to /opt/ViaVoiceTTS" >&2
    echo "" >&2
fi

# --- Find speech-dispatcher paths ---
find_spd_module_dir() {
    if [[ "$SYSTEM_MODE" == true ]]; then
        # Try pkg-config first
        if command -v pkg-config &>/dev/null; then
            local dir
            dir=$(pkg-config --variable=modulebindir speech-dispatcher 2>/dev/null) || true
            if [[ -d "${dir:-}" ]]; then
                echo "$dir"
                return 0
            fi
        fi
        # Common distro paths
        local candidates=(
            /usr/lib/speech-dispatcher-modules          # Debian/Ubuntu
            /usr/libexec/speech-dispatcher-modules       # Fedora/RHEL/Arch
            /usr/lib64/speech-dispatcher-modules         # openSUSE 64-bit
        )
        for dir in "${candidates[@]}"; do
            if [[ -d "$dir" ]]; then
                echo "$dir"
                return 0
            fi
        done
    else
        # User install: XDG-compliant path
        echo "$HOME/.local/libexec/speech-dispatcher-modules"
        return 0
    fi
    return 1
}

find_spd_config_dir() {
    if [[ "$SYSTEM_MODE" == true ]]; then
        echo "/etc/speech-dispatcher/modules"
    else
        echo "${XDG_CONFIG_HOME:-$HOME/.config}/speech-dispatcher/modules"
    fi
}

SPD_MODULE_DIR="$(find_spd_module_dir)" || die "Could not find speech-dispatcher module directory. Is speech-dispatcher installed?"
SPD_CONFIG_DIR="$(find_spd_config_dir)"

# --- Confirm installation ---
echo ""
echo "Installation summary:"
echo "  Bundle install path: $INSTALL_PATH"
echo "  SPD module symlink:  $SPD_MODULE_DIR/sd_viavoice"
echo "  SPD config path:     $SPD_CONFIG_DIR/viavoice.conf"
echo ""

if [[ "$YES" != true ]]; then
    if [[ ! -t 0 ]]; then
        die "stdin is not a terminal — pass --yes for non-interactive install"
    fi
    read -p "Continue? [Y/n] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]?$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# --- Step 1: Copy bundle to install location ---
step "Copying files to $INSTALL_PATH..."
mkdir -p "$INSTALL_PATH" || die "Failed to create $INSTALL_PATH"
cp -r "$SCRIPT_DIR"/* "$INSTALL_PATH/" || die "Failed to copy bundle files"

# --- Step 2: Fix eci.ini path ---
step "Configuring eci.ini..."

ENU_LIB="$INSTALL_PATH/usr/lib/enu50.so"
ECI_INI="$INSTALL_PATH/usr/lib/ViaVoiceTTS/eci.ini"

if [[ -f "$ECI_INI" ]]; then
    sed -i "s|^Path=.*|Path=$ENU_LIB|" "$ECI_INI" || die "Failed to update eci.ini"
    info "eci.ini configured: Path=$ENU_LIB"
else
    warn "eci.ini not found — creating minimal config"
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
    info "Created eci.ini"
fi

# --- Step 2b: Fix viavoice.conf install path ---
if [[ -f "$INSTALL_PATH/etc/viavoice.conf" ]]; then
    sed -i "s|@INSTALL_PATH@|$INSTALL_PATH|g" "$INSTALL_PATH/etc/viavoice.conf"
    info "viavoice.conf configured: @INSTALL_PATH@ → $INSTALL_PATH"
fi

# --- Step 3: Set permissions ---
step "Setting permissions..."
chmod +x "$INSTALL_PATH/sd_viavoice" || die "Failed to set permissions on sd_viavoice"
chmod +x "$INSTALL_PATH/usr/bin/sd_viavoice.bin" || die "Failed to set permissions on sd_viavoice.bin"
# ViaVoice tools (inigen etc.) - best effort
find "$INSTALL_PATH/usr/lib/ViaVoiceTTS/bin/" -type f -exec chmod +x {} + 2>/dev/null || true

# --- Step 4: Create speech-dispatcher module symlink ---
step "Creating symlink in speech-dispatcher modules directory..."

mkdir -p "$SPD_MODULE_DIR" || die "Failed to create $SPD_MODULE_DIR"
SYMLINK_PATH="$SPD_MODULE_DIR/sd_viavoice"

if [[ -e "$SYMLINK_PATH" || -L "$SYMLINK_PATH" ]]; then
    warn "Existing sd_viavoice found, backing up..."
    mv "$SYMLINK_PATH" "$SYMLINK_PATH.backup.$(date +%s)" || rm -f "$SYMLINK_PATH"
fi

ln -sf "$INSTALL_PATH/sd_viavoice" "$SYMLINK_PATH" || die "Failed to create symlink at $SYMLINK_PATH"
info "Symlink created: $SYMLINK_PATH -> $INSTALL_PATH/sd_viavoice"

# --- Step 5: Install module config file ---
step "Installing module configuration..."

mkdir -p "$SPD_CONFIG_DIR" || die "Failed to create $SPD_CONFIG_DIR"
if [[ -f "$INSTALL_PATH/etc/viavoice.conf" ]]; then
    cp "$INSTALL_PATH/etc/viavoice.conf" "$SPD_CONFIG_DIR/viavoice.conf" || die "Failed to install viavoice.conf"
    info "Config installed: $SPD_CONFIG_DIR/viavoice.conf"
else
    warn "viavoice.conf not found in bundle"
fi

# --- Step 6: Restart speech-dispatcher ---
step "Restarting speech-dispatcher..."
if pgrep -x speech-dispatch >/dev/null 2>&1; then
    warn "Killing running speech-dispatcher (it will restart on next use)"
    pkill speech-dispatch || warn "Could not kill speech-dispatcher"
    sleep 1
else
    info "speech-dispatcher not running"
fi

# --- Step 7: Verify installation ---
step "Verifying installation..."

LIB_DIR="$INSTALL_PATH/usr/lib"
BIN="$INSTALL_PATH/usr/bin/sd_viavoice.bin"

missing=$(LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$BIN" 2>&1 | grep "not found" || true)
if [[ -n "$missing" ]]; then
    warn "Some libraries are missing:"
    echo "$missing" >&2
    echo "" >&2
    if command -v apt &>/dev/null; then
        echo "  Try: sudo dpkg --add-architecture i386 && sudo apt install libc6:i386" >&2
    elif command -v pacman &>/dev/null; then
        echo "  Try: sudo pacman -S lib32-glibc" >&2
    elif command -v dnf &>/dev/null; then
        echo "  Try: sudo dnf install glibc.i686" >&2
    fi
else
    info "All library dependencies satisfied"
fi

echo ""
info "Installation complete!"
