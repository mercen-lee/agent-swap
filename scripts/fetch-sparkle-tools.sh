#!/bin/zsh
set -euo pipefail
umask 022

# Use the same audited release as the application's Swift Package dependency.
# The digest is GitHub's SHA-256 for Sparkle's official distribution asset.
if (( $# != 1 )); then
    print -u2 -r -- "Usage: $0 NEW_OUTPUT_DIRECTORY"
    exit 64
fi
AGENTSWAP_SPARKLE_DESTINATION="$1"
[[ ! -e "$AGENTSWAP_SPARKLE_DESTINATION" && ! -L "$AGENTSWAP_SPARKLE_DESTINATION" ]] || {
    print -u2 -r -- 'Sparkle tools output directory must not already exist.'
    exit 1
}
AGENTSWAP_SPARKLE_VERSION=2.10.0
AGENTSWAP_SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
AGENTSWAP_SPARKLE_TEMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agentswap-sparkle.XXXXXXXX")"
trap '/bin/rm -rf "$AGENTSWAP_SPARKLE_TEMP"' EXIT
/usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$AGENTSWAP_SPARKLE_VERSION/Sparkle-$AGENTSWAP_SPARKLE_VERSION.tar.xz" \
    --output "$AGENTSWAP_SPARKLE_TEMP/distribution.tar.xz"
AGENTSWAP_SPARKLE_ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$AGENTSWAP_SPARKLE_TEMP/distribution.tar.xz" | /usr/bin/awk '{ print $1 }')"
[[ "$AGENTSWAP_SPARKLE_ACTUAL_SHA256" == "$AGENTSWAP_SPARKLE_SHA256" ]] || {
    print -u2 -r -- 'Sparkle distribution checksum did not match the pinned release.'
    exit 1
}
/bin/mkdir "$AGENTSWAP_SPARKLE_TEMP/tools"
/usr/bin/tar -xJf "$AGENTSWAP_SPARKLE_TEMP/distribution.tar.xz" -C "$AGENTSWAP_SPARKLE_TEMP/tools"
for AGENTSWAP_SPARKLE_TOOL in generate_keys sign_update generate_appcast; do
    [[ -x "$AGENTSWAP_SPARKLE_TEMP/tools/bin/$AGENTSWAP_SPARKLE_TOOL" ]] || {
        print -u2 -r -- 'The Sparkle distribution is missing a release tool.'
        exit 1
    }
done
/bin/mv "$AGENTSWAP_SPARKLE_TEMP/tools" "$AGENTSWAP_SPARKLE_DESTINATION"
