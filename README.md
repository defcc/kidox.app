# KidoX

KidoX is a focused macOS launcher built with Swift and SwiftUI.

This repository contains the KidoX macOS app source code. It is published for transparency, security review, education, and community contributions. The license-management backend, production release configuration, signing credentials, and distribution infrastructure are not included.

## Source Availability

KidoX is source-available, not open-source.

You may read the source code, study how the app works, audit it, and build it locally for personal evaluation or development. You may also submit issues and pull requests.

You may not redistribute KidoX, publish compiled builds, sell compiled builds, distribute modified versions, distribute forks, or use the KidoX name, icon, logo, or brand assets in a way that suggests an official release or endorsement without prior written permission.

Official builds are distributed only through channels controlled by the KidoX maintainers.

## Repository Layout

- `KidoX/` - main macOS app source
- `KidoXApp.xcodeproj/` - Xcode project and shared scheme
- `KidoXIPC/` - shared IPC support code
- `KidoXDockTile/` - Dock tile plug-in
- `Resources/` - app icons and bundled visual assets
- `Packaging/DMG/` - local DMG packaging helper scripts

## Requirements

- macOS
- Xcode
- Xcode command line tools

## Build Locally

Open `KidoXApp.xcodeproj` in Xcode and run the `KidoX` scheme.

You can also build from the command line:

```sh
xcodebuild -project KidoXApp.xcodeproj -scheme KidoX -configuration Debug build
```

The project uses Swift Package Manager dependencies resolved by Xcode.

## Packaging

The DMG helper lives at `Packaging/DMG/build-dmg.sh`.

Release packaging requires local signing, notarization, and production configuration that are intentionally not committed to this repository. Local files such as `Packaging/DMG/release.env` are ignored and should not be committed.

## Contributions

Issues and pull requests are welcome when they improve the app, documentation, reliability, or security.

By submitting a contribution, you agree that the maintainers may use, modify, distribute, and include your contribution in official KidoX releases.

## License

No open-source license is granted.

The source code is made available only under the source-availability terms described above. All rights not expressly granted are reserved by the copyright holders.
