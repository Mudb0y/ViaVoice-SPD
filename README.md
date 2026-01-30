# ViaVoice TTS for Speech-Dispatcher

[![Build and Release](https://github.com/YOUR_USERNAME/viavoice-spd/actions/workflows/release.yml/badge.svg)](https://github.com/YOUR_USERNAME/viavoice-spd/actions/workflows/release.yml)

A speech-dispatcher module for IBM ViaVoice TTS 5.1, packaged as a fully self-contained bundle.

**Works on any Linux distro. No dependencies required.**

## Disclaimer

This project is vibe-coded. If you don't like that, than this definitely isn't for you.

To that end I have made certain that everything works at the very least as well as it can. I have reviewed the shell scripts used to build and install time and time again, fixing any issues that were glaringly obvious to a human but not to an AI and trying to conform to standards to the best of my ability.

I don't know C however, so I haven't thoroughly reviewed the SPD module. If any of you do know C, have the time on your hands, and are willing to take a look at the code and even point out issues, I would be grateful.

If, however, you use AI to contribute, claim otherwise, and I notice, your contribution goes out the window. Nothing wrong with using AI to code, but everything wrong with lieing. Don't be a meany. Our broken education system should've at least tought you that.

## Why?

Just because.

Actually, I'm kidding. I hate how Espeak NG sounds. Some people can stand it just fine, but it drives me batshit insane, particularly while using it on headphones.

My TTS of choice on platforms other than Linux is Eloquence, which IBM worked on along side ETI / Eloquent Technologies during the 90s and early 2000s. ETI seems to have stopped development around version 6.1, which is still widely in circulation amongst OEMs like Apple, Freedom Scientific, ETC, while IBM continued their own thing.

IBM's last version is IBMTTS 6.7, which is available for Linux today via Voxin but has many, many issues. Some amongst them are non-toggleable phraze prediction, non-toggleable abbriviation dictionaries, and an issue inside of the library it self which causes the speech parameters like rate and volume to reset at random intervals.

This is ViaVoice TTS 5.1, which while slightly older doesn't have this reset issue, and at least with Claude's SPD implementation seems to just behave much better than the Voxin module does. I have no idea if it's the librarys fault or Voxin's, so I'm not shifting blame on to anybody. I just think this works better.

Plus, you can't buy Voxin today, and you can still download the ViaVoice tarballs, and you don't even have to feel bad about it since they were once freely available on IBM's website!

## Quick Start

Download the latest release and run:

```bash
tar -xzf viavoice-tts-bundle.tar.gz
cd viavoice-bundle
sudo ./install.sh    # System-wide
# or
./install.sh         # User install (~/.local)
```

Test it:

```bash
spd-say -o viavoice "Hello, I am ViaVoice"
spd-say -o viavoice -y Flo "Hi, I'm Flo!"
spd-say -o viavoice -L  # List voices
```

## Voices

| Name | Description |
|------|-------------|
| Wade | Adult Male 1 (default) |
| Flo | Adult Female 1 |
| Bobbie | Child |
| Male2 | Adult Male 2 |
| Male3 | Adult Male 3 |
| Female2 | Adult Female 2 |
| Grandma | Elderly Female |
| Grandpa | Elderly Male |

## What's in the Bundle

The bundle contains the complete ViaVoice RTK and SDK installed, plus a 32-bit runtime environment:

```
viavoice-bundle/
├── usr/bin/
│   └── sd_viavoice.bin             # Speech-dispatcher module
├── usr/lib/
│   ├── ld-linux.so.2               # Dynamic linker
│   ├── libc.so.6, libm.so.6        # Glibc
│   ├── libstdc++...                # Ancient C++ runtime
│   ├── libibmeci50.so              # ViaVoice ECI engine
│   ├── enu50.so                    # English voice data
│   └── ViaVoiceTTS/
│       ├── bin/
│       │   ├── inigen              # INI generator tool
│       │   ├── showmsg             # Message viewer
│       │   └── vieweci             # ECI viewer
│       ├── samples/                # SDK samples
│       └── eci.ini                 # Generated config
├── usr/include/
│   └── eci.h                       # SDK header
├── usr/doc/ViaVoiceTTS/            # Documentation
├── etc/
│   └── viavoice.conf               # Module config
├── sd_viavoice                     # Wrapper script
└── install.sh
```

The `eci.ini` file is generated at build time using IBM's `inigen` tool from the SDK.

## How It Works

When called by speech-dispatcher, the wrapper script:
1. Sets `ECIINI` to point to the bundled `eci.ini`
2. Sets `LD_LIBRARY_PATH` to the bundled libraries
3. Invokes the bundled `ld-linux.so.2` dynamic linker
4. Loads all libraries from the bundle—completely isolated from system libraries

This means it works on any Linux distro with speech-dispatcher installed.

## Building from Source

### Prerequisites

- GCC with 32-bit support (`gcc-multilib`)
- speech-dispatcher development headers
- curl, cpio (for extracting RPMs)

### Build

```bash
# Install build deps (Debian/Ubuntu)
sudo apt install gcc-multilib libc6-dev-i386 libspeechd-dev curl cpio

# Build the bundle
./scripts/build-bundle.sh
```

Output: `dist/viavoice-tts-bundle.tar.gz`

### What the build script does

1. Downloads ViaVoice RTK and SDK from [archive.org](https://archive.org/download/mandrake-7.2-power-pack/)
2. Extracts the RPMs using `rpm2cpio`
3. Installs both to a mini rootfs
4. Downloads 32-bit runtime libraries from Debian archives
5. Compiles the speech-dispatcher module
6. Runs `inigen` to generate `eci.ini`
7. Packages everything into a self-contained bundle

## Configuration

Edit `<install-path>/etc/viavoice.conf`:

```conf
# Sample rate (8000, 11025, 22050)
ViaVoiceSampleRate 22050

# Default voice (0-7)
ViaVoiceDefaultVoice 0

# Voice parameters
ViaVoicePitchBaseline 65
ViaVoiceSpeed 50
ViaVoiceVolume 90

# Text processing
ViaVoicePhrasePrediction 1

# Custom dictionaries
ViaVoiceMainDict /path/to/main.dct
ViaVoiceAbbrevDict /path/to/abbrev.dct
```

## ViaVoice SDK Tools

The bundle includes the original IBM SDK tools:

```bash
# Generate new eci.ini
$INSTALL_PATH/usr/lib/ViaVoiceTTS/bin/inigen /path/to/enu50.so

# View ECI info
$INSTALL_PATH/usr/lib/ViaVoiceTTS/bin/vieweci
```

Sample programs are in `usr/lib/ViaVoiceTTS/samples/`.

## Uninstall

```bash
# From bundle directory
./uninstall.sh

# Or manually
sudo rm -rf /opt/ViaVoiceTTS
sudo rm /usr/lib/speech-dispatcher-modules/sd_viavoice
```

## Project Structure

```
viavoice-spd/
├── .github/workflows/
│   └── release.yml           # Build & release on tag
├── src/                      # Module source code
│   ├── sd_viavoice.c         # Main module
│   ├── module_*.c            # SPD framework
│   └── *.h                   # Headers
├── bundle/                   # Install scripts & wrapper
│   ├── install.sh
│   ├── uninstall.sh
│   └── sd_viavoice.in        # Wrapper template
├── config/
│   └── viavoice.conf         # Default module config
├── scripts/
│   └── build-bundle.sh       # Downloads RTK/SDK, builds bundle
├── Makefile
└── README.md
```

## License

- Module code: BSD license (speech-dispatcher framework)
- ViaVoice RTK/SDK: IBM proprietary (abandonware, archived for accessibility)

## Credits

- IBM ViaVoice TTS 5.1 (~2000)
- [speech-dispatcher](https://github.com/brailcom/speechd) project
- [Archive.org](https://archive.org) for preserving the ViaVoice packages
