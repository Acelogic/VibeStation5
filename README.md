# VibeStation5

VibeStation5 is an experimental native SwiftUI PS4/PS5 runtime for Apple Silicon, with shared macOS and iPadOS targets. It is **inspired by and derived from [SharpEmu](https://github.com/sharpemu/sharpemu)**, whose loader, runtime, and emulation research provided the foundation for this port.

The Apple-platform work replaces SharpEmu's desktop-oriented x86-64 direct-execution path with an ARM64-native, no-JIT interpreter designed to operate within iPadOS executable-memory restrictions.

> [!IMPORTANT]
> VibeStation5 is an early compatibility and CPU bring-up project—not a general-purpose playable PS5 emulator. The Dreaming Sarah screen below is the current interactive title-menu milestone while broader HLE, scheduling, GPU, and Metal rendering work continues.

## Running on iPad

The current build reaches an interactive Dreaming Sarah menu on a physical 11-inch iPad Pro M4, with title music, selection effects, touch controls, iPad keyboard input, DualSense support, and a full-screen guest view.

![Dreaming Sarah menu running full-screen on a physical iPad Pro](docs/screenshots/dreaming-sarah-menu-ipad.png)

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/library-ipad.png" alt="VibeStation5 game library on iPad"></td>
    <td width="50%"><img src="docs/screenshots/runtime-console-ipad.png" alt="VibeStation5 runtime console and Dreaming Sarah guest view on iPad"></td>
  </tr>
  <tr>
    <td align="center"><strong>Game Library</strong></td>
    <td align="center"><strong>Runtime Console</strong></td>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/screenshots/settings-ipad.png" alt="VibeStation5 settings and supported-host status on iPad"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><strong>Settings and Host Status</strong></td>
  </tr>
</table>

Dreaming Sarah is used here only as a compatibility-test title. The game, firmware, keys, and complete copyrighted game data are not included in this repository.

## Current capabilities

- Shared macOS and iPadOS SwiftUI game library, runtime console, settings, and full-screen guest UI
- Security-scoped folder imports that persist across launches
- Recursive `eboot.bin` discovery with `sce_sys/param.json` metadata and artwork
- PS4/PS5 SELF and decrypted 64-bit ELF inspection
- Lazy file-backed virtual memory with PS4/PS5 image bases
- Dynamic-table parsing, x86-64 base relocations, and HLE import thunks
- Vendored Capstone x86-64 decoding for macOS and iPadOS ARM64
- ARM64-native x86-64 interpreter covering the current integer, atomic, BMI2, SIMD, and AVX bring-up paths
- AVFoundation guest PCM output plus title-music and menu-effect playback for the Dreaming Sarah milestone
- DualSense/PS5 controller, hardware keyboard, and on-screen touch input
- Game and System UI preflight modes with deterministic runtime reporting
- Unit coverage for executable loading, virtual memory, platform gating, input/audio, and ARM-native guest execution

The iPad target currently gates execution to 1 TB / 16 GB iPad Pro M4 and M5 configurations. The macOS target requires macOS 14 or newer.

## Build

Requirements:

- Xcode with the required Apple platform SDKs
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Generate the project and build the iPad simulator target:

```sh
xcodegen generate
xcodebuild -project VibeStation5.xcodeproj \
  -scheme VibeStation5 \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  build
```

Build the macOS target:

```sh
xcodebuild -project VibeStation5.xcodeproj \
  -scheme VibeStation5-macOS \
  -destination 'platform=macOS' \
  build
```

The standalone probe can inspect and exercise a user-supplied `eboot.bin` without the UI:

```sh
xcodebuild -project VibeStation5.xcodeproj \
  -scheme VibeStation5Probe \
  -configuration Release \
  -derivedDataPath /tmp/VibeStation5Probe \
  CODE_SIGNING_ALLOWED=NO build

/tmp/VibeStation5Probe/Build/Products/Release/VibeStation5Probe /path/to/eboot.bin
```

## Project status

The loader, runtime shell, decoder, and CPU interpreter run natively on ARM64. Dreaming Sarah reaches the current interactive title-menu milestone on iPad; ASTRO BOT's SELF also loads, applies 557,366 relocations, and executes one million guest instructions in the standalone probe before its configured budget stops the run.

Major remaining work includes broader HLE/syscall behavior, thread scheduling, complete x86-64/AVX semantics, firmware services, GNM/GNMX emulation, and a general Metal renderer.

## Attribution and license

VibeStation5 is inspired by and derived from the [SharpEmu project](https://github.com/sharpemu/sharpemu), an experimental PlayStation 5 emulator for Windows, Linux, and macOS. SharpEmu copyright notices and SPDX headers are retained in derived source files.

VibeStation5 is licensed under **GPL-2.0-or-later**. See [LICENSE](LICENSE). The vendored [Capstone](https://www.capstone-engine.org/) sources retain their upstream BSD/LLVM license files under `Vendor/Capstone`.

Dreaming Sarah and its artwork are property of their respective rights holders. Screenshots are included for compatibility documentation and project demonstration only.
