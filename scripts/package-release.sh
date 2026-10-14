#!/bin/zsh
set -euo pipefail
umask 022

fail() { print -u2 -r -- "Release packaging: $1"; exit 1; }
usage() { print -r -- "Usage: $0 VERSION (X.Y.Z or X.Y.Z-prerelease; AGENTSWAP_RELEASE_BUILD_NUMBER defaults to 1)"; }
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
AGENTSWAP_RELEASE_BUILD_NUMBER="${AGENTSWAP_RELEASE_BUILD_NUMBER:-1}"
[[ "$AGENTSWAP_RELEASE_BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] || fail "AGENTSWAP_RELEASE_BUILD_NUMBER must be a positive integer."

AGENTSWAP_ROOT="${0:A:h:h}"
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
        /bin/rm -f "$AGENTSWAP_RELEASE_OUTPUT_DIR/$AGENTSWAP_ZIP_NAME" "$AGENTSWAP_RELEASE_OUTPUT_DIR/SHA256SUMS"
        /bin/rmdir "$AGENTSWAP_RELEASE_OUTPUT_DIR" 2>/dev/null || true
    fi
    if [[ "$AGENTSWAP_RELEASE_WORK_DIR" == "$AGENTSWAP_RELEASE_WORK_ROOT"/package.* && ! -L "$AGENTSWAP_RELEASE_WORK_DIR" ]]; then
        /bin/rm -rf "$AGENTSWAP_RELEASE_WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Override an owned plist before Xcode signs the bundle; never rewrite the source plist
# or alter metadata inside a signed product after the build.
AGENTSWAP_RELEASE_PLIST="$AGENTSWAP_RELEASE_WORK_DIR/AgentSwap-Release.plist"
/usr/bin/ditto "$AGENTSWAP_ROOT/AgentSwapApp/Info.plist" "$AGENTSWAP_RELEASE_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $AGENTSWAP_BUNDLE_VERSION" "$AGENTSWAP_RELEASE_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $AGENTSWAP_RELEASE_BUILD_NUMBER" "$AGENTSWAP_RELEASE_PLIST"
/usr/bin/xcodebuild \
    -project "$AGENTSWAP_ROOT/AgentSwap.xcodeproj" \
    -scheme AgentSwap \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$AGENTSWAP_RELEASE_WORK_DIR/DerivedData" \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES \
    MACOSX_DEPLOYMENT_TARGET=14.0 \
    "MARKETING_VERSION=$AGENTSWAP_BUNDLE_VERSION" \
    "CURRENT_PROJECT_VERSION=$AGENTSWAP_RELEASE_BUILD_NUMBER" \
    "INFOPLIST_FILE=$AGENTSWAP_RELEASE_PLIST" INFOPLIST_EXPAND_BUILD_SETTINGS=YES \
    build

AGENTSWAP_RELEASE_STAGING="$AGENTSWAP_RELEASE_WORK_DIR/staging"
/bin/mkdir "$AGENTSWAP_RELEASE_STAGING"
AGENTSWAP_RELEASE_APP="$AGENTSWAP_RELEASE_STAGING/AgentSwap.app"
/usr/bin/ditto "$AGENTSWAP_RELEASE_WORK_DIR/DerivedData/Build/Products/Release/AgentSwap.app" "$AGENTSWAP_RELEASE_APP"
AGENTSWAP_BUNDLE_PLIST="$AGENTSWAP_RELEASE_APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$AGENTSWAP_BUNDLE_PLIST")" == net.mercen.agentswap ]] || fail "Unexpected bundle identifier."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$AGENTSWAP_BUNDLE_PLIST")" == "$AGENTSWAP_BUNDLE_VERSION" ]] || fail "Unexpected bundle version."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$AGENTSWAP_BUNDLE_PLIST")" == "$AGENTSWAP_RELEASE_BUILD_NUMBER" ]] || fail "Unexpected build number."
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
/usr/bin/codesign --verify --deep --strict "$AGENTSWAP_RELEASE_APP"

AGENTSWAP_RELEASE_ARCHIVE="$AGENTSWAP_RELEASE_WORK_DIR/archive"
/bin/mkdir "$AGENTSWAP_RELEASE_ARCHIVE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$AGENTSWAP_RELEASE_APP" "$AGENTSWAP_RELEASE_ARCHIVE/$AGENTSWAP_ZIP_NAME"
(
    cd "$AGENTSWAP_RELEASE_ARCHIVE"
    /usr/bin/shasum -a 256 "$AGENTSWAP_ZIP_NAME" > SHA256SUMS
    /usr/bin/shasum -a 256 --check SHA256SUMS
)
# mkdir is exclusive: concurrent runs for the same version cannot replace one another.
/bin/mkdir "$AGENTSWAP_RELEASE_OUTPUT_DIR" || fail "Artifacts for VERSION were created by another run."
AGENTSWAP_RELEASE_OUTPUT_CREATED=1
/bin/mv "$AGENTSWAP_RELEASE_ARCHIVE/$AGENTSWAP_ZIP_NAME" "$AGENTSWAP_RELEASE_OUTPUT_DIR/$AGENTSWAP_ZIP_NAME"
/bin/mv "$AGENTSWAP_RELEASE_ARCHIVE/SHA256SUMS" "$AGENTSWAP_RELEASE_OUTPUT_DIR/SHA256SUMS"
AGENTSWAP_RELEASE_PUBLISHED=1
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'zip_path=%s\nchecksum_path=%s\n' \
        "build/releases/$AGENTSWAP_RELEASE_VERSION/$AGENTSWAP_ZIP_NAME" \
        "build/releases/$AGENTSWAP_RELEASE_VERSION/SHA256SUMS" >> "$GITHUB_OUTPUT"
fi
print -r -- "Packaged: build/releases/$AGENTSWAP_RELEASE_VERSION/$AGENTSWAP_ZIP_NAME"
print -r -- "Checksums: build/releases/$AGENTSWAP_RELEASE_VERSION/SHA256SUMS"
print -r -- 'The app is ad-hoc signed and has not been notarized.'
