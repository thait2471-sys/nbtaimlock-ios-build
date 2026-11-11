#!/usr/bin/env bash
# Sign the clean unsigned NBTAimlock IPA with an Apple certificate + profile.
#
# Why this script exists
# ----------------------
# The app binary is already compiled. iOS only refuses to install when the
# bundle is structurally invalid or when the signature/profile pair is wrong.
# This script takes the structurally valid unsigned IPA and produces a signed
# IPA that a stock iPhone can install over the air or through Apple Configurator.
#
# Requirements: macOS with Xcode Command Line Tools (codesign, security,
# PlistBuddy). The certificate must already be in the login keychain, or run
# this from the GitHub Actions workflow that imports it.
#
# Usage:
#   export PROVISIONING_PROFILE=/path/to/profile.mobileprovision
#   export SIGNING_IDENTITY="Apple Development: Name (TEAMID)"   # optional
#   export BUNDLE_ID=com.nbtaimlock.ios                          # optional
#   bash tools/sign_existing_ipa.sh <unsigned.ipa> <signed.ipa>
#
# Do NOT commit the .p12, its password, or the .mobileprovision to the repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_DIR="$PWD"

IPA_IN="${1:-}"
IPA_OUT="${2:-build/nbtaimlock-signed.ipa}"
BUNDLE_ID="${BUNDLE_ID:-com.nbtaimlock.ios}"
: "${PROVISIONING_PROFILE:?PROVISIONING_PROFILE must point to a .mobileprovision file}"

