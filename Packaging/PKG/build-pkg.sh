#!/usr/bin/env bash
set -euo pipefail

# KidoX PKG release builder.
#
# Default:
#   Packaging/PKG/build-pkg.sh
#
# Use a specific app bundle instead of the release DMG:
#   APP_PATH=/path/to/KidoX.app Packaging/PKG/build-pkg.sh
#
# Use a specific DMG:
#   SOURCE_DMG=/path/to/KidoX.dmg Packaging/PKG/build-pkg.sh

APP_NAME="KidoX"
SCHEME="KidoX"
PROJECT="KidoXApp.xcodeproj"
CONFIGURATION="Release"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

default_pkg_version() {
  local build_settings
  local marketing_version
  local build_version

  build_settings="$(
    xcodebuild \
      -project "$ROOT_DIR/$PROJECT" \
      -target "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -showBuildSettings 2>/dev/null
  )"
  marketing_version="$(printf '%s\n' "$build_settings" | awk '$1 == "MARKETING_VERSION" { print $3; exit }')"
  build_version="$(printf '%s\n' "$build_settings" | awk '$1 == "CURRENT_PROJECT_VERSION" { print $3; exit }')"

  if [[ -n "$marketing_version" && -n "$build_version" ]]; then
    printf '%s-build%s' "$marketing_version" "$build_version"
    return
  fi

  printf '%s' "${marketing_version:-unknown}"
}

PKG_VERSION="${PKG_VERSION:-$(default_pkg_version)}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/Releases}"
OUTPUT_PKG="${OUTPUT_PKG:-$OUTPUT_DIR/${APP_NAME}-${PKG_VERSION}.pkg}"
SOURCE_DMG="${SOURCE_DMG:-$OUTPUT_DIR/${APP_NAME}-${PKG_VERSION}.dmg}"
APP_PATH="${APP_PATH:-}"

DEVELOPER_ID_INSTALLER="${DEVELOPER_ID_INSTALLER:-}"
AUTO_DETECT_DEVELOPER_ID_INSTALLER="${AUTO_DETECT_DEVELOPER_ID_INSTALLER:-1}"
REQUIRE_SIGNING="${REQUIRE_SIGNING:-1}"
NOTARIZE="${NOTARIZE:-1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-kidox-notary}"

TMP_DIR="${KIDOX_PKG_TMP_DIR:-/private/tmp/KidoXPKG}"
MOUNT_DIR="$TMP_DIR/mount"

log() {
  printf '\n==> %s\n' "$*"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

detect_developer_id_installer() {
  if [[ -n "$DEVELOPER_ID_INSTALLER" ]] || [[ "$AUTO_DETECT_DEVELOPER_ID_INSTALLER" != "1" ]]; then
    return
  fi

  local identity_line
  identity_line="$(/usr/bin/security find-identity -v -p basic 2>/dev/null | grep 'Developer ID Installer:' | head -n 1 || true)"

  if [[ -z "$identity_line" ]]; then
    return
  fi

  DEVELOPER_ID_INSTALLER="${identity_line#*\"}"
  DEVELOPER_ID_INSTALLER="${DEVELOPER_ID_INSTALLER%\"*}"
}

detach_mount_if_present() {
  if /sbin/mount | /usr/bin/grep -q " on ${MOUNT_DIR} "; then
    /usr/bin/hdiutil detach "$MOUNT_DIR" >/dev/null || true
  fi
}

cleanup() {
  detach_mount_if_present
}

source_app_path() {
  if [[ -n "$APP_PATH" ]]; then
    printf '%s' "$APP_PATH"
    return
  fi

  if [[ ! -f "$SOURCE_DMG" ]]; then
    echo "Missing SOURCE_DMG: $SOURCE_DMG" >&2
    echo "Pass APP_PATH=/path/to/KidoX.app or SOURCE_DMG=/path/to/KidoX.dmg." >&2
    exit 1
  fi

  mkdir -p "$MOUNT_DIR"
  detach_mount_if_present

  log "Mounting $SOURCE_DMG"
  /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$SOURCE_DMG" >/dev/null

  printf '%s/%s.app' "$MOUNT_DIR" "$APP_NAME"
}

require_tool xcodebuild
require_tool productbuild
require_tool pkgutil
require_tool hdiutil
require_tool shasum

detect_developer_id_installer

if [[ -z "$DEVELOPER_ID_INSTALLER" ]]; then
  if [[ "$REQUIRE_SIGNING" == "1" ]]; then
    echo "DEVELOPER_ID_INSTALLER is required when REQUIRE_SIGNING=1." >&2
    exit 1
  fi

  echo "Refusing to create an unsigned package. Set REQUIRE_SIGNING=0 only for local experiments." >&2
  exit 1
fi

trap cleanup EXIT

mkdir -p "$TMP_DIR" "$OUTPUT_DIR"
rm -f "$OUTPUT_PKG"

SOURCE_APP="$(source_app_path)"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing app bundle: $SOURCE_APP" >&2
  exit 1
fi

log "Verifying source app signature"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"

log "Building signed installer package"
/usr/bin/productbuild \
  --component "$SOURCE_APP" /Applications \
  --sign "$DEVELOPER_ID_INSTALLER" \
  --timestamp \
  "$OUTPUT_PKG"

log "Checking package signature"
/usr/sbin/pkgutil --check-signature "$OUTPUT_PKG"

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "NOTARY_PROFILE is required when NOTARIZE=1." >&2
    exit 1
  fi

  log "Submitting package for notarization with keychain profile $NOTARY_PROFILE"
  /usr/bin/xcrun notarytool submit "$OUTPUT_PKG" --keychain-profile "$NOTARY_PROFILE" --wait

  log "Stapling notarization ticket"
  /usr/bin/xcrun stapler staple "$OUTPUT_PKG"
  /usr/bin/xcrun stapler validate "$OUTPUT_PKG"

  log "Assessing notarized package with Gatekeeper"
  if ! /usr/sbin/spctl --assess --type install --verbose=4 "$OUTPUT_PKG"; then
    echo "Warning: spctl assessment failed. The package was accepted by notarytool and stapler validate passed." >&2
  fi
else
  log "Skipping notarization because NOTARIZE is not 1"
fi

shasum -a 256 "$OUTPUT_PKG"
echo "Wrote $OUTPUT_PKG"
