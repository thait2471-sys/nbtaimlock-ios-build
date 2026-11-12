#!/usr/bin/env bash
# Build and export an installable NABATI AIMLOCK IPA.
#
# MUST run on macOS with Xcode 15+ (Command Line Tools included).
# Why: compiling Swift for arm64-apple-ios, compiling Assets.xcassets into
# Assets.car, and producing an Apple CMS signature all require Apple's toolchain
# and an Apple Developer identity. Neither can be reproduced on Windows.
#
# Usage:
#   export TEAM_ID=ABCDE12345                 # Apple Developer Team ID
#   export METHOD=ad-hoc                      # development | ad-hoc
#   export BUNDLE_ID=com.nbtaimlock.ios
#   bash tools/build_ios_ipa.sh
#
# Optional:
#   export KEYCHAIN_PATH=$HOME/Library/Keychains/nabati-signing.keychain-db
#   export EXPORT_OPTIONS_PLIST=/path/to/custom-ExportOptions.plist
#
# Output: build/export/nbtaimlock-release.ipa (then run validate_ios_release.py)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT/NBTAimlock"
PROJECT="$PROJECT_DIR/NBTAimlock.xcodeproj"
SCHEME="NBTAimlock"
CONFIG="Release"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/NBTAimlock.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
METHOD="${METHOD:-ad-hoc}"
TEAM_ID="${TEAM_ID:?TEAM_ID is required (Apple Developer Team ID)}"
BUNDLE_ID="${BUNDLE_ID:-com.nbtaimlock.ios}"

# Only exports that carry device authorisation can be installed from a direct /
# OTA link:
#   development — installs on the UDIDs registered in the profile
#   ad-hoc      — installs on the UDIDs registered in the profile
#   enterprise  — In-House profile; installs on any device (requires the paid
#                 Apple Developer Enterprise Programme and an In-House cert)
# An app-store export has no device authorisation at all, so publishing it
# would produce exactly the "Không thể cài đặt, vui lòng thử lại sau" customers
# see. Reject it here rather than after the upload.
case "$METHOD" in
  development|ad-hoc|enterprise) ;;
  app-store)
    echo "METHOD=app-store cannot be installed from a direct/OTA link." >&2
    echo "Use METHOD=ad-hoc (registered UDIDs), development, or enterprise (In-House)." >&2
    exit 2
    ;;
  *)
    echo "Unknown METHOD='$METHOD'. Supported: development | ad-hoc | enterprise" >&2
    exit 2
    ;;
esac

echo "==> Preflight"
command -v xcodebuild >/dev/null || { echo "xcodebuild not found — install Xcode"; exit 1; }
command -v xcrun >/dev/null || { echo "xcrun not found — install Xcode"; exit 1; }
xcodebuild -version

echo "==> Verifying signing identity for team $TEAM_ID"
# A keychain can hold identities for several teams. Signing with a certificate
# from a different team than the provisioning profile is one of the most common
# causes of an IPA that installs on nothing. Match the team explicitly.
if ! security find-identity -v -p codesigning | grep -q "($TEAM_ID)"; then
  echo "No code-signing identity for team $TEAM_ID in the keychain."
  echo "Present identities:"
  security find-identity -v -p codesigning || true
  echo "Import your Apple Developer .p12 certificate first (Keychain Access)."
  exit 1
fi

echo "==> Cleaning previous artifacts"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_DIR"

echo "==> Archiving ($CONFIG, generic iOS device)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_STYLE=Automatic \
  archive

if [[ ! -d "$ARCHIVE" ]]; then
  echo "Archive failed — no .xcarchive produced"
  exit 1
fi

echo "==> Asserting the archived binary is the Swift build"
ARCHIVED_APP="$ARCHIVE/Products/Applications/NBTAimlock.app"
if [[ -d "$ARCHIVED_APP" ]]; then
  # A Swift app links libswiftCore.dylib, or — if statically linked — carries
  # __swift5_* sections. "grep -q Swift" is wrong: it also matches unrelated
  # framework names (e.g. /usr/lib/swift/libswiftAVFoundation is fine, but a
  # pure-ObjC binary named *Swift* would pass), so test the two real signals.
  if otool -L "$ARCHIVED_APP/NBTAimlock" | grep -q "libswift"; then
    echo "    Swift runtime linked"
  else
    otool -l "$ARCHIVED_APP/NBTAimlock" | grep -q "__swift5_" \
      || {
        echo "ARCHIVED BINARY IS NOT THE SWIFT BUILD." >&2
        echo "The sources are Swift/SwiftUI. This binary links no libswift*" >&2
        echo "dylib and has no __swift5_* sections, so it cannot be the app" >&2
        echo "in this repository. Refusing to export it as a release." >&2
        otool -L "$ARCHIVED_APP/NBTAimlock" >&2
        exit 1
      }
    echo "    Swift metadata (__swift5_*) present"
  fi
fi

echo "==> Writing ExportOptions.plist ($METHOD)"
EXPORT_OPTIONS="${EXPORT_OPTIONS_PLIST:-$BUILD_DIR/ExportOptions.plist}"
if [[ ! -f "$EXPORT_OPTIONS" ]]; then
  cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>$METHOD</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>compileBitcode</key>
  <false/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
PLIST
fi

echo "==> Exporting IPA"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -1)"
if [[ -z "$IPA" ]]; then
  echo "Export produced no .ipa"
  exit 1
fi

echo "==> Validating exported IPA"
python3 "$ROOT/tools/validate_ios_release.py" "$IPA"

echo ""
echo "IPA ready: $IPA"
echo "SHA-256:  $(shasum -a 256 "$IPA" | awk '{print $1}')"
echo "Bytes:    $(wc -c < "$IPA" | tr -d ' ')"
echo ""
echo "Next: upload this IPA somewhere HTTPS-reachable, then paste that URL"
echo "in Admin → Phiên bản mới → iOS. No app rebuild is needed for future"
echo "link changes: Admin publishes the URL and the OTA manifest reads it live."
