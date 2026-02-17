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
# NOTE: We bundle a minimal 32-bit runtime loader/libs so end users do not need
# to install host multilib runtime packages just to run the module.
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
RUNTIME_DIR="$BUNDLE_DIR/usr/lib/runtime"

# --- Download URLs ---
VIAVOICE_BASE_URL="https://archive.org/download/mandrake-7.2-power-pack/Mandrake%207.2%20PowerPack%20CD%2004%20of%2007.iso/IBM-ViaVoice-SDK%2Ftar"
VIAVOICE_RTK_URL="${VIAVOICE_BASE_URL}/viavoice_tts_rtk_5.tar"
VIAVOICE_SDK_URL="${VIAVOICE_BASE_URL}/viavoice_tts_sdk_5.tar"
LIBSTDCPP_URL="https://archive.debian.org/debian/pool/main/g/gcc-2.95/libstdc++2.10-glibc2.2_2.95.4-27_i386.deb"

# --- SHA256 checksums ---
RTK_SHA256="2cd5069a24b409862a88c4a086fbe03147e9f307541f501ba96dd37d6f854651"
SDK_SHA256="c03911146ee7faf0bd15fff05bed32516eeef2b2e79fe0a7d744aed002c4db9b"
LIBSTDCPP_SHA256="236ed073aa04d4d704d1664eb4bfc2d32f0c47c30f6c0fc5c7d62a4a03fa7317"

