#!/bin/zsh
set -euo pipefail
umask 022

# Bootstrap once in CI. Future app packages fetch these signed bytes; they must
# never rebuild or re-sign this service merely because the parent app changed.
fail() { print -u2 -r -- "Vault service packaging: $1"; exit 1; }
if (( $# != 1 )); then
    print -u2 -r -- "Usage: $0 NEW_OUTPUT_DIRECTORY"
    exit 64
fi
AGENTSWAP_ROOT="${0:A:h:h}"
AGENTSWAP_VAULT_OUTPUT="$1"
[[ "${GITHUB_ACTIONS:-}" == true ]] || fail 'Bootstrap signing is restricted to the reviewed CI workflow.'
[[ ! -e "$AGENTSWAP_VAULT_OUTPUT" && ! -L "$AGENTSWAP_VAULT_OUTPUT" ]] || fail 'The output directory already exists.'
AGENTSWAP_VAULT_SOURCE="${AGENTSWAP_VAULT_SOURCE_COMMIT:-}"
[[ "$AGENTSWAP_VAULT_SOURCE" =~ '^[0-9a-f]{40}$' ]] || fail 'An exact source commit is required.'
[[ "$(/usr/bin/git -C "$AGENTSWAP_ROOT" rev-parse HEAD)" == "$AGENTSWAP_VAULT_SOURCE" ]] || fail 'The checkout differs from the requested source commit.'
[[ -z "$(/usr/bin/git -C "$AGENTSWAP_ROOT" status --porcelain --untracked-files=normal)" ]] || fail 'The source checkout must be clean.'
[[ "${GITHUB_RUN_ID:-}" =~ '^[1-9][0-9]*$' ]] || fail 'A CI run ID is required.'
AGENTSWAP_VAULT_KEYCHAIN="${AGENTSWAP_RELEASE_SIGNING_KEYCHAIN:-}"
[[ -f "$AGENTSWAP_VAULT_KEYCHAIN" && ! -L "$AGENTSWAP_VAULT_KEYCHAIN" ]] || fail 'The dedicated ephemeral signing keychain is required.'
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
AGENTSWAP_VAULT_XCODE="$(/usr/bin/xcodebuild -version)"
[[ "$AGENTSWAP_VAULT_XCODE" =~ '^Xcode ([0-9]+)' ]] && (( match[1] >= 27 )) || fail 'Xcode 27 or later is required.'
AGENTSWAP_VAULT_SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
[[ "${AGENTSWAP_VAULT_SDK%%.*}" =~ '^[0-9]+$' ]] && (( ${AGENTSWAP_VAULT_SDK%%.*} >= 27 )) || fail 'macOS SDK 27 or later is required.'
[[ ! -L "$AGENTSWAP_ROOT/build" ]] || fail 'The build directory cannot be a symlink.'
/bin/mkdir -p "$AGENTSWAP_ROOT/build"
AGENTSWAP_VAULT_WORK="$(/usr/bin/mktemp -d "$AGENTSWAP_ROOT/build/vault-bootstrap.XXXXXXXX")"
trap '/bin/rm -rf "$AGENTSWAP_VAULT_WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
AGENTSWAP_VAULT_CERTIFICATE="$AGENTSWAP_ROOT/scripts/signing/release-certificate.cer"
AGENTSWAP_VAULT_SIGNER="$AGENTSWAP_VAULT_WORK/release-signing"
/usr/bin/xcrun swiftc -suppress-warnings "$AGENTSWAP_ROOT/scripts/release-signing.swift" -o "$AGENTSWAP_VAULT_SIGNER"
AGENTSWAP_VAULT_CERT_SHA1="$("$AGENTSWAP_VAULT_SIGNER" preflight "$AGENTSWAP_VAULT_CERTIFICATE" "$AGENTSWAP_VAULT_KEYCHAIN")"
[[ "$AGENTSWAP_VAULT_CERT_SHA1" =~ '^[0-9A-F]{40}$' ]] || fail 'The pinned signing identity was not found.'
AGENTSWAP_VAULT_ID=net.mercen.agentswap.vault
AGENTSWAP_VAULT_REQUIREMENT="identifier \"$AGENTSWAP_VAULT_ID\" and certificate leaf = H\"$AGENTSWAP_VAULT_CERT_SHA1\""
AGENTSWAP_VAULT_BUNDLE="$AGENTSWAP_VAULT_WORK/AgentSwapVaultService.xpc"
/bin/mkdir -p "$AGENTSWAP_VAULT_BUNDLE/Contents/MacOS"
for AGENTSWAP_VAULT_ARCH in arm64 x86_64; do
    AGENTSWAP_VAULT_SCRATCH="$AGENTSWAP_VAULT_WORK/$AGENTSWAP_VAULT_ARCH"
    MACOSX_DEPLOYMENT_TARGET=14.0 /usr/bin/xcrun swift build \
        --package-path "$AGENTSWAP_ROOT/AgentSwapCore" --scratch-path "$AGENTSWAP_VAULT_SCRATCH" \
        --configuration release --triple "$AGENTSWAP_VAULT_ARCH-apple-macosx14.0" \
        --product AgentSwapVaultService
    AGENTSWAP_VAULT_BIN_PATH="$(/usr/bin/xcrun swift build \
        --package-path "$AGENTSWAP_ROOT/AgentSwapCore" --scratch-path "$AGENTSWAP_VAULT_SCRATCH" \
        --configuration release --triple "$AGENTSWAP_VAULT_ARCH-apple-macosx14.0" --show-bin-path)"
    /bin/cp "$AGENTSWAP_VAULT_BIN_PATH/AgentSwapVaultService" "$AGENTSWAP_VAULT_WORK/$AGENTSWAP_VAULT_ARCH-executable"
done
/usr/bin/lipo -create "$AGENTSWAP_VAULT_WORK/arm64-executable" "$AGENTSWAP_VAULT_WORK/x86_64-executable" \
    -output "$AGENTSWAP_VAULT_BUNDLE/Contents/MacOS/AgentSwapVaultService"
/bin/chmod 755 "$AGENTSWAP_VAULT_BUNDLE/Contents/MacOS/AgentSwapVaultService"
/usr/bin/ditto "$AGENTSWAP_ROOT/AgentSwapCore/Sources/AgentSwapVaultService/Info.plist" "$AGENTSWAP_VAULT_BUNDLE/Contents/Info.plist"
# No inherited/app entitlements, no --deep, no interpreter ACL. Sign once after
# lipo and all bundle metadata are final; only copy these bytes afterwards.
/usr/bin/codesign --force --options runtime --sign "$AGENTSWAP_VAULT_CERT_SHA1" \
    --keychain "$AGENTSWAP_VAULT_KEYCHAIN" --identifier "$AGENTSWAP_VAULT_ID" \
    --requirements "=designated => $AGENTSWAP_VAULT_REQUIREMENT" --timestamp=none "$AGENTSWAP_VAULT_BUNDLE"
/usr/bin/codesign --verify --strict --all-architectures "$AGENTSWAP_VAULT_BUNDLE"
/usr/bin/python3 - "$AGENTSWAP_ROOT" "$AGENTSWAP_VAULT_BUNDLE" "$AGENTSWAP_VAULT_WORK" "$AGENTSWAP_VAULT_SOURCE" "$GITHUB_RUN_ID" <<'PY'
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import stat
import sys
import zipfile

sys.dont_write_bytecode = True
root, bundle, work = map(Path, sys.argv[1:4])
commit, run_id = sys.argv[4:6]
spec = importlib.util.spec_from_file_location('vault_artifact', root / 'scripts/fetch-vault-service.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
certificate = root / 'scripts/signing/release-certificate.cer'
fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
files = {}
for path in sorted(bundle.rglob('*')):
    if path.is_file():
        path.chmod(0o755 if path.parent.name == 'MacOS' else 0o644)
        data = path.read_bytes()
        files[path.relative_to(bundle).as_posix()] = {'sha256': verifier.sha256(data), 'size': len(data), 'mode': stat.S_IMODE(path.stat().st_mode)}
archive = work / f'AgentSwapVaultService-{commit}-universal.zip'
with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED) as output:
    for name, value in files.items():
        entry = zipfile.ZipInfo(bundle.name + '/' + name, date_time=(2000, 1, 1, 0, 0, 0))
        entry.create_system = 3
        entry.external_attr = (stat.S_IFREG | value['mode']) << 16
        entry.compress_type = zipfile.ZIP_DEFLATED
        output.writestr(entry, (bundle / name).read_bytes())
architectures = {}
for arch in ('arm64', 'x86_64'):
    signing = verifier.command(['/usr/bin/codesign', '--display', '--verbose=4', '--arch', arch, bundle]).stderr.decode()
    cdhash = re.search(r'^CDHash=([0-9a-f]{40})$', signing, re.MULTILINE)
    verifier.require(cdhash is not None, 'missing helper cdhash')
    architectures[arch] = {'cdhash': cdhash.group(1), 'minimumOS': '14.0'}
manifest = {
    'schemaVersion': 1, 'protocolVersion': 1,
    'bundleName': verifier.BUNDLE, 'executable': verifier.EXECUTABLE, 'bundleIdentifier': verifier.IDENTIFIER,
    'sourceCommit': commit, 'runID': run_id, 'certificateSHA1': fingerprint,
    'designatedRequirement': f'identifier "{verifier.IDENTIFIER}" and certificate leaf = H"{fingerprint}"',
    'archive': {'name': archive.name, 'sha256': verifier.sha256(archive.read_bytes()), 'size': archive.stat().st_size},
    'executableSHA256': files['Contents/MacOS/AgentSwapVaultService']['sha256'],
    'architectures': architectures, 'files': files,
}
manifest_path = archive.with_suffix('.json')
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
pin = verifier.load_manifest(manifest_path, certificate)
verifier.verify_bundle(bundle, pin, certificate)
restored = work / 'restored' / bundle.name
restored.parent.mkdir()
verifier.extract_archive(archive, restored, pin)
verifier.verify_bundle(restored, pin, certificate)
PY
/bin/mkdir "$AGENTSWAP_VAULT_OUTPUT"
AGENTSWAP_VAULT_STEM="AgentSwapVaultService-$AGENTSWAP_VAULT_SOURCE-universal"
/bin/cp "$AGENTSWAP_VAULT_WORK/$AGENTSWAP_VAULT_STEM.zip" "$AGENTSWAP_VAULT_OUTPUT/"
/bin/cp "$AGENTSWAP_VAULT_WORK/$AGENTSWAP_VAULT_STEM.json" "$AGENTSWAP_VAULT_OUTPUT/"
print -r -- 'Prepared frozen vault service ZIP and public manifest. No release assets were published.'
