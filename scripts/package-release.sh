#!/bin/zsh
set -euo pipefail
umask 022

AGENTSWAP_PACKAGE_COMMAND="$0"
fail() { print -u2 -r -- "Release packaging: $1"; exit 1; }
usage() { print -r -- "Usage: $AGENTSWAP_PACKAGE_COMMAND VERSION (X.Y.Z or X.Y.Z-prerelease; build number defaults to the source commit timestamp)"; }
if (( $# == 1 )) && [[ "$1" == --help ]]; then usage; exit 0; fi
if (( $# != 1 )); then usage >&2; exit 64; fi

AGENTSWAP_RELEASE_VERSION="$1"
AGENTSWAP_VERSION_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
[[ "$AGENTSWAP_RELEASE_VERSION" =~ "$AGENTSWAP_VERSION_PATTERN" ]] || fail "VERSION must be X.Y.Z with an optional SemVer prerelease."
(( ${#AGENTSWAP_RELEASE_VERSION} <= 192 )) || fail "VERSION is too long for the artifact filename."
if [[ "$AGENTSWAP_RELEASE_VERSION" == *-* ]]; then
    AGENTSWAP_PRERELEASE="${AGENTSWAP_RELEASE_VERSION#*-}"
    for AGENTSWAP_IDENTIFIER in "${(@s:.:)AGENTSWAP_PRERELEASE}"; do
        if [[ "$AGENTSWAP_IDENTIFIER" =~ '^[0-9]+$' && "$AGENTSWAP_IDENTIFIER" == 0?* ]]; then
            fail "Numeric prerelease identifiers cannot have leading zeroes."
        fi
    done
fi
AGENTSWAP_BUNDLE_VERSION="${AGENTSWAP_RELEASE_VERSION%%-*}"
# Capture CI's secret without exporting it to Xcode or its build subprocesses.
# Local releases use Sparkle's dedicated Keychain account instead.
AGENTSWAP_SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"
unset SPARKLE_PRIVATE_KEY

AGENTSWAP_ROOT="${0:A:h:h}"
AGENTSWAP_VAULT_PIN="$AGENTSWAP_ROOT/scripts/signing/vault-service-v1.json"
[[ -f "$AGENTSWAP_VAULT_PIN" && ! -L "$AGENTSWAP_VAULT_PIN" ]] || fail "The reviewed frozen vault service pin is required before packaging an app."
/usr/bin/python3 "$AGENTSWAP_ROOT/scripts/fetch-vault-service.py" \
    --pin "$AGENTSWAP_VAULT_PIN" \
    --verify-source-pin "$AGENTSWAP_ROOT/AgentSwapCore/Sources/AgentSwapCore/AppVaultTransport.swift"
[[ "$AGENTSWAP_ROOT" != *$'\n'* && "$AGENTSWAP_ROOT" != *$'\r'* ]] || fail "The workspace path cannot contain line breaks."
AGENTSWAP_RELEASE_WORK_ROOT="$AGENTSWAP_ROOT/build/ReleasePackage"
AGENTSWAP_RELEASE_OUTPUT_ROOT="$AGENTSWAP_ROOT/build/releases"
AGENTSWAP_RELEASE_OUTPUT_DIR="$AGENTSWAP_RELEASE_OUTPUT_ROOT/$AGENTSWAP_RELEASE_VERSION"
AGENTSWAP_ZIP_NAME="AgentSwap-${AGENTSWAP_RELEASE_VERSION}-universal.zip"
[[ ! -e "$AGENTSWAP_RELEASE_OUTPUT_DIR" && ! -L "$AGENTSWAP_RELEASE_OUTPUT_DIR" ]] || fail "Artifacts for VERSION already exist; move them explicitly before packaging again."
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    [[ -f "$GITHUB_OUTPUT" && ! -L "$GITHUB_OUTPUT" && -w "$GITHUB_OUTPUT" ]] || fail "GITHUB_OUTPUT must name an existing writable regular file."
fi

# Normalize archive timestamps for a source revision. This does not promise identical
# binaries across different Xcode/SDK versions or signing identities.
AGENTSWAP_RELEASE_EPOCH="${SOURCE_DATE_EPOCH:-}"
if [[ -z "$AGENTSWAP_RELEASE_EPOCH" ]]; then
    AGENTSWAP_RELEASE_EPOCH="$(/usr/bin/git -C "$AGENTSWAP_ROOT" log -1 --format=%ct 2>/dev/null || true)"
    AGENTSWAP_RELEASE_EPOCH="${AGENTSWAP_RELEASE_EPOCH:-946684800}"
fi
[[ "$AGENTSWAP_RELEASE_EPOCH" =~ '^[0-9]{1,10}$' ]] || fail "SOURCE_DATE_EPOCH must be an integer in the ZIP timestamp range."
(( AGENTSWAP_RELEASE_EPOCH >= 315532800 && AGENTSWAP_RELEASE_EPOCH <= 4354819199 )) || fail "SOURCE_DATE_EPOCH must be between 1980 and 2107."
AGENTSWAP_RELEASE_TOUCH_TIME="$(TZ=UTC /bin/date -r "$AGENTSWAP_RELEASE_EPOCH" +%Y%m%d%H%M.%S)"
AGENTSWAP_RELEASE_BUILD_NUMBER="${AGENTSWAP_RELEASE_BUILD_NUMBER:-$AGENTSWAP_RELEASE_EPOCH}"
[[ "$AGENTSWAP_RELEASE_BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] || fail "AGENTSWAP_RELEASE_BUILD_NUMBER must be a positive integer."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
AGENTSWAP_XCODE_VERSION="$(/usr/bin/xcodebuild -version)" || fail "Select a full Xcode installation with DEVELOPER_DIR."
[[ "$AGENTSWAP_XCODE_VERSION" =~ '^Xcode ([0-9]+)' ]] || fail "Cannot determine the Xcode version."
(( match[1] >= 27 )) || fail "Xcode 27 or later is required for the supported release toolchain."
AGENTSWAP_SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
AGENTSWAP_SDK_MAJOR="${AGENTSWAP_SDK_VERSION%%.*}"
[[ "$AGENTSWAP_SDK_MAJOR" =~ '^[0-9]+$' ]] && (( AGENTSWAP_SDK_MAJOR >= 27 )) || fail "macOS SDK 27 or later is required for the supported release toolchain."

for AGENTSWAP_DIRECTORY in "$AGENTSWAP_ROOT/build" "$AGENTSWAP_RELEASE_WORK_ROOT" "$AGENTSWAP_RELEASE_OUTPUT_ROOT"; do
    [[ ! -L "$AGENTSWAP_DIRECTORY" ]] || fail "A release output directory cannot be a symlink."
    /bin/mkdir -p "$AGENTSWAP_DIRECTORY"
done
AGENTSWAP_RELEASE_WORK_DIR="$(/usr/bin/mktemp -d "$AGENTSWAP_RELEASE_WORK_ROOT/package.XXXXXXXX")"
AGENTSWAP_RELEASE_OUTPUT_CREATED=0
AGENTSWAP_RELEASE_PUBLISHED=0
cleanup() {
    if (( AGENTSWAP_RELEASE_OUTPUT_CREATED && ! AGENTSWAP_RELEASE_PUBLISHED )); then
        /bin/rm -f "$AGENTSWAP_RELEASE_OUTPUT_DIR/$AGENTSWAP_ZIP_NAME" "$AGENTSWAP_RELEASE_OUTPUT_DIR/SHA256SUMS" "$AGENTSWAP_RELEASE_OUTPUT_DIR/appcast.xml"
        /bin/rmdir "$AGENTSWAP_RELEASE_OUTPUT_DIR" 2>/dev/null || true
    fi
    if [[ "$AGENTSWAP_RELEASE_WORK_DIR" == "$AGENTSWAP_RELEASE_WORK_ROOT"/package.* && ! -L "$AGENTSWAP_RELEASE_WORK_DIR" ]]; then
        /bin/rm -rf "$AGENTSWAP_RELEASE_WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A release must preserve its Keychain identity across executable changes. Build
# intermediates may be ad-hoc, but public archives must use the pinned dedicated
# release certificate; never fall back to an ad-hoc or a developer's identity.
AGENTSWAP_RELEASE_CERTIFICATE="$AGENTSWAP_ROOT/scripts/signing/release-certificate.cer"
AGENTSWAP_RELEASE_SIGNING_KEYCHAIN="${AGENTSWAP_RELEASE_SIGNING_KEYCHAIN:-}"
[[ -n "$AGENTSWAP_RELEASE_SIGNING_KEYCHAIN" ]] || fail "AGENTSWAP_RELEASE_SIGNING_KEYCHAIN must name a dedicated keychain containing the pinned release identity."
[[ -f "$AGENTSWAP_RELEASE_SIGNING_KEYCHAIN" && ! -L "$AGENTSWAP_RELEASE_SIGNING_KEYCHAIN" ]] || fail "The dedicated release keychain must be a regular file."
AGENTSWAP_RELEASE_SIGNING_HELPER="$AGENTSWAP_RELEASE_WORK_DIR/release-signing"
/usr/bin/xcrun swiftc -suppress-warnings "$AGENTSWAP_ROOT/scripts/release-signing.swift" -o "$AGENTSWAP_RELEASE_SIGNING_HELPER"
AGENTSWAP_RELEASE_CERTIFICATE_SHA1="$("$AGENTSWAP_RELEASE_SIGNING_HELPER" preflight "$AGENTSWAP_RELEASE_CERTIFICATE" "$AGENTSWAP_RELEASE_SIGNING_KEYCHAIN")"
[[ "$AGENTSWAP_RELEASE_CERTIFICATE_SHA1" =~ '^[0-9A-F]{40}$' ]] || fail "Cannot determine the pinned release signing identity."
AGENTSWAP_RELEASE_REQUIREMENT="=designated => identifier \"net.mercen.agentswap\" and certificate leaf = H\"$AGENTSWAP_RELEASE_CERTIFICATE_SHA1\""

AGENTSWAP_SPARKLE_TOOLS="$AGENTSWAP_RELEASE_WORK_DIR/Sparkle"
"$AGENTSWAP_ROOT/scripts/fetch-sparkle-tools.sh" "$AGENTSWAP_SPARKLE_TOOLS"
if [[ -z "$AGENTSWAP_SPARKLE_PRIVATE_KEY" ]]; then
    "$AGENTSWAP_SPARKLE_TOOLS/bin/generate_keys" --account net.mercen.agentswap -p >/dev/null || \
        fail "A Sparkle signing key is required in the net.mercen.agentswap Keychain account (or CI SPARKLE_PRIVATE_KEY)."
fi
sparkle_tool() {
    local AGENTSWAP_TOOL="$1"
    shift
    if [[ -n "$AGENTSWAP_SPARKLE_PRIVATE_KEY" ]]; then
        printf '%s\n' "$AGENTSWAP_SPARKLE_PRIVATE_KEY" | "$AGENTSWAP_SPARKLE_TOOLS/bin/$AGENTSWAP_TOOL" --ed-key-file - "$@"
    else
        "$AGENTSWAP_SPARKLE_TOOLS/bin/$AGENTSWAP_TOOL" --account net.mercen.agentswap "$@"
    fi
}

# Override an owned plist before Xcode signs the bundle; never rewrite the source plist
# or alter metadata inside a signed product after the build.
AGENTSWAP_RELEASE_PLIST="$AGENTSWAP_RELEASE_WORK_DIR/AgentSwap-Release.plist"
/usr/bin/ditto "$AGENTSWAP_ROOT/AgentSwapApp/Info.plist" "$AGENTSWAP_RELEASE_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $AGENTSWAP_BUNDLE_VERSION" "$AGENTSWAP_RELEASE_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $AGENTSWAP_RELEASE_BUILD_NUMBER" "$AGENTSWAP_RELEASE_PLIST"
/usr/bin/python3 - "$AGENTSWAP_RELEASE_PLIST" "$AGENTSWAP_RELEASE_VERSION" <<'PY'
import base64
import plistlib
import sys

with open(sys.argv[1], 'rb') as source:
    config = plistlib.load(source)
try:
    valid_key = len(base64.b64decode(config['SUPublicEDKey'], validate=True)) == 32
except (KeyError, ValueError, TypeError):
    valid_key = False
if not valid_key or config.get('SURequireSignedFeed') is not True or config.get('SUVerifyUpdateBeforeExtraction') is not True or config.get('SUSignedFeedFailureExpirationInterval') != 0:
    raise SystemExit('Release packaging requires an Ed25519 public key, signed feeds, and validation before extraction.')
config['AgentSwapReleaseTag'] = f'v{sys.argv[2]}'
config['SUFeedURL'] = f'https://github.com/mercen-lee/agent-swap/releases/download/v{sys.argv[2]}/appcast.xml'
with open(sys.argv[1], 'wb') as destination:
    plistlib.dump(config, destination, sort_keys=False)
PY
/usr/bin/xcodebuild \
    -project "$AGENTSWAP_ROOT/AgentSwap.xcodeproj" \
    -scheme AgentSwap \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$AGENTSWAP_RELEASE_WORK_DIR/DerivedData" \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "CODE_SIGN_ENTITLEMENTS=$AGENTSWAP_ROOT/AgentSwapApp/AgentSwap-AdHoc.entitlements" \
    MACOSX_DEPLOYMENT_TARGET=14.0 \
    "MARKETING_VERSION=$AGENTSWAP_BUNDLE_VERSION" \
    "CURRENT_PROJECT_VERSION=$AGENTSWAP_RELEASE_BUILD_NUMBER" \
    "INFOPLIST_FILE=$AGENTSWAP_RELEASE_PLIST" INFOPLIST_EXPAND_BUILD_SETTINGS=YES \
    build

AGENTSWAP_RELEASE_STAGING="$AGENTSWAP_RELEASE_WORK_DIR/staging"
/bin/mkdir "$AGENTSWAP_RELEASE_STAGING"
AGENTSWAP_RELEASE_APP="$AGENTSWAP_RELEASE_STAGING/AgentSwap.app"
/usr/bin/ditto "$AGENTSWAP_RELEASE_WORK_DIR/DerivedData/Build/Products/Release/AgentSwap.app" "$AGENTSWAP_RELEASE_APP"
# Assemble the already signed service before the outer app is signed. Its own
# file hashes, certificate, designated requirement and both cdhashes are pinned.
"$AGENTSWAP_ROOT/scripts/install-vault-service.sh" "$AGENTSWAP_VAULT_PIN" "$AGENTSWAP_RELEASE_APP"
AGENTSWAP_BUNDLE_PLIST="$AGENTSWAP_RELEASE_APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$AGENTSWAP_BUNDLE_PLIST")" == net.mercen.agentswap ]] || fail "Unexpected bundle identifier."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$AGENTSWAP_BUNDLE_PLIST")" == "$AGENTSWAP_BUNDLE_VERSION" ]] || fail "Unexpected bundle version."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$AGENTSWAP_BUNDLE_PLIST")" == "$AGENTSWAP_RELEASE_BUILD_NUMBER" ]] || fail "Unexpected build number."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :AgentSwapReleaseTag' "$AGENTSWAP_BUNDLE_PLIST")" == "v$AGENTSWAP_RELEASE_VERSION" ]] || fail "Unexpected release tag."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$AGENTSWAP_BUNDLE_PLIST")" == 14.0 ]] || fail "Unexpected minimum macOS version."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$AGENTSWAP_BUNDLE_PLIST")" == AgentSwap ]] || fail "Unexpected app executable."
AGENTSWAP_RELEASE_EXECUTABLE="$AGENTSWAP_RELEASE_APP/Contents/MacOS/AgentSwap"
for AGENTSWAP_ARCH in arm64 x86_64; do
    AGENTSWAP_BINARY_MINIMUM="$(/usr/bin/xcrun vtool -arch "$AGENTSWAP_ARCH" -show-build "$AGENTSWAP_RELEASE_EXECUTABLE" | /usr/bin/awk '$1 == "minos" { print $2 }')"
    [[ "$AGENTSWAP_BINARY_MINIMUM" == 14.0 || "$AGENTSWAP_BINARY_MINIMUM" == 14.0.0 ]] || fail "The executable minimum macOS version is incorrect."
done
while IFS= read -r -d '' AGENTSWAP_FILE; do
    if [[ "$(/usr/bin/file -b "$AGENTSWAP_FILE")" == *Mach-O* ]]; then
        AGENTSWAP_ARCHITECTURES="$(/usr/bin/lipo -archs "$AGENTSWAP_FILE")"
        [[ "$AGENTSWAP_ARCHITECTURES" == 'arm64 x86_64' || "$AGENTSWAP_ARCHITECTURES" == 'x86_64 arm64' ]] || fail "Every bundled Mach-O must contain exactly arm64 and x86_64."
    fi
done < <(/usr/bin/find "$AGENTSWAP_RELEASE_APP" -type f -print0)
TZ=UTC /usr/bin/find "$AGENTSWAP_RELEASE_APP" -exec /usr/bin/touch -h -t "$AGENTSWAP_RELEASE_TOUCH_TIME" {} +
# Sign the outer app after metadata and nested-code assembly are final. Preserve
# Xcode's entitlements and the existing Sparkle nested signatures. --deep signing
# would apply the app's requirement to unrelated nested bundle identifiers.
/usr/bin/codesign --force --options runtime --preserve-metadata=entitlements \
    --sign "$AGENTSWAP_RELEASE_CERTIFICATE_SHA1" --keychain "$AGENTSWAP_RELEASE_SIGNING_KEYCHAIN" \
    --identifier net.mercen.agentswap --requirements "$AGENTSWAP_RELEASE_REQUIREMENT" \
    --timestamp=none "$AGENTSWAP_RELEASE_APP"
/usr/bin/codesign --verify --deep --strict "$AGENTSWAP_RELEASE_APP"
"$AGENTSWAP_RELEASE_SIGNING_HELPER" verify "$AGENTSWAP_RELEASE_APP" "$AGENTSWAP_RELEASE_CERTIFICATE"
/usr/bin/python3 "$AGENTSWAP_ROOT/scripts/fetch-vault-service.py" \
    --pin "$AGENTSWAP_VAULT_PIN" \
    --verify-bundle "$AGENTSWAP_RELEASE_APP/Contents/XPCServices/AgentSwapVaultService.xpc"
/usr/bin/codesign --display --entitlements :- "$AGENTSWAP_RELEASE_APP" 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
entitlements = plistlib.loads(sys.stdin.buffer.read())
if entitlements.get("com.apple.security.get-task-allow") is True or entitlements.get("com.apple.security.cs.disable-library-validation") is not True:
    raise SystemExit("The release app must disable debugger attachment and allow its separately signed Sparkle framework.")
'

AGENTSWAP_RELEASE_ARCHIVE="$AGENTSWAP_RELEASE_WORK_DIR/archive"
/bin/mkdir "$AGENTSWAP_RELEASE_ARCHIVE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$AGENTSWAP_RELEASE_APP" "$AGENTSWAP_RELEASE_ARCHIVE/$AGENTSWAP_ZIP_NAME"
sparkle_tool generate_appcast \
    --download-url-prefix "https://github.com/mercen-lee/agent-swap/releases/download/v$AGENTSWAP_RELEASE_VERSION/" \
    --link "https://github.com/mercen-lee/agent-swap/releases/tag/v$AGENTSWAP_RELEASE_VERSION" \
    --maximum-versions 1 --maximum-deltas 0 \
    -o "$AGENTSWAP_RELEASE_ARCHIVE/appcast.xml" "$AGENTSWAP_RELEASE_ARCHIVE"
# Preserve the prerelease label in Sparkle's UI while CFBundleShortVersionString
# keeps the numeric version required by Apple's bundle format. Re-sign below.
/usr/bin/python3 - "$AGENTSWAP_RELEASE_ARCHIVE/appcast.xml" "$AGENTSWAP_RELEASE_VERSION" "$AGENTSWAP_RELEASE_BUILD_NUMBER" "$AGENTSWAP_ZIP_NAME" <<'PY'
import base64
import os
import sys
import xml.etree.ElementTree as ET

path, version, build, zip_name = sys.argv[1:]
namespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', namespace)
root = ET.parse(path)
items = root.findall('./channel/item')
if len(items) != 1:
    raise SystemExit('The release appcast must contain exactly one update.')
item = items[0]
enclosure = item.find('enclosure')
expected_url = f'https://github.com/mercen-lee/agent-swap/releases/download/v{version}/{zip_name}'
if enclosure is None or enclosure.get('url') != expected_url:
    raise SystemExit('The appcast download URL does not match the release archive.')
signature = enclosure.get(f'{{{namespace}}}edSignature', '')
try:
    valid_signature = len(base64.b64decode(signature, validate=True)) == 64
except ValueError:
    valid_signature = False
if not valid_signature or int(enclosure.get('length', '0')) != os.path.getsize(os.path.join(os.path.dirname(path), zip_name)):
    raise SystemExit('The release archive is missing a valid EdDSA signature or length.')
if item.findtext(f'{{{namespace}}}version') != build:
    raise SystemExit('The appcast build number does not match the application.')
if item.findtext(f'{{{namespace}}}minimumSystemVersion') != '14.0':
    raise SystemExit('The appcast minimum macOS version must be 14.0.')
item.find('title').text = f'AgentSwap {version}'
item.find(f'{{{namespace}}}shortVersionString').text = version
root.write(path, encoding='utf-8', xml_declaration=True)
PY
sparkle_tool sign_update "$AGENTSWAP_RELEASE_ARCHIVE/appcast.xml"
sparkle_tool sign_update --verify "$AGENTSWAP_RELEASE_ARCHIVE/appcast.xml"
AGENTSWAP_ARCHIVE_SIGNATURE="$(/usr/bin/python3 - "$AGENTSWAP_RELEASE_ARCHIVE/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).find('./channel/item/enclosure').get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'))
PY
)"
sparkle_tool sign_update --verify "$AGENTSWAP_RELEASE_ARCHIVE/$AGENTSWAP_ZIP_NAME" "$AGENTSWAP_ARCHIVE_SIGNATURE"
/usr/bin/xcrun swift "$AGENTSWAP_ROOT/scripts/verify-release-signature.swift" \
    "$AGENTSWAP_BUNDLE_PLIST" "$AGENTSWAP_RELEASE_ARCHIVE/$AGENTSWAP_ZIP_NAME" "$AGENTSWAP_ARCHIVE_SIGNATURE"
