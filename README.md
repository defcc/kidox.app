<div align="center">
  <img src="Resources/Icons/KidoX-400.png" width="160" height="160" alt="KidoX app icon">
  <h1>KidoX</h1>
  <p>A modern Launchpad replacement for Mac, with gestures, search, pages, and app uninstall.</p>
  <p>
    <a href="https://kidox.app">Website</a>
    ·
    <a href="https://kidox.app/download/">Download</a>
  </p>
  <img src="media/kidox-launcher.png" width="100%" alt="KidoX launcher screenshot">
</div>

## About KidoX App

Apple removed Launchpad in macOS Tahoe, replacing a familiar visual app launcher with a different app discovery experience.

KidoX is built for people who still want a fast, visual, keyboard-friendly way to browse, organize, and launch Mac apps.

It restores the Launchpad-style grid while improving the parts that matter day to day: quick search, clean organization, smooth navigation, customizable behavior, and a native macOS feel built with SwiftUI.

KidoX is not a system hack or a patched copy of Launchpad. It is an independent macOS app designed to provide a modern launcher experience that feels at home on current versions of macOS.

## Features

Core features:

- Launchpad-style app grid with pages, folders, drag-and-drop arrangement, and keyboard navigation
- Fast in-place search for installed apps
- F4 / Launchpad key support, custom shortcuts, hot corners, menu-bar access, and Dock access
- Optional global four-finger trackpad gesture: pinch to show KidoX, spread to hide it
- Automatic scanning of standard Applications folders
- Wallpaper, glass, and solid-color appearance modes
- Localized app language support

Pro features:

- Advanced sorting modes, including recently used, most used, newly added, and name
- Hidden Apps for keeping rarely used apps out of the launch panel
- Built-in app uninstaller with related app data cleanup and protected-system-app checks
- Custom image backgrounds
- Backup and restore for layout, hidden apps, launch stats, sorting, shortcut, appearance, Dock icon, and custom image

The four-finger gesture is optional and disabled by default. It uses a runtime-loaded private macOS multitouch framework, so official KidoX builds are distributed outside the Mac App Store.

## Overview

This repository contains the KidoX Community Edition macOS app source code. It is published for transparency, security review, education, and community contributions under the GNU Affero General Public License v3.0.

The license-management backend, production release configuration, signing credentials, notarization credentials, and distribution infrastructure are not included in this repository.

## Community Edition

You may read the source code, study how the app works, audit it, modify it, build it, and redistribute it under the terms of the AGPL-3.0 license.

Official KidoX builds are distributed only through channels controlled by the KidoX maintainers. Third-party builds and forks must comply with the AGPL-3.0 license and may not use the KidoX name, logo, icon, or brand assets in a way that suggests an official release or endorsement.

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

Local builds are intended for evaluation, review, and development. If you distribute modified builds, you are responsible for complying with AGPL-3.0 and for removing or replacing reserved KidoX brand assets where required.

## Packaging

The DMG helper lives at `Packaging/DMG/build-dmg.sh`.

Release packaging requires local signing, notarization, and production configuration that are intentionally not committed to this repository. Local files such as `Packaging/DMG/release.env` are ignored and should not be committed.

## Maintainers

- [defcc](https://github.com/defcc)

## Contributing

Issues and pull requests are welcome when they improve the app, documentation, reliability, or security.

By submitting a contribution, you agree to license your contribution under AGPL-3.0 and confirm that you have the right to do so. For substantial contributions that may be included in dual-licensed or commercial-license-exempt releases, the maintainers may ask you to sign a contributor license agreement before merging.

## Disclaimer

This repository is the source distribution for KidoX Community Edition. It is not an official distribution channel for signed, notarized KidoX binaries.

## License

KidoX Community Edition is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0), available at <https://www.gnu.org/licenses/agpl-3.0.html>.

Use of KidoX Community Edition for commercial purposes is permitted, subject to full compliance with the terms and conditions of the AGPL-3.0 license.

If you require a commercial license that provides an exemption from the AGPL-3.0 requirements, please contact us at <support@kidox.app>.

The KidoX name, logo, icon, website assets, signing keys, release infrastructure, and other brand assets are not licensed under AGPL-3.0 unless explicitly stated otherwise.
