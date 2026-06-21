# KidoX

KidoX is a macOS launcher app built with Swift and SwiftUI.

This repository contains the macOS app source, Xcode project, shared IPC code, Dock tile plug-in, resources, and local DMG packaging scripts. The license-management backend is not included in this app repository.

## Requirements

- macOS with Xcode installed
- Xcode command line tools

## Build

Open `KidoXApp.xcodeproj` in Xcode and run the `KidoX` scheme, or build from the command line:

```sh
xcodebuild -project KidoXApp.xcodeproj -scheme KidoX -configuration Debug build
```

## Packaging

The DMG helper lives at `Packaging/DMG/build-dmg.sh`.

Local release configuration files such as `Packaging/DMG/release.env` are ignored and should not be committed.