(
    cd "$AGENTSWAP_RELEASE_ARCHIVE"
    /usr/bin/shasum -a 256 "$AGENTSWAP_ZIP_NAME" appcast.xml > SHA256SUMS
    /usr/bin/shasum -a 256 --check SHA256SUMS
)
# mkdir is exclusive: concurrent runs for the same version cannot replace one another.
/bin/mkdir "$AGENTSWAP_RELEASE_OUTPUT_DIR" || fail "Artifacts for VERSION were created by another run."
AGENTSWAP_RELEASE_OUTPUT_CREATED=1
/bin/mv "$AGENTSWAP_RELEASE_ARCHIVE/$AGENTSWAP_ZIP_NAME" "$AGENTSWAP_RELEASE_OUTPUT_DIR/$AGENTSWAP_ZIP_NAME"
/bin/mv "$AGENTSWAP_RELEASE_ARCHIVE/SHA256SUMS" "$AGENTSWAP_RELEASE_OUTPUT_DIR/SHA256SUMS"
/bin/mv "$AGENTSWAP_RELEASE_ARCHIVE/appcast.xml" "$AGENTSWAP_RELEASE_OUTPUT_DIR/appcast.xml"
AGENTSWAP_RELEASE_PUBLISHED=1
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'zip_path=%s\nchecksum_path=%s\nappcast_path=%s\n' \
        "build/releases/$AGENTSWAP_RELEASE_VERSION/$AGENTSWAP_ZIP_NAME" \
        "build/releases/$AGENTSWAP_RELEASE_VERSION/SHA256SUMS" \
        "build/releases/$AGENTSWAP_RELEASE_VERSION/appcast.xml" >> "$GITHUB_OUTPUT"
fi
print -r -- "Packaged: build/releases/$AGENTSWAP_RELEASE_VERSION/$AGENTSWAP_ZIP_NAME"
print -r -- "Checksums: build/releases/$AGENTSWAP_RELEASE_VERSION/SHA256SUMS"
print -r -- "Signed update feed: build/releases/$AGENTSWAP_RELEASE_VERSION/appcast.xml"
print -r -- 'The app uses the pinned dedicated signing certificate and has not been notarized.'
