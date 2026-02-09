# ViaVoice TTS for Speech-Dispatcher

A speech-dispatcher module for IBM ViaVoice TTS 5.1. This lets you use ViaVoice as a text-to-speech engine on modern Linux through speech-dispatcher.

ViaVoice TTS is based on the same Eloquence synthesis technology that IBM and ETI developed in the 90s. Version 5.1 was freely distributed by IBM and is now archived on archive.org. It sounds significantly more natural than eSpeak NG for extended listening.

## Install

Requires: speech-dispatcher, 32-bit libc support (the ViaVoice engine is a 32-bit i386 binary from 2000).

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

If you don't have 32-bit support installed, on Debian/Ubuntu:

```bash
sudo dpkg --add-architecture i386 && sudo apt install libc6:i386
```

Test it:

```bash
spd-say -o viavoice "Hello, this is ViaVoice."
spd-say -o viavoice -y Flo "Hi, I'm Flo!"
spd-say -o viavoice -L   # list voices
```

## Uninstall

```bash
# From the bundle directory, or from wherever you installed it
sudo ./uninstall.sh

# Or with a custom prefix
./uninstall.sh --prefix=/path/to/install
```

## Voices

ViaVoice 5.1 ships with 8 English voices:

| Voice | Name |
|-------|------|
| 0 | Wade (adult male, default) |
| 1 | Flo (adult female) |
| 2 | Bobbie (child) |
| 3 | Male 2 |
| 4 | Male 3 |
| 5 | Female 2 |
| 6 | Grandma (elderly female) |
| 7 | Grandpa (elderly male) |

Select by name: `spd-say -o viavoice -y Grandpa "Back in my day..."`

## Configuration

The config file lives at `<install-path>/etc/viavoice.conf` and is also copied to speech-dispatcher's module config directory during install. All settings are optional. The defaults work fine.

```conf
# Sample rate: 8000, 11025, or 22050 (default: 22050)
ViaVoiceSampleRate 22050

# Default voice (0-7, see table above)
ViaVoiceDefaultVoice 0

# Voice parameters (applied to all voices)
ViaVoicePitchBaseline 65     # 0-100
ViaVoicePitchFluctuation 30  # 0-100, higher = more expressive
ViaVoiceSpeed 50             # 0-250
ViaVoiceVolume 90            # 0-100
ViaVoiceHeadSize 50          # 0-100, affects resonance
ViaVoiceRoughness 0          # 0-100, voice gravel
ViaVoiceBreathiness 0        # 0-100, airy quality

# Phrase prediction (0=off, 1=on, default: off)
ViaVoicePhrasePrediction 0

# Custom dictionaries
ViaVoiceMainDict /path/to/main.dct
ViaVoiceRootDict /path/to/root.dct
ViaVoiceAbbrevDict /path/to/abbrev.dct
```

## Building from source

Build dependencies (Debian/Ubuntu):

```bash
sudo apt install gcc-multilib libc6-dev-i386 libspeechd-dev curl rpm2cpio cpio binutils make
```

Build:

```bash
./scripts/build-bundle.sh
```

This downloads the ViaVoice RTK/SDK from archive.org, extracts them, downloads the ancient libstdc++ that ViaVoice needs, compiles the speech-dispatcher module as a 32-bit binary, and packages everything into `dist/viavoice-tts-bundle.tar.gz`.

All downloads are verified against embedded SHA256 checksums. Pass `--skip-verify` to bypass this during development.

## How it works

This section explains the full pipeline from speech-dispatcher to audio output.

### Architecture overview

Speech-dispatcher (SPD) is a server that sits between applications and TTS engines. Applications send text to SPD via the SSIP protocol. SPD processes the text (punctuation handling, SSML wrapping) and routes it to a module -- this project is one such module.

SPD modules are standalone executables that communicate with the SPD server over stdin/stdout using a line-based protocol. The module receives commands like `SPEAK`, `STOP`, `SET`, and `LIST VOICES`. When SPD sends text to speak, it wraps it in SSML and escapes special characters as XML entities (`'` becomes `&apos;`, `&` becomes `&amp;`, etc.).

### The wrapper script

SPD launches `sd_viavoice`, which is a bash wrapper script (`bundle/sd_viavoice.in`). It resolves its own path (following symlinks), then sets up the environment:

- `ECIINI` -- points to `eci.ini`, the ViaVoice voice configuration file
- `LD_LIBRARY_PATH` -- prepends the bundle's `usr/lib/` so the linker finds `libibmeci50.so` and the ancient `libstdc++-libc6.1-1.so.2`
- `LD_PRELOAD` -- preloads `enu50.so` (the English voice data) to work around a loading issue in ViaVoice

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
- `ViaVoiceTTS/bin/` -- IBM SDK tools (inigen, vieweci, showmsg)
- `ViaVoiceTTS/eci.ini` -- voice configuration (paths are fixed up by the installer)

The only thing the host system needs to provide is 32-bit libc (`libc6:i386` on Debian) and speech-dispatcher.

### Why not IBMTTS 6.7 / Voxin?

IBMTTS 6.7 (sold as Voxin) is the newer version of this engine but has several issues: non-toggleable phrase prediction, non-disableable abbreviation dictionaries, and a bug where speech parameters (rate, volume) randomly reset during synthesis. ViaVoice 5.1 doesn't have these problems.

## License

- Module code: BSD (based on speech-dispatcher's skeleton module by Samuel Thibault)
- ViaVoice RTK/SDK: IBM proprietary (abandonware, archived for accessibility use)

## Credits

- IBM ViaVoice TTS 5.1 (~2000)
- [speech-dispatcher](https://github.com/brailcom/speechd)
- [Archive.org](https://archive.org) for preserving the ViaVoice packages
