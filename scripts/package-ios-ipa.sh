#!/usr/bin/env bash

# Build scarf mobile for a physical iOS device and wrap the .app in an IPA.
# Signing is intentionally off — no Apple Developer account required.
#
# The resulting IPA will not install on a stock iPhone until a sideloading
# tool (AltStore, Sideloadly, TrollStore, etc.) re-signs it. This script
# only produces the archive.

# --- Xcode toolchain guard: build with a real Xcode.app (not the Command Line Tools), resolved via
#     DEVELOPER_DIR (no sudo). Survives an Xcode swap that left `xcode-select` on CommandLineTools. ---
if [ -z "${DEVELOPER_DIR:-}" ]; then
  case "$(xcode-select -p 2>/dev/null)" in
    */Xcode*.app/Contents/Developer) : ;;
    *) for _xc in /Applications/Xcode.app /Applications/Xcode-*.app; do
         [ -x "$_xc/Contents/Developer/usr/bin/xcodebuild" ] && { export DEVELOPER_DIR="$_xc"; break; }
       done ;;
  esac
fi

set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT="$REPO_ROOT/scarf/scarf.xcodeproj"
SCHEME="${SCHEME:-scarf mobile}"
CONFIG="${CONFIG:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/build/DerivedData-ios}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build}"
PACKAGE_RESOLVED_REL="scarf/scarf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PACKAGE_RESOLVED="$REPO_ROOT/$PACKAGE_RESOLVED_REL"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

cleanup_generated_files() {
  if [[ "${REMOVE_GENERATED_PACKAGE_RESOLVED:-0}" == "1" && -f "$PACKAGE_RESOLVED" ]]; then
    rm -f "$PACKAGE_RESOLVED"
    rmdir "$REPO_ROOT/scarf/scarf.xcodeproj/project.xcworkspace/xcshareddata/swiftpm" 2>/dev/null || true
    rmdir "$REPO_ROOT/scarf/scarf.xcodeproj/project.xcworkspace/xcshareddata" 2>/dev/null || true
  fi
}
trap cleanup_generated_files EXIT

[[ "$(uname -s)" == "Darwin" ]] || die "this script requires macOS and Xcode (Linux cannot produce an iOS IPA)"

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found; install Xcode"
command -v ditto >/dev/null 2>&1 || die "ditto not found"

log "Xcode $(xcodebuild -version | tr '\n' ' ')"
log "iOS SDK $(xcrun --sdk iphoneos --show-sdk-version)"

log "Resolving Swift packages"
if [[ ! -e "$PACKAGE_RESOLVED" ]] && ! git -C "$REPO_ROOT" ls-files --error-unmatch "$PACKAGE_RESOLVED_REL" >/dev/null 2>&1; then
  REMOVE_GENERATED_PACKAGE_RESOLVED=1
fi
xcodebuild \
  -resolvePackageDependencies \
  -project "$PROJECT"

log "Building unsigned $CONFIG $SCHEME for generic iOS"
mkdir -p "$DERIVED_DATA" "$OUT_DIR"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  ENABLE_PREVIEWS=NO \
  ENABLE_CODE_COVERAGE=NO \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  build

APP_PATH="$DERIVED_DATA/Build/Products/${CONFIG}-iphoneos/scarf mobile.app"
[[ -d "$APP_PATH" ]] || die "build completed, but app bundle was not found at $APP_PATH"

plist_value() {
  local key="$1"
  if command -v defaults >/dev/null 2>&1; then
    defaults read "$APP_PATH/Info" "$key" 2>/dev/null || true
  fi
}
VERSION="$(plist_value CFBundleShortVersionString)"
BUILD="$(plist_value CFBundleVersion)"
VERSION="${VERSION:-unknown}"
BUILD="${BUILD:-0}"
IPA_PATH="$OUT_DIR/ScarfGo-${VERSION}-${BUILD}-unsigned.ipa"

log "Packaging Payload/scarf mobile.app → $IPA_PATH"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/scarf-ipa.XXXXXX")"
cleanup_stage() {
  rm -rf "$STAGE"
  cleanup_generated_files
}
trap cleanup_stage EXIT
mkdir -p "$STAGE/Payload"
ditto "$APP_PATH" "$STAGE/Payload/scarf mobile.app"
rm -f "$IPA_PATH"
ditto -c -k --norsrc --keepParent "$STAGE/Payload" "$IPA_PATH"

[[ -f "$IPA_PATH" ]] || die "IPA was not written"
log "IPA ready: $IPA_PATH ($(du -h "$IPA_PATH" | awk '{print $1}'))"
printf '%s\n' "$IPA_PATH"
