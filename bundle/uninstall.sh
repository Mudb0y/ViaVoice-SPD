#!/bin/bash
#
# ViaVoice TTS Bundle Uninstaller
#
# Removes the ViaVoice TTS speech-dispatcher module and its configuration.
#

set -euo pipefail

# --- Output helpers (color suppressed when not on a terminal) ---
if [[ -t 2 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi

info() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Argument parsing ---
YES=false
PREFIX=""

usage() {
    cat <<'EOF'
Usage: uninstall.sh [OPTIONS]

Remove the ViaVoice TTS speech-dispatcher module.

Options:
  --yes              Skip confirmation prompt
  --prefix=PATH      Specify install path (overrides auto-detection)
  --help             Show this help message

Examples:
  sudo ./uninstall.sh                    # Uninstall system-wide install
  ./uninstall.sh --prefix=~/.local/ViaVoiceTTS
  ./uninstall.sh --yes                   # Non-interactive
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

# --- Find installation ---
find_installation() {
    # If --prefix given, use it directly
    if [[ -n "$PREFIX" ]]; then
        if [[ -d "$PREFIX" && -f "$PREFIX/usr/bin/sd_viavoice.bin" ]]; then
            echo "$PREFIX"
            return 0
        fi
        die "No ViaVoice installation found at --prefix=$PREFIX"
    fi

    # Auto-detect: check standard locations
    local candidates=(
        /opt/ViaVoiceTTS
        "$HOME/.local/ViaVoiceTTS"
    )
    for path in "${candidates[@]}"; do
        if [[ -d "$path" && -f "$path/usr/bin/sd_viavoice.bin" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

INSTALL_PATH="$(find_installation)" || die "ViaVoice installation not found. Use --prefix=PATH if installed to a custom location."
info "Found installation at: $INSTALL_PATH"

# Validate that this actually looks like our install before rm -rf
if [[ ! -f "$INSTALL_PATH/usr/bin/sd_viavoice.bin" ]]; then
    die "Directory $INSTALL_PATH does not contain usr/bin/sd_viavoice.bin — refusing to remove"
fi

# --- Detect install mode based on path ---
if [[ "$INSTALL_PATH" == /opt/* || "$INSTALL_PATH" == /usr/* ]]; then
    SYSTEM_MODE=true
else
    SYSTEM_MODE=false
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
            /usr/lib/speech-dispatcher-modules
            /usr/libexec/speech-dispatcher-modules
            /usr/lib64/speech-dispatcher-modules
        )
        for dir in "${candidates[@]}"; do
            if [[ -d "$dir" ]]; then
                echo "$dir"
                return 0
            fi
        done
    else
        local dir="$HOME/.local/libexec/speech-dispatcher-modules"
        if [[ -d "$dir" ]]; then
            echo "$dir"
            return 0
        fi
    fi
    return 1
}

find_spd_config_dir() {
    if [[ "$SYSTEM_MODE" == true ]]; then
        local dir="/etc/speech-dispatcher/modules"
        if [[ -d "$dir" ]]; then
            echo "$dir"
            return 0
        fi
    else
        local dir="${XDG_CONFIG_HOME:-$HOME/.config}/speech-dispatcher/modules"
        if [[ -d "$dir" ]]; then
            echo "$dir"
            return 0
        fi
    fi
    return 1
}

SPD_MODULE_DIR="$(find_spd_module_dir)" || SPD_MODULE_DIR=""
SPD_CONFIG_DIR="$(find_spd_config_dir)" || SPD_CONFIG_DIR=""

# --- Show what will be removed and confirm ---
echo ""
echo "Will remove:"
echo "  - $INSTALL_PATH/"
if [[ -n "$SPD_MODULE_DIR" && -L "$SPD_MODULE_DIR/sd_viavoice" ]]; then
    echo "  - $SPD_MODULE_DIR/sd_viavoice (symlink)"
fi
if [[ -n "$SPD_CONFIG_DIR" && -f "$SPD_CONFIG_DIR/viavoice.conf" ]]; then
    echo "  - $SPD_CONFIG_DIR/viavoice.conf"
fi
echo ""

if [[ "$YES" != true ]]; then
    if [[ ! -t 0 ]]; then
        die "stdin is not a terminal — pass --yes for non-interactive uninstall"
    fi
    read -p "Continue? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# --- Remove symlink ---
if [[ -n "$SPD_MODULE_DIR" && -L "$SPD_MODULE_DIR/sd_viavoice" ]]; then
    rm -f "$SPD_MODULE_DIR/sd_viavoice" || warn "Could not remove symlink $SPD_MODULE_DIR/sd_viavoice (need sudo?)"
    info "Removed module symlink"
fi

# --- Remove config ---
if [[ -n "$SPD_CONFIG_DIR" && -f "$SPD_CONFIG_DIR/viavoice.conf" ]]; then
    rm -f "$SPD_CONFIG_DIR/viavoice.conf" || warn "Could not remove config $SPD_CONFIG_DIR/viavoice.conf (need sudo?)"
    info "Removed config file"
fi

# --- Remove installation directory ---
info "Removing $INSTALL_PATH..."
rm -rf "$INSTALL_PATH" || die "Failed to remove $INSTALL_PATH (need sudo?)"

echo ""
info "Uninstallation complete"