# Resolve the destination before entering the temporary unpack directory. A
# relative destination must remain relative to the caller, not to WORK.
if [[ "$IPA_OUT" != /* ]]; then
  IPA_OUT="$CALLER_DIR/$IPA_OUT"
fi
mkdir -p "$(dirname "$IPA_OUT")"
IPA_OUT="$(cd "$(dirname "$IPA_OUT")" && pwd)/$(basename "$IPA_OUT")"

if [[ -z "$IPA_IN" || ! -f "$IPA_IN" ]]; then
  echo "Usage: PROVISIONING_PROFILE=... bash tools/sign_existing_ipa.sh <unsigned.ipa> [signed.ipa]" >&2
  exit 2
fi
if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
  echo "Provisioning profile not found: $PROVISIONING_PROFILE" >&2
  exit 2
fi
command -v codesign >/dev/null || { echo "codesign not found — run this on macOS with Xcode CLT" >&2; exit 1; }
command -v security >/dev/null || { echo "security not found — macOS only" >&2; exit 1; }
command -v /usr/libexec/PlistBuddy >/dev/null || { echo "PlistBuddy not found — macOS only" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found — install Xcode Command Line Tools" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/nbt_sign.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> Unpacking $IPA_IN"
# ditto keeps POSIX modes and symlinks and never injects __MACOSX, which is a
# documented cause of "Unable to Install, please try again later" on iOS.
mkdir -p "$WORK/unpack"
ditto -x -k "$IPA_IN" "$WORK/unpack"
APP="$(find "$WORK/unpack/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
if [[ -z "$APP" ]]; then
  echo "No Payload/*.app found in the IPA" >&2
  exit 1
fi
echo "    bundle: $APP"

echo "==> Reading provisioning profile"
security cms -D -i "$PROVISIONING_PROFILE" > "$WORK/profile.plist"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$WORK/profile.plist" 2>/dev/null || true)"
TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$WORK/profile.plist" 2>/dev/null || true)"
if [[ -z "$PROFILE_APP_ID" || -z "$TEAM_ID" ]]; then
  echo "Profile is missing application-identifier or TeamIdentifier" >&2
  exit 1
fi
PROFILE_SUFFIX="${PROFILE_APP_ID#*.}"
# A profile is a wildcard only when its suffix is exactly "*" or "TEAM.*".
# Matching *".*" made every concrete App ID (com.nbtaimlock.ios) look like a
# wildcard, which disabled the bundle-id check below and let this script sign
# a bundle with a profile issued for a different app. The device then refuses
# with "Unable to Install, please try again later" — the exact reported bug.
IS_WILDCARD=0
if [[ "$PROFILE_SUFFIX" == "*" ]]; then
  IS_WILDCARD=1
fi
PROFILE_TEAM_FROM_APP_ID="${PROFILE_APP_ID%%.*}"
if [[ "$PROFILE_TEAM_FROM_APP_ID" != "$TEAM_ID" ]]; then
  echo "Provisioning profile team mismatch: application-identifier uses '$PROFILE_TEAM_FROM_APP_ID', TeamIdentifier is '$TEAM_ID'." >&2
  exit 1
fi
echo "    profile app id: $PROFILE_APP_ID (team $TEAM_ID, wildcard=$IS_WILDCARD)"

# A profile the device cannot accept is the single most common cause of
# "Unable to Install". Fail here with the reason instead of on the device.
# The App ID check lives here as well as in the shell: a glob mistake in the
# shell previously let a profile for another app through, so the rule is
# re-asserted in Python where string handling is unambiguous.
echo "==> Checking profile validity"
python3 - "$WORK/profile.plist" "$BUNDLE_ID" <<'PY'
import plistlib, sys
from datetime import datetime, timezone

with open(sys.argv[1], "rb") as fh:
    prof = plistlib.load(fh)
bundle_id = sys.argv[2]

expires = prof.get("ExpirationDate")
if not isinstance(expires, datetime):
    raise SystemExit("FAIL: profile has no ExpirationDate")
if expires.tzinfo is None:
    expires = expires.replace(tzinfo=timezone.utc)
if expires <= datetime.now(timezone.utc):
    raise SystemExit(f"FAIL: profile expired at {expires}")

app_id = str((prof.get("Entitlements") or {}).get("application-identifier", ""))
suffix = app_id.split(".", 1)[1] if "." in app_id else ""
is_wildcard = suffix == "*"
if not is_wildcard and suffix != bundle_id:
    raise SystemExit(
        f"FAIL: profile is issued for '{app_id}' but the bundle is '{bundle_id}'. "
        "iOS rejects that pair with 'Unable to Install'. Use a profile whose App ID "
        "matches the bundle, or a true wildcard profile (TEAMID.*)."
    )

if prof.get("ProvisionsAllDevices"):
    kind = "enterprise (any device)"
else:
    devices = prof.get("ProvisionedDevices") or []
    if not devices:
        raise SystemExit(
            "FAIL: profile has no ProvisionedDevices and is not enterprise. "
            "An App Store / distribution profile cannot be installed over OTA."
        )
    kind = f"ad-hoc ({len(devices)} registered UDID(s))"

print(f"    valid until {expires} — {kind}")
print(f"    app id: {app_id}" + (" (wildcard)" if is_wildcard else ""))
print("    WARNING: the target iPhone's UDID must be listed in this profile"
      " or the install will fail on the device."
      if not prof.get("ProvisionsAllDevices") else "")
PY

ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "Bundle id mismatch: IPA has '$ACTUAL_BUNDLE_ID', expected '$BUNDLE_ID'" >&2
  echo "Refusing to rewrite the bundle id silently — rebuild with the right PRODUCT_BUNDLE_IDENTIFIER." >&2
  exit 1
fi
if [[ "$IS_WILDCARD" -eq 0 && "$PROFILE_SUFFIX" != "$BUNDLE_ID" ]]; then
  echo "Provisioning profile is for '$PROFILE_APP_ID', not '$BUNDLE_ID'." >&2
  echo "Use a profile whose App ID matches the bundle, or a wildcard profile." >&2
  exit 1
fi

# iOS refuses a bundle whose Info.plist lost these keys. Signing cannot add
# them back, so catch it before spending a signing cycle.
echo "==> Checking bundle metadata"
PLATFORMS="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms' "$APP/Info.plist" 2>/dev/null || true)"
case "$PLATFORMS" in
  *iPhoneOS*) ;;
  *) echo "FAIL: Info.plist lacks CFBundleSupportedPlatforms=iPhoneOS — iOS will refuse the install" >&2; exit 1 ;;
esac
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist" 2>/dev/null || true)"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null || true)"
if ! [[ "$BUNDLE_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "FAIL: CFBundleVersion '$BUNDLE_VERSION' is not a numeric build number — the OTA manifest cannot advertise it" >&2
  exit 1
fi
echo "    CFBundleIdentifier=$ACTUAL_BUNDLE_ID"
echo "    CFBundleShortVersionString=$SHORT_VERSION"
echo "    CFBundleVersion=$BUNDLE_VERSION  (OTA manifest must use this value)"

echo "==> Exporting entitlements from the profile"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/profile.plist" > "$WORK/entitlements.plist"
# A wildcard profile ships template entitlements (TEAMID.*). codesign needs the
# concrete application identifier, otherwise AMFI rejects the signature.
python3 - "$WORK/entitlements.plist" "$TEAM_ID" "$BUNDLE_ID" "$IS_WILDCARD" <<'PY'
import plistlib, sys
path, team, bundle, wildcard = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
with open(path, "rb") as fh:
    ent = plistlib.load(fh)
concrete = f"{team}.{bundle}"
ent["application-identifier"] = concrete
if wildcard:
    for key, value in list(ent.items()):
        if isinstance(value, str) and value == f"{team}.*":
            ent[key] = concrete
        elif isinstance(value, list):
            ent[key] = [concrete if v == f"{team}.*" else v for v in value]
with open(path, "wb") as fh:
    plistlib.dump(ent, fh)
print("    entitlements:", ", ".join(sorted(ent.keys())))
PY

echo "==> Cleaning previous signature artifacts"
rm -rf "$APP/_CodeSignature" "$APP/SC_Info"
rm -f "$APP/embedded.mobileprovision"
find "$APP" -name '.DS_Store' -delete || true
find "$APP" -name '._*' -delete || true

echo "==> Embedding provisioning profile"
cp "$PROVISIONING_PROFILE" "$APP/embedded.mobileprovision"

if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple (Development|Distribution|iPhone)/ {print $2; exit}')"
fi
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  echo "No Apple code-signing identity found. Import the .p12 into the keychain first." >&2
  security find-identity -v -p codesigning >&2 || true
  exit 1
fi
echo "==> Signing with: $SIGNING_IDENTITY"

# Codesign refuses to accept a signature if any nested code is unsigned or
# signed with a different identity, so sign deepest code first. `find -depth`
# walks children before parents, which is exactly the required order.
echo "==> Signing nested code (deepest first)"
NESTED_COUNT=0
while IFS= read -r -d '' nested; do
  case "$nested" in
    *.app/PlugIns/*|*.app/Frameworks/*|*.app/AppClips/*|*.app/Watch/*|*/Frameworks/*)
      echo "    codesign $(basename "$nested")"
      codesign -f -s "$SIGNING_IDENTITY" --timestamp=none "$nested"
      NESTED_COUNT=$((NESTED_COUNT + 1))
      ;;
  esac
done < <(find "$APP" -depth \
           \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' -o -name '*.bundle' \) \
           -print0 2>/dev/null || true)
echo "    nested bundles signed: $NESTED_COUNT"

codesign -f -s "$SIGNING_IDENTITY" \
  --entitlements "$WORK/entitlements.plist" \
  --generate-entitlement-der \
  --timestamp=none \
  "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# `codesign -d` only succeeds when the signature is readable; it also prints the
# identifier, which must match the bundle id the device expects.
codesign -d --entitlements :- "$APP" > "$WORK/signed_entitlements.plist" 2>/dev/null || true
if [[ ! -s "$WORK/signed_entitlements.plist" ]]; then
  echo "WARNING: could not read the signed entitlements back from the bundle" >&2
fi

echo "==> Repacking IPA"
mkdir -p "$(dirname "$IPA_OUT")"
rm -f "$IPA_OUT"
# The archive root must be the `Payload/` directory — iOS looks for
# Payload/<Name>.app and nothing else. Pass the Payload dir itself with
# --keepParent so the entry prefix is exactly "Payload/".
#
# --norsrc/--noextattr/--noqtn/--noacl matter: plain `zip` and ditto's default
# both emit __MACOSX entries and AppleDouble ._* files from extended
# attributes, and an IPA containing them fails to install.
PAYLOAD_DIR="$WORK/unpack/Payload"
if [[ ! -d "$PAYLOAD_DIR" ]]; then
  echo "Payload directory vanished before repack: $PAYLOAD_DIR" >&2
  exit 1
fi
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$PAYLOAD_DIR" "$IPA_OUT"

echo "==> Checking archive layout"
python3 - "$IPA_OUT" <<'PY'
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
roots = {n.split("/", 1)[0] for n in names if n}
if roots != {"Payload"}:
    raise SystemExit(f"FAIL: archive roots must be exactly ['Payload'], found {sorted(roots)}")
junk = [n for n in names if "__MACOSX" in n or "/._" in n or n.startswith("._")]
if junk:
    raise SystemExit(f"FAIL: resource-fork entries in IPA: {junk[:5]}")
apps = {n.split("/")[1] for n in names if n.count("/") >= 2}
print(f"    roots={sorted(roots)} apps={sorted(apps)} entries={len(names)}")
PY

echo "==> Running installability gate"
# The gate must know which app it is looking at. A Swift build links
# libswiftCore; the reviewed legacy native build links only the five system
# libraries and carries no Swift runtime. Hard-coding the flag would break the
# Swift path, and omitting it made every successful legacy signing run exit 1 at
# its last step — an operator who skips the exit code then publishes an IPA the
# gate had already rejected. Detect instead of guess, and pass the matching
# assertion. The legacy flag is not a bypass: the gate still verifies the five
# linked dylibs, the five markers and minos 14.0.0 for that build.
GATE_FLAGS=()
# Read CFBundleExecutable rather than assuming the executable is named after the
# bundle — a mismatch would make the probe inspect the wrong file and silently
# choose the wrong gate.
if ! python3 - "$IPA_OUT" <<'PY'
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as zf:
    names = zf.namelist()
    app = next(n.split("/")[1] for n in names
               if n.count("/") >= 2 and n.split("/")[0] == "Payload" and n.split("/")[1].endswith(".app"))
    prefix = f"Payload/{app}/"
    info = plistlib.loads(zf.read(prefix + "Info.plist"))
    binary = zf.read(prefix + info["CFBundleExecutable"])
sys.exit(0 if b"libswift" in binary else 1)
PY
then
  GATE_FLAGS+=(--legacy-native)
  echo "    binary has no Swift runtime — gating as the reviewed legacy native app"
else
  echo "    binary links the Swift runtime — gating as a Swift build"
fi
python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validate_ios_release.py" \
  "${GATE_FLAGS[@]}" "$IPA_OUT"

echo ""
echo "Signed IPA: $IPA_OUT"
echo "SHA-256:    $(shasum -a 256 "$IPA_OUT" | awk '{print $1}')"
echo "Bytes:      $(wc -c < "$IPA_OUT" | tr -d ' ')"
echo ""
echo "OTA manifest values (paste into Admin when publishing):"
echo "  bundle-identifier : $ACTUAL_BUNDLE_ID"
echo "  bundle-version    : $BUNDLE_VERSION"
