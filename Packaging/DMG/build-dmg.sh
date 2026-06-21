#!/usr/bin/env bash
set -euo pipefail

# KidoX DMG release builder.
#
# Local test DMG:
#   Packaging/DMG/build-dmg.sh
#
# Rebuild the DMG layout without rebuilding the app:
#   SKIP_BUILD=1 Packaging/DMG/build-dmg.sh
#
# Signed + notarized release DMG:
#   Packaging/DMG/build-dmg.sh
#
# Create the notary profile once with:
#   xcrun notarytool store-credentials kidox-notary --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#
# Edit these values while tuning the Finder window.
# create-dmg icon coordinates use Finder coordinates: origin is top-left.
# background coordinates use AppKit coordinates: origin is bottom-left.

APP_NAME="KidoX"
SCHEME="KidoX"
PROJECT="KidoXApp.xcodeproj"
CONFIGURATION="Release"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

default_dmg_version() {
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

DMG_VERSION="${DMG_VERSION:-$(default_dmg_version)}"

# Signing and notarization.
# Leave DEVELOPER_ID_APPLICATION empty to auto-detect the first available
# "Developer ID Application" identity from the login keychain.
# Set AUTO_DETECT_DEVELOPER_ID=0 to disable auto-detection for local test DMGs.
# Use NOTARIZE=0 for local unsigned/notarization-free test DMGs.
# Use REQUIRE_SIGNING=1 to fail instead of producing an unsigned DMG.
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
AUTO_DETECT_DEVELOPER_ID="${AUTO_DETECT_DEVELOPER_ID:-1}"
REQUIRE_SIGNING="${REQUIRE_SIGNING:-0}"
NOTARIZE="${NOTARIZE:-1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-kidox-notary}"
VERIFY_MOUNTED_APP="${VERIFY_MOUNTED_APP:-1}"

# Release-time Info.plist overrides. These are applied to the staged .app before
# signing, so the source Info.plist can keep development defaults.
APPCAST_URL="${APPCAST_URL:-https://kidox.app/appcast.xml}"
LICENSE_ENDPOINT_URL="${LICENSE_ENDPOINT_URL:-}"
PURCHASE_URL="${PURCHASE_URL:-https://kidox.app}"
WEBSITE_URL="${WEBSITE_URL:-https://kidox.app}"
SUPPORT_URL="${SUPPORT_URL:-https://kidox.app/support}"
HELP_URL="${HELP_URL:-https://kidox.app/help}"
REQUIRE_RELEASE_CONFIG="${REQUIRE_RELEASE_CONFIG:-0}"

WINDOW_WIDTH=720
WINDOW_HEIGHT=440
WINDOW_X=200
WINDOW_Y=120
ICON_SIZE=96

# Finder icon positions. Increase Y to move icons lower; decrease Y to move icons higher.
APP_ICON_X=170
APP_ICON_Y=225
APPLICATIONS_ICON_X=550
APPLICATIONS_ICON_Y=225

# Background arrow position. Increase Y to move arrow higher; decrease Y to move arrow lower.
ARROW_X=282
ARROW_Y=145
ARROW_WIDTH=156
ARROW_HEIGHT=73
ARROW_OPACITY=0.84

# Other background layout values.
TITLE_X=48
TITLE_Y=350
SUBTITLE_X=50
SUBTITLE_Y=324
CARD_X=56
CARD_Y=82
CARD_WIDTH=608
CARD_HEIGHT=220
FOOTER_X=50
FOOTER_Y=34

TMP_DIR="${KIDOX_DMG_TMP_DIR:-/private/tmp/KidoXDMG}"
DERIVED_DATA="$TMP_DIR/DerivedData"
STAGE_DIR="$TMP_DIR/stage"
ASSETS_DIR="$TMP_DIR/assets"
MODULE_CACHE="$TMP_DIR/swift-module-cache"
BACKGROUND_IMAGE="$ASSETS_DIR/dmg-background.png"
ARROW_IMAGE="$ROOT_DIR/Packaging/DMG/assets/install-arrow.png"
OUTPUT_DIR="$ROOT_DIR/Releases"
OUTPUT_DMG="$OUTPUT_DIR/${APP_NAME}-${DMG_VERSION}.dmg"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/${APP_NAME}.app"
STAGE_APP="$STAGE_DIR/${APP_NAME}.app"

log() {
  printf '\n==> %s\n' "$*"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

detect_developer_id_application() {
  if [[ -n "$DEVELOPER_ID_APPLICATION" ]] || [[ "$AUTO_DETECT_DEVELOPER_ID" != "1" ]]; then
    return
  fi

  local identity_line
  identity_line="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application:' | head -n 1 || true)"

  if [[ -z "$identity_line" ]]; then
    return
  fi

  DEVELOPER_ID_APPLICATION="${identity_line#*\"}"
  DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION%\"*}"
}

plist_set_string_if_present() {
  local plist="$1"
  local key="$2"
  local value="$3"

  if [[ -n "$value" ]]; then
    /usr/bin/plutil -replace "$key" -string "$value" "$plist"
  fi
}

plist_read() {
  local plist="$1"
  local key="$2"

  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

apply_release_plist_overrides() {
  local info_plist="$STAGE_APP/Contents/Info.plist"

  plist_set_string_if_present "$info_plist" "SUFeedURL" "$APPCAST_URL"
  plist_set_string_if_present "$info_plist" "KidoXLicenseEndpointURL" "$LICENSE_ENDPOINT_URL"
  plist_set_string_if_present "$info_plist" "KidoXPurchaseURL" "$PURCHASE_URL"
  plist_set_string_if_present "$info_plist" "KidoXWebsiteURL" "$WEBSITE_URL"
  plist_set_string_if_present "$info_plist" "KidoXSupportURL" "$SUPPORT_URL"
  plist_set_string_if_present "$info_plist" "KidoXHelpURL" "$HELP_URL"

  local current_appcast
  current_appcast="$(plist_read "$info_plist" "SUFeedURL")"

  if [[ "$REQUIRE_RELEASE_CONFIG" == "1" ]] && [[ "$current_appcast" =~ ^https?://(127\.0\.0\.1|localhost)(:|/) ]]; then
    echo "Refusing release build with local SUFeedURL: $current_appcast" >&2
    echo "Pass APPCAST_URL=https://... or set REQUIRE_RELEASE_CONFIG=0 for local testing." >&2
    exit 1
  fi
}

sign_app_if_requested() {
  if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
    if [[ "$REQUIRE_SIGNING" == "1" ]]; then
      echo "DEVELOPER_ID_APPLICATION is required when REQUIRE_SIGNING=1." >&2
      exit 1
    fi

    log "Skipping app signing because DEVELOPER_ID_APPLICATION is not set"
    return
  fi

  log "Signing app with $DEVELOPER_ID_APPLICATION"
  /usr/bin/codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$STAGE_APP"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGE_APP"
}

sign_dmg_if_requested() {
  if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
    log "Skipping DMG signing because DEVELOPER_ID_APPLICATION is not set"
    return
  fi

  log "Signing DMG with $DEVELOPER_ID_APPLICATION"
  /usr/bin/codesign \
    --force \
    --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$OUTPUT_DMG"

  /usr/bin/codesign --verify --verbose=2 "$OUTPUT_DMG"
}

detach_volume_if_present() {
  local volume_path

  for volume_path in "/Volumes/$APP_NAME" "/Volumes/$APP_NAME 1" "/Volumes/$APP_NAME 2" /Volumes/dmg.*; do
    [[ -e "$volume_path" ]] || continue

    if /sbin/mount | /usr/bin/grep -q " on ${volume_path} "; then
      /usr/bin/hdiutil detach "$volume_path" >/dev/null || true
    fi
  done
}

verify_mounted_app_if_signed() {
  if [[ "$VERIFY_MOUNTED_APP" != "1" ]]; then
    log "Skipping mounted app verification because VERIFY_MOUNTED_APP is not 1"
    return
  fi

  if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
    log "Skipping mounted app signature verification because the DMG is unsigned"
    return
  fi

  local mount_dir="$TMP_DIR/verify-mount"
  rm -rf "$mount_dir"
  mkdir -p "$mount_dir"

  log "Mounting DMG to verify bundled app signature"
  /usr/bin/hdiutil attach "$OUTPUT_DMG" -nobrowse -readonly -mountpoint "$mount_dir" >/dev/null

  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$mount_dir/${APP_NAME}.app"; then
    /usr/bin/hdiutil detach "$mount_dir" >/dev/null || true
    exit 1
  fi

  /usr/bin/hdiutil detach "$mount_dir" >/dev/null
}

notarize_dmg_if_requested() {
  if [[ "$NOTARIZE" != "1" ]]; then
    log "Skipping notarization because NOTARIZE is not 1"
    return
  fi

  if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
    echo "Notarization requires DEVELOPER_ID_APPLICATION." >&2
    exit 1
  fi

  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "Notarization requires NOTARY_PROFILE." >&2
    echo "Create one with: xcrun notarytool store-credentials kidox-notary --apple-id ... --team-id ... --password ..." >&2
    exit 1
  fi

  log "Submitting DMG for notarization with keychain profile $NOTARY_PROFILE"
  /usr/bin/xcrun notarytool submit "$OUTPUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait

  log "Stapling notarization ticket"
  /usr/bin/xcrun stapler staple "$OUTPUT_DMG"
  /usr/bin/xcrun stapler validate "$OUTPUT_DMG"

  log "Assessing notarized DMG with Gatekeeper"
  if ! /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$OUTPUT_DMG"; then
    echo "Warning: spctl assessment failed. The DMG was accepted by notarytool and stapler validate passed." >&2
  fi
  detach_volume_if_present
}

notarize_app_if_requested() {
  if [[ "$NOTARIZE" != "1" ]]; then
    log "Skipping app notarization because NOTARIZE is not 1"
    return
  fi

  if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
    echo "App notarization requires DEVELOPER_ID_APPLICATION." >&2
    exit 1
  fi

  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "App notarization requires NOTARY_PROFILE." >&2
    exit 1
  fi

  local app_zip="$TMP_DIR/${APP_NAME}.app.zip"
  rm -f "$app_zip"

  log "Creating app archive for notarization"
  /usr/bin/ditto -c -k --keepParent "$STAGE_APP" "$app_zip"

  log "Submitting app for notarization with keychain profile $NOTARY_PROFILE"
  /usr/bin/xcrun notarytool submit "$app_zip" --keychain-profile "$NOTARY_PROFILE" --wait

  log "Stapling notarization ticket to app"
  /usr/bin/xcrun stapler staple "$STAGE_APP"
  /usr/bin/xcrun stapler validate "$STAGE_APP"

  log "Assessing notarized app with Gatekeeper"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$STAGE_APP"
}

require_tool xcodebuild
require_tool swift
require_tool create-dmg
require_tool hdiutil
require_tool shasum
detect_developer_id_application

if [[ -n "$DEVELOPER_ID_APPLICATION" ]]; then
  log "Using signing identity: $DEVELOPER_ID_APPLICATION"
fi

detach_volume_if_present

mkdir -p "$TMP_DIR" "$DERIVED_DATA" "$STAGE_DIR" "$ASSETS_DIR" "$MODULE_CACHE" "$OUTPUT_DIR"
rm -rf "$STAGE_DIR" "$BACKGROUND_IMAGE" "$OUTPUT_DMG"
mkdir -p "$STAGE_DIR"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  log "Building $APP_NAME"
  xcodebuild \
    -project "$ROOT_DIR/$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
    build
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing app bundle: $APP_BUNDLE" >&2
  exit 1
fi

log "Staging app"
/usr/bin/ditto "$APP_BUNDLE" "$STAGE_APP"

log "Applying release Info.plist overrides"
apply_release_plist_overrides

sign_app_if_requested
notarize_app_if_requested

log "Rendering DMG background"
env \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  DMG_BACKGROUND_OUTPUT="$BACKGROUND_IMAGE" \
  DMG_ARROW_IMAGE="$ARROW_IMAGE" \
  DMG_WINDOW_WIDTH="$WINDOW_WIDTH" \
  DMG_WINDOW_HEIGHT="$WINDOW_HEIGHT" \
  DMG_TITLE_X="$TITLE_X" \
  DMG_TITLE_Y="$TITLE_Y" \
  DMG_SUBTITLE_X="$SUBTITLE_X" \
  DMG_SUBTITLE_Y="$SUBTITLE_Y" \
  DMG_CARD_X="$CARD_X" \
  DMG_CARD_Y="$CARD_Y" \
  DMG_CARD_WIDTH="$CARD_WIDTH" \
  DMG_CARD_HEIGHT="$CARD_HEIGHT" \
  DMG_ARROW_X="$ARROW_X" \
  DMG_ARROW_Y="$ARROW_Y" \
  DMG_ARROW_WIDTH="$ARROW_WIDTH" \
  DMG_ARROW_HEIGHT="$ARROW_HEIGHT" \
  DMG_ARROW_OPACITY="$ARROW_OPACITY" \
  DMG_FOOTER_X="$FOOTER_X" \
  DMG_FOOTER_Y="$FOOTER_Y" \
  swift "$ROOT_DIR/Packaging/DMG/MakeDMGBackground.swift"

log "Creating DMG"
create-dmg \
  --volname "$APP_NAME" \
  --volicon "$ROOT_DIR/Resources/Icons/KidoX.icns" \
  --background "$BACKGROUND_IMAGE" \
  --window-pos "$WINDOW_X" "$WINDOW_Y" \
  --window-size "$WINDOW_WIDTH" "$WINDOW_HEIGHT" \
  --text-size 12 \
  --icon-size "$ICON_SIZE" \
  --icon "${APP_NAME}.app" "$APP_ICON_X" "$APP_ICON_Y" \
  --app-drop-link "$APPLICATIONS_ICON_X" "$APPLICATIONS_ICON_Y" \
  --no-internet-enable \
  --format UDZO \
  "$OUTPUT_DMG" \
  "$STAGE_DIR"

sign_dmg_if_requested
verify_mounted_app_if_signed
notarize_dmg_if_requested

hdiutil verify "$OUTPUT_DMG"
shasum -a 256 "$OUTPUT_DMG"

echo "Wrote $OUTPUT_DMG"
