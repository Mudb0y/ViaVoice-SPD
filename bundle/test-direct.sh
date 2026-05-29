#!/bin/bash
#
# ViaVoice direct synth smoke test (no speech-dispatcher).
#

set -euo pipefail

baseDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
libDir="$baseDir/usr/lib"
runtimeDir="$libDir/runtime"
sampleBin="$libDir/ViaVoiceTTS/samples/cmdlinespeak/cmdlinespeak"
eciIniSource="$libDir/ViaVoiceTTS/eci.ini"
tmpIniFile=""

cleanup_tmp() {
    [[ -n "$tmpIniFile" ]] && rm -f "$tmpIniFile" 2>/dev/null || true
}
trap cleanup_tmp EXIT

if [[ ! -x "$sampleBin" ]]; then
    echo "test-direct: sample binary not found: $sampleBin" >&2
    exit 1
fi
if [[ ! -f "$eciIniSource" ]]; then
    echo "test-direct: eci.ini not found: $eciIniSource" >&2
    exit 1
fi
if [[ ! -f "$libDir/enu50.so" ]]; then
    echo "test-direct: voice library not found: $libDir/enu50.so" >&2
    exit 1
fi

if [[ $# -eq 0 ]]; then
    set -- "Direct ViaVoice smoke test."
fi

tmpIniFile="$(mktemp)"
cp "$eciIniSource" "$tmpIniFile"
sed -i "s|@VIAVOICE_LIB@|$libDir|g" "$tmpIniFile"

export ECIINI="$tmpIniFile"
export LD_LIBRARY_PATH="$runtimeDir:$libDir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_PRELOAD="$libDir/enu50.so${LD_PRELOAD:+:$LD_PRELOAD}"

if [[ -x "$runtimeDir/ld-linux.so.2" ]]; then
    exec "$runtimeDir/ld-linux.so.2" --library-path "$LD_LIBRARY_PATH" "$sampleBin" "$@"
fi

exec "$sampleBin" "$@"
