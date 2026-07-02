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

- [defcc](https://github.com/defcc)

## Contributing

Issues and pull requests are welcome when they improve the app, documentation, reliability, or security.

By submitting a contribution, you agree that the maintainers may use, modify, distribute, and include your contribution in official KidoX releases.

## Disclaimer

This repository is provided as a source-visible reference for the KidoX macOS app. It is not an official distribution channel for compiled binaries.

## License

No open-source license is granted.

The source code is made available only under the source-availability terms described above. All rights not expressly granted are reserved by the copyright holders. The KidoX name, logo, icon, and related brand assets are reserved.