# --- 32-bit runtime libs to bundle ---
RUNTIME_LIBS=(
    libc.so.6
    libm.so.6
    libdl.so.2
    libpthread.so.0
    libgcc_s.so.1
)

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
    local speechdCflags=""
    if ! printf '#include <stdio.h>\nint main(void){return 0;}\n' | gcc -m32 -x c -c -o /dev/null - 2>/dev/null; then
        missing+=("32-bit libc development headers (gnu/stubs-32.h)")
    fi
    command -v pkg-config &>/dev/null || missing+=("pkg-config")
    if command -v pkg-config &>/dev/null; then
        if pkg-config --exists speech-dispatcher; then
            speechdCflags=$(pkg-config --cflags speech-dispatcher 2>/dev/null || true)
            echo '#include <speechd_types.h>' | gcc -m32 -x c -c -o /dev/null - $speechdCflags 2>/dev/null \
                || missing+=("speech-dispatcher headers (speechd_types.h)")
        else
            missing+=("speech-dispatcher pkg-config file (speech-dispatcher.pc)")
        fi
    fi
    command -v curl   &>/dev/null || missing+=("curl")
    command -v rpm2cpio &>/dev/null || missing+=("rpm2cpio")
    command -v cpio   &>/dev/null || missing+=("cpio")
    command -v ar     &>/dev/null || missing+=("binutils (ar)")
    command -v file   &>/dev/null || missing+=("file")
    command -v make   &>/dev/null || missing+=("make")

    if [[ ${#missing[@]} -gt 0 ]]; then
        local installHint=""
        if command -v apt &>/dev/null; then
            installHint="sudo apt install gcc-multilib libc6-dev-i386 libspeechd-dev pkg-config curl rpm2cpio cpio binutils file make"
        elif command -v pacman &>/dev/null; then
            installHint="sudo pacman -S gcc-multilib lib32-glibc speech-dispatcher pkgconf curl rpmextract cpio binutils file make"
        elif command -v dnf &>/dev/null; then
            installHint="sudo dnf install gcc glibc-devel.i686 speech-dispatcher-devel pkgconf-pkg-config curl rpm2cpio cpio binutils file make"
        else
            installHint="Install required toolchain + speech-dispatcher headers/pkg-config for your distro"
        fi
        die "Missing build dependencies: ${missing[*]}
Install with: $installHint
Note: runtime no longer needs host multilib packages, but building from source still needs a 32-bit development toolchain."
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

# --- Locate 32-bit loader/libs on diverse distro layouts ---
is_i386_elf() {
    local candidatePath="$1"
    [[ -f "$candidatePath" ]] || return 1
    file -Lb "$candidatePath" | grep -qi 'ELF 32-bit'
}

resolve_from_gcc_print_file_name() {
    local libraryName="$1"
    local candidatePath=""

    candidatePath=$(gcc -m32 -print-file-name="$libraryName" 2>/dev/null || true)
    if [[ -n "$candidatePath" && "$candidatePath" != "$libraryName" ]] && is_i386_elf "$candidatePath"; then
        echo "$candidatePath"
        return 0
    fi
    return 1
}

resolve_from_ldconfig() {
    local libraryName="$1"
    local candidatePath=""

    command -v ldconfig &>/dev/null || return 1
    while IFS= read -r candidatePath; do
        if is_i386_elf "$candidatePath"; then
            echo "$candidatePath"
            return 0
        fi
    done < <(ldconfig -p 2>/dev/null | awk -v libName="$libraryName" '$1 == libName && /=>/ {print $NF}')
    return 1
}

resolve_from_fixed_dirs() {
    local libraryName="$1"
    shift
    local dirPath=""
    local candidatePath=""

    for dirPath in "$@"; do
        candidatePath="$dirPath/$libraryName"
        if is_i386_elf "$candidatePath"; then
            echo "$candidatePath"
            return 0
        fi
    done
    return 1
}

resolve_from_gcc_search_dirs() {
    local libraryName="$1"
    local libraryDirsLine=""
    local dirPath=""
    local candidatePath=""
    local gccDirs=()

    libraryDirsLine=$(gcc -m32 -print-search-dirs 2>/dev/null | sed -n 's/^libraries: =//p')
    [[ -n "$libraryDirsLine" ]] || return 1

    IFS=':' read -r -a gccDirs <<< "$libraryDirsLine"
    for dirPath in "${gccDirs[@]}"; do
        [[ -n "$dirPath" ]] || continue
        candidatePath="$dirPath/$libraryName"
        if is_i386_elf "$candidatePath"; then
            echo "$candidatePath"
            return 0
        fi
    done
    return 1
}

resolve_from_find() {
    local libraryName="$1"
    local roots=(
        /lib
        /lib32
        /usr/lib
        /usr/lib32
        /usr/local/lib
        /usr/local/lib32
    )
    local rootPath=""
    local candidatePath=""

    for rootPath in "${roots[@]}"; do
        [[ -d "$rootPath" ]] || continue
        while IFS= read -r candidatePath; do
            if is_i386_elf "$candidatePath"; then
                echo "$candidatePath"
                return 0
            fi
        done < <(find "$rootPath" -maxdepth 6 -type f -name "$libraryName" 2>/dev/null)
    done
    return 1
}

find_i386_loader() {
    local loaderName="ld-linux.so.2"
    local candidatePath=""

    if candidatePath=$(resolve_from_gcc_print_file_name "$loaderName"); then
        echo "$candidatePath"
        return 0
    fi
    if candidatePath=$(resolve_from_fixed_dirs "$loaderName" \
        /lib /lib32 /lib/i386-linux-gnu /lib/i686-linux-gnu \
        /usr/lib32 /usr/lib/i386-linux-gnu /usr/lib/i686-linux-gnu); then
        echo "$candidatePath"
        return 0
    fi
    if candidatePath=$(resolve_from_ldconfig "$loaderName"); then
        echo "$candidatePath"
        return 0
    fi
    if candidatePath=$(resolve_from_find "$loaderName"); then
        echo "$candidatePath"
        return 0
    fi
    return 1
}

find_i386_lib() {
    local libraryName="$1"
    local candidatePath=""

    if candidatePath=$(resolve_from_gcc_print_file_name "$libraryName"); then
        echo "$candidatePath"
        return 0
    fi
    if candidatePath=$(resolve_from_ldconfig "$libraryName"); then
        echo "$candidatePath"
        return 0
    fi
    if candidatePath=$(resolve_from_fixed_dirs "$libraryName" \
        /lib/i386-linux-gnu /usr/lib/i386-linux-gnu \
        /lib/i686-linux-gnu /usr/lib/i686-linux-gnu \
        /lib32 /usr/lib32 /lib /usr/lib); then
        echo "$candidatePath"
        return 0
    fi
    if candidatePath=$(resolve_from_gcc_search_dirs "$libraryName"); then
        echo "$candidatePath"
        return 0
    fi
    if candidatePath=$(resolve_from_find "$libraryName"); then
        echo "$candidatePath"
        return 0
    fi
    return 1
}

# --- Assemble the bundle ---
assemble_bundle() {
    step "Assembling bundle..."

    # Start fresh
    rm -rf "$BUNDLE_DIR"
    mkdir -p "$BUNDLE_DIR"/{usr/bin,usr/lib/ViaVoiceTTS,etc}
    mkdir -p "$RUNTIME_DIR"

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

    # Minimal 32-bit runtime loader/libs so host multilib package install is not required
    local loader_path
    loader_path=$(find_i386_loader) || die "Could not find a 32-bit loader (ld-linux.so.2) on build host"
    cp -L "$loader_path" "$RUNTIME_DIR/ld-linux.so.2" || die "Failed to copy $(basename "$loader_path")"
    local runtime_lib=""
    local runtime_path=""
    for runtime_lib in "${RUNTIME_LIBS[@]}"; do
        runtime_path=$(find_i386_lib "$runtime_lib") || die "Could not find 32-bit $runtime_lib on build host"
        cp -L "$runtime_path" "$RUNTIME_DIR/$runtime_lib" || die "Failed to copy $runtime_lib"
    done
    info "Bundled 32-bit runtime loader/libs in $RUNTIME_DIR"

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

    # Pronunciation dictionaries
    if [[ -f "$ROOT_DIR/config/main.dict" ]]; then
        cp "$ROOT_DIR/config/main.dict" "$BUNDLE_DIR/etc/"
    fi
    if [[ -f "$ROOT_DIR/config/root.dict" ]]; then
        cp "$ROOT_DIR/config/root.dict" "$BUNDLE_DIR/etc/"
    fi

    # Config and scripts from our repo
    cp "$ROOT_DIR/config/viavoice.conf" "$BUNDLE_DIR/etc/" || die "Failed to copy viavoice.conf"
    cp "$ROOT_DIR/bundle/install.sh"    "$BUNDLE_DIR/"     || die "Failed to copy install.sh"
    cp "$ROOT_DIR/bundle/uninstall.sh"  "$BUNDLE_DIR/"     || die "Failed to copy uninstall.sh"
    cp "$ROOT_DIR/bundle/test-direct.sh" "$BUNDLE_DIR/"    || die "Failed to copy test-direct.sh"
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
    chmod +x "$BUNDLE_DIR/test-direct.sh"
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
