# ViaVoice TTS for Speech-Dispatcher

A speech-dispatcher module for IBM ViaVoice TTS 5.1. This lets you use ViaVoice as a text-to-speech engine on modern Linux through speech-dispatcher.

ViaVoice TTS is based on the same Eloquence synthesis technology that IBM and ETI developed in the 90s. Version 5.1 was freely distributed by IBM on their website around 1999 - 2000. It was also distributed on the Mandrake Linux 7.2 Powerpack CDs, which is the source for our SDK and RTK versions, the bundle builder fetches them directly off of archive.org.

## Install

Requires: speech-dispatcher. The bundle ships its own 32-bit runtime loader/libs.
Your kernel still must support running i386 binaries.

Download the latest release tarball, extract it, and run the installer:

```bash
tar -xzf viavoice-tts-bundle.tar.gz
cd viavoice-bundle

# System-wide (installs to /opt/ViaVoiceTTS)
sudo ./install.sh

# Or user-only (installs to ~/.local/ViaVoiceTTS)
./install.sh
```

The installer accepts `--yes` to skip the confirmation prompt and `--prefix=PATH` for a custom location.

Test it:

```bash
spd-say -o viavoice "Hello, this is ViaVoice."
```

Direct isolated test (no speech-dispatcher):

```bash
./test-direct.sh "Hello from direct ViaVoice"
```

Audible isolated test via temporary speech-dispatcher (does not modify your running setup):

```bash
./scripts/test-isolated.sh "Hello from isolated ViaVoice"
```

## Uninstall

```bash
# From the bundle directory, or from wherever you installed it
sudo ./uninstall.sh

# Or with a custom prefix
./uninstall.sh --prefix=/path/to/install
```

## Configuration

The config file lives at `<install-path>/etc/viavoice.conf` and is also copied to speech-dispatcher's module config directory during install. All settings are optional. The defaults work fine.

## Building from source

Build dependencies (Debian/Ubuntu):

```bash
sudo apt install gcc-multilib libc6-dev-i386 libspeechd-dev curl rpm2cpio cpio binutils file make
```

Build:

```bash
./scripts/build-bundle.sh
```

This downloads the ViaVoice RTK/SDK from archive.org, extracts them, downloads the ancient libstdc++ that ViaVoice needs, compiles the speech-dispatcher module as a 32-bit binary, and packages everything into `dist/viavoice-tts-bundle.tar.gz`.

Note: using the built bundle at runtime does not require host multilib packages, but building from source still requires a 32-bit development toolchain.

All downloads are verified against embedded SHA256 checksums. Pass `--skip-verify` to bypass this during development.

## How it works

This section explains the full pipeline from speech-dispatcher to audio output.

### Architecture overview

Speech-dispatcher (SPD) is a server that sits between applications and TTS engines. Applications send text to SPD via the SSIP protocol. SPD processes the text (punctuation handling, SSML wrapping) and routes it to a module -- this project is one such module.

SPD modules are standalone executables that communicate with the SPD server over stdin/stdout using a line-based protocol. The module receives commands like `SPEAK`, `STOP`, `SET`, and `LIST VOICES`. When SPD sends text to speak, it wraps it in SSML and escapes special characters as XML entities (`'` becomes `&apos;`, `&` becomes `&amp;`, etc.).

### The wrapper script

SPD launches `sd_viavoice`, which is a bash wrapper script (`bundle/sd_viavoice.in`). It resolves its own path (following symlinks), then sets up the environment:

- `ECIINI` -- points to `eci.ini`, the ViaVoice voice configuration file
- `LD_LIBRARY_PATH` -- prepends the bundle's `usr/lib/runtime/` and `usr/lib/`
- `LD_PRELOAD` -- preloads `enu50.so` (the English voice data) to work around a loading issue in ViaVoice

If present, it launches the module through bundled `ld-linux.so.2` from `usr/lib/runtime/`, so host multilib packages are not required.
It then `exec`s the actual binary `sd_viavoice.bin`.

### The module binary

`sd_viavoice.bin` is a 32-bit ELF binary compiled from `src/sd_viavoice.c` and the module framework files (`module_main.c`, `module_readline.c`, `module_process.c`). The framework handles the stdin/stdout protocol with SPD. The module code implements these callbacks:

