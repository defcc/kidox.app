<div align="center">
  <img src="Resources/Icons/KidoX-400.png" width="160" height="160" alt="KidoX app icon">
  <h1>KidoX</h1>
  <h3>A focused macOS launcher built with Swift and SwiftUI.</h3>
  <p>
    KidoX keeps your applications, folders, and launch workflows close at hand in a native macOS experience.
  </p>
  <p>
    <a href="https://kidox.app">Website</a>
    ·
    <a href="https://kidox.app/help">Help</a>
    ·
    <a href="https://kidox.app/support">Support</a>
  </p>
  <img src="media/kidox-launcher.png" width="100%" alt="KidoX launcher screenshot">
</div>

## Overview

This repository contains the KidoX macOS app source code. It is published for transparency, security review, education, and community contributions.

The license-management backend, production release configuration, signing credentials, notarization credentials, and distribution infrastructure are not included in this repository.

## Source Availability

KidoX is source-available, not open-source.

You may read the source code, study how the app works, audit it, and build it locally for personal evaluation, security review, or development. You may also submit issues and pull requests.

You may not redistribute KidoX, publish compiled builds, sell compiled builds, distribute modified versions, distribute forks, or use the KidoX name, icon, logo, or brand assets in a way that suggests an official release or endorsement without prior written permission.

Official builds are distributed only through channels controlled by the KidoX maintainers.

## What's Included

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

## Local Development

Open `KidoXApp.xcodeproj` in Xcode and run the `KidoX` scheme.

You can also build from the command line:

```sh
xcodebuild -project KidoXApp.xcodeproj -scheme KidoX -configuration Debug build
```

The project uses Swift Package Manager dependencies resolved by Xcode.

Local builds are intended for evaluation, review, and development. They are not licensed for redistribution.

## Packaging

The DMG helper lives at `Packaging/DMG/build-dmg.sh`.

Release packaging requires local signing, notarization, and production configuration that are intentionally not committed to this repository. Local files such as `Packaging/DMG/release.env` are ignored and should not be committed.

## Maintainers

- [Chengchao](https://github.com/defcc)

## Contributing

Issues and pull requests are welcome when they improve the app, documentation, reliability, or security.

By submitting a contribution, you agree that the maintainers may use, modify, distribute, and include your contribution in official KidoX releases.

## Disclaimer

This repository is provided as a source-visible reference for the KidoX macOS app. It is not an official distribution channel for compiled binaries.

## License

No open-source license is granted.

The source code is made available only under the source-availability terms described above. All rights not expressly granted are reserved by the copyright holders. The KidoX name, logo, icon, and related brand assets are reserved.
