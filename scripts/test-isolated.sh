#!/usr/bin/env bash
#
# Run an isolated, no-install ViaVoice test through a temporary Speech Dispatcher instance.
# This does not modify or stop the user's existing speech-dispatcher service.
#

set -euo pipefail

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repoDir="$(cd "$scriptDir/.." && pwd)"
bundlePath="$repoDir/dist/viavoice-bundle"
testText="hello from isolated no-install viavoice"
keepTemp=false

usage() {
    cat <<'EOF'
Usage: scripts/test-isolated.sh [OPTIONS] [TEXT...]

Run ViaVoice audibly without installing it system-wide.
Starts a temporary Speech Dispatcher instance with a private socket/config.

Options:
  --bundle=PATH   Bundle directory (default: dist/viavoice-bundle)
  --keep-temp     Keep temporary files for inspection
  -h, --help      Show this help

Examples:
  scripts/test-isolated.sh "hello world"
  scripts/test-isolated.sh --bundle=/tmp/viavoice-bundle "testing one two"
EOF
}

for arg in "$@"; do
    case "$arg" in
        --bundle=*)
            bundlePath="${arg#--bundle=}"
            ;;
        --keep-temp)
            keepTemp=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ "$testText" == "hello from isolated no-install viavoice" ]]; then
                testText="$arg"
            else
                testText="$testText $arg"
            fi
            ;;
    esac
done

if [[ ! -d "$bundlePath" ]]; then
    echo "test-isolated: bundle directory not found: $bundlePath" >&2
    exit 1
fi
if [[ ! -x "$bundlePath/usr/bin/sd_viavoice.bin" ]]; then
    echo "test-isolated: missing module binary: $bundlePath/usr/bin/sd_viavoice.bin" >&2
    exit 1
fi
if [[ ! -f "$repoDir/config/viavoice.conf" ]]; then
    echo "test-isolated: missing config template: $repoDir/config/viavoice.conf" >&2
    exit 1
fi

if ! command -v speech-dispatcher >/dev/null 2>&1; then
    echo "test-isolated: speech-dispatcher command not found" >&2
    exit 1
fi
if ! command -v spd-say >/dev/null 2>&1; then
    echo "test-isolated: spd-say command not found" >&2
    exit 1
fi
if ! command -v rg >/dev/null 2>&1; then
    echo "test-isolated: rg command not found" >&2
    exit 1
fi

tempRoot="$(mktemp -d /tmp/viavoice-isolated.XXXXXX)"
configDir="$tempRoot/config"
modulesDir="$tempRoot/modules"
moduleName="viavoice_test"
socketPath="$tempRoot/speechd.sock"
pidFile="$tempRoot/speechd.pid"
speechdConf="$configDir/speechd.conf"
baseConf=""

cleanup_temp() {
    if [[ -f "$pidFile" ]]; then
        kill "$(cat "$pidFile")" 2>/dev/null || true
    fi
    if [[ "$keepTemp" != true ]]; then
        rm -rf "$tempRoot"
    fi
}
trap cleanup_temp EXIT

if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/speech-dispatcher/speechd.conf" ]]; then
    baseConf="${XDG_CONFIG_HOME:-$HOME/.config}/speech-dispatcher/speechd.conf"
elif [[ -f "/etc/speech-dispatcher/speechd.conf" ]]; then
    baseConf="/etc/speech-dispatcher/speechd.conf"
else
    echo "test-isolated: could not find a base speechd.conf" >&2
    exit 1
fi

mkdir -p "$configDir/modules" "$modulesDir"
cp "$baseConf" "$speechdConf"

if ! rg -q 'AddModule "viavoice_test"' "$speechdConf"; then
    echo "AddModule \"viavoice_test\" \"sd_viavoice\" \"viavoice.conf\"" >> "$speechdConf"
fi
if rg -q '^#?[[:space:]]*DefaultModule' "$speechdConf"; then
    sed -i 's|^#\?[[:space:]]*DefaultModule.*|DefaultModule viavoice_test|' "$speechdConf"
else
    echo "DefaultModule viavoice_test" >> "$speechdConf"
fi
if rg -q '^#?[[:space:]]*CommunicationMethod' "$speechdConf"; then
    sed -i 's|^#\?[[:space:]]*CommunicationMethod.*|CommunicationMethod "unix_socket"|' "$speechdConf"
else
    echo "CommunicationMethod \"unix_socket\"" >> "$speechdConf"
fi
if rg -q '^#?[[:space:]]*SocketPath' "$speechdConf"; then
    sed -i "s|^#\?[[:space:]]*SocketPath.*|SocketPath \"$socketPath\"|" "$speechdConf"
else
    echo "SocketPath \"$socketPath\"" >> "$speechdConf"
fi

sed "s|@INSTALL_PATH@|$bundlePath|g" "$repoDir/config/viavoice.conf" > "$configDir/modules/viavoice.conf"

cat > "$modulesDir/sd_viavoice" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

baseDir="__BUNDLE_PATH__"
runtimeLoader="$baseDir/usr/lib/runtime/ld-linux.so.2"
moduleBin="$baseDir/usr/bin/sd_viavoice.bin"
eciIni="$baseDir/usr/lib/ViaVoiceTTS/eci.ini"
libDir="$baseDir/usr/lib"
tmpIniFile=""

cleanup_tmp() {
    [[ -n "$tmpIniFile" ]] && rm -f "$tmpIniFile" 2>/dev/null || true
}
trap cleanup_tmp EXIT

if [[ ! -f "$moduleBin" ]]; then
    echo "isolated sd_viavoice: missing module binary: $moduleBin" >&2
    exit 1
fi
if [[ ! -f "$eciIni" ]]; then
    echo "isolated sd_viavoice: missing eci.ini: $eciIni" >&2
    exit 1
fi

if rg -q '@VIAVOICE_LIB@' "$eciIni"; then
    tmpIniFile="$(mktemp)"
    cp "$eciIni" "$tmpIniFile"
    sed -i "s|@VIAVOICE_LIB@|$libDir|g" "$tmpIniFile"
    export ECIINI="$tmpIniFile"
else
    export ECIINI="$eciIni"
fi

export LD_LIBRARY_PATH="$libDir/runtime:$libDir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_PRELOAD="$libDir/enu50.so${LD_PRELOAD:+:$LD_PRELOAD}"

if [[ -x "$runtimeLoader" ]]; then
    exec "$runtimeLoader" --library-path "$LD_LIBRARY_PATH" "$moduleBin" "$@"
fi
exec "$moduleBin" "$@"
EOF

sed -i "s|__BUNDLE_PATH__|$bundlePath|g" "$modulesDir/sd_viavoice"
chmod +x "$modulesDir/sd_viavoice"

echo "Starting isolated speech-dispatcher..."
speech-dispatcher --run-daemon -C "$configDir" -m "$modulesDir" -c unix_socket -S "$socketPath" -P "$pidFile" -t 60

for _ in $(seq 1 50); do
    [[ -S "$socketPath" ]] && break
    sleep 0.1
done
if [[ ! -S "$socketPath" ]]; then
    echo "test-isolated: isolated socket did not appear: $socketPath" >&2
    exit 1
fi

echo "Speaking through isolated module '$moduleName'..."
SPEECHD_ADDRESS="unix_socket:$socketPath" spd-say -o "$moduleName" -w "$testText"

if [[ "$keepTemp" == true ]]; then
    echo "Temporary files kept at: $tempRoot"
fi
echo "Isolated test complete."