- `module_config()` -- parses the config file
- `module_init()` -- creates an ECI instance, allocates an audio buffer, registers the audio callback, configures voice parameters and dictionaries
- `module_set()` -- handles SPD parameter changes (voice, rate, pitch, volume), mapping SPD's -100..+100 ranges to ViaVoice's native ranges
- `module_speak_sync()` -- the main synthesis function (see below)
- `module_stop()` / `module_pause()` -- sets a flag and calls `eciStop()`
- `module_list_voices()` -- returns the 8 ViaVoice preset voices
- `module_close()` -- cleans up ECI handle, dictionaries, and buffers

### Text processing pipeline

When `module_speak_sync()` receives text from SPD, it goes through these stages:

1. **SSML stripping** -- Removes all XML tags (`<speak>`, `<voice>`, etc.) since ViaVoice doesn't understand SSML.

2. **XML entity decoding** -- Converts `&apos;` back to `'`, `&amp;` to `&`, `&lt;` to `<`, `&gt;` to `>`, `&quot;` to `"`.

3. **Text sanitization** (only for normal text reading, not character-by-character or key echo):
   - Letters, digits, whitespace, basic sentence punctuation (`. , ! ?`), `$`, and `'` pass through unchanged.
   - Clause-break characters (`;` `:` `(` `)` `[` `]` `{` `}`) are replaced with a comma attached to the preceding word. This preserves natural pause inflection without ViaVoice reading the character name aloud. For example, `word (aside) more` becomes `word, aside, more`. If the clause-break is at the start of text with no preceding word, it's simply dropped.
   - Punctuation immediately after a clause-break char is consumed (e.g., `").` doesn't leave an isolated period).
   - Em-dashes and en-dashes (U+2014, U+2013) get the same comma treatment.
   - UTF-8 currency symbols are replaced with English words: `£` to "pound", `¢` to "cent", `¥` to "yen", `€` to "euro". The ASCII `$` passes through directly since ViaVoice handles it natively (reads "$5" as "five dollars").
   - All other characters (including multi-byte UTF-8 that ViaVoice can't handle) are replaced with spaces.

   The sanitizer allocates a new buffer (2x input length) rather than editing in-place, since clause-break expansion can produce more bytes than the input.

4. **ECI synthesis** -- The cleaned text is passed to `eciAddText()`, then `eciSynthesize()` and `eciSynchronize()`. ViaVoice runs in plain text mode (`eciInputType = 0`) so it applies natural prosody to punctuation (trailing off at commas, rising pitch at question marks, finality at periods) rather than reading punctuation characters aloud.

### Audio path

ViaVoice synthesizes audio in chunks. An ECI callback (`eci_callback`) is called for each chunk with a buffer of 16-bit PCM samples. The callback appends these to a growing `AudioData` buffer (protected by a mutex). After synthesis completes, the full buffer is sent to the SPD server as a single `AudioTrack` (16-bit, mono, at the configured sample rate). SPD handles the actual audio output.

### The bundle

The tarball contains everything ViaVoice needs to run:

- `sd_viavoice.bin` -- the 32-bit speech-dispatcher module
- `libibmeci50.so` -- the ViaVoice ECI engine
- `enu50.so` -- English voice data
- `libstdc++-libc6.1-1.so.2` -- ancient libstdc++ from gcc 2.95 that ViaVoice was linked against
- `usr/lib/runtime/ld-linux.so.2` and core 32-bit glibc libs (`libc`, `libm`, `libdl`, `libpthread`, `libgcc_s`)
- `ViaVoiceTTS/bin/` -- IBM SDK tools (inigen, vieweci, showmsg)
- `ViaVoiceTTS/eci.ini` -- voice configuration (paths are fixed up by the installer)
- `test-direct.sh` -- direct engine smoke test without speech-dispatcher

The host system needs speech-dispatcher and an x86 kernel with IA32 emulation enabled.

### Why not IBMTTS 6.7 / Voxin?

IBMTTS 6.7 (sold as Voxin) is the newer version of this engine but has several issues: non-toggleable phrase prediction, non-disableable abbreviation dictionaries, and a bug where speech parameters (rate, volume) randomly reset during synthesis. ViaVoice 5.1 doesn't have these problems.

## License

- Module code: BSD (based on speech-dispatcher's skeleton module by Samuel Thibault)
- ViaVoice RTK/SDK: IBM proprietary (abandonware, archived for accessibility use)

## Credits

- IBM ViaVoice TTS 5.1 (~2000)
- [speech-dispatcher](https://github.com/brailcom/speechd)
- [Archive.org](https://archive.org) for preserving the ViaVoice packages
