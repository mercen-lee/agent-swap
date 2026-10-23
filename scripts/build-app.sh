#!/bin/zsh
set -euo pipefail

AGENTSWAP_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# A normal app build must contain the frozen service. Bootstrap-only source
# commits intentionally cannot produce a new app until its public pin is ready.
AGENTSWAP_VAULT_PIN="$AGENTSWAP_ROOT/scripts/signing/vault-service-v1.json"
[[ -f "$AGENTSWAP_VAULT_PIN" && ! -L "$AGENTSWAP_VAULT_PIN" ]] || {
  print -u2 -r -- 'The reviewed frozen vault service pin is required before building an app.'
  exit 1
}
/usr/bin/python3 "$AGENTSWAP_ROOT/scripts/fetch-vault-service.py" \
    --pin "$AGENTSWAP_VAULT_PIN" \
    --verify-source-pin "$AGENTSWAP_ROOT/AgentSwapCore/Sources/AgentSwapCore/AppVaultTransport.swift"

# Keep a developer-machine signing choice out of source control. An explicitly
# supplied environment value (including "-") always takes precedence.
if [[ -n "${AGENTSWAP_SIGN_IDENTITY+x}" ]]; then
  AGENTSWAP_RESOLVED_SIGN_IDENTITY="$AGENTSWAP_SIGN_IDENTITY"
else
  AGENTSWAP_LOCAL_SIGNING_IDENTITY="$AGENTSWAP_ROOT/.agentswap-signing-identity"
  if [[ -e "$AGENTSWAP_LOCAL_SIGNING_IDENTITY" || -L "$AGENTSWAP_LOCAL_SIGNING_IDENTITY" ]]; then
    if [[ ! -f "$AGENTSWAP_LOCAL_SIGNING_IDENTITY" || -L "$AGENTSWAP_LOCAL_SIGNING_IDENTITY" ]]; then
      echo "Local signing identity must be a regular file: $AGENTSWAP_LOCAL_SIGNING_IDENTITY" >&2
      exit 1
    fi

    AGENTSWAP_RESOLVED_SIGN_IDENTITY="$(<"$AGENTSWAP_LOCAL_SIGNING_IDENTITY")"
    AGENTSWAP_LOCAL_SIGNING_LINES="$(/usr/bin/wc -l < "$AGENTSWAP_LOCAL_SIGNING_IDENTITY" | /usr/bin/tr -d ' ')"
    if [[ ! "$AGENTSWAP_RESOLVED_SIGN_IDENTITY" =~ '^[0-9A-Fa-f]{40}$' ]] || (( AGENTSWAP_LOCAL_SIGNING_LINES > 1 )); then
      echo "Local signing identity must contain exactly one 40-character certificate SHA-1: $AGENTSWAP_LOCAL_SIGNING_IDENTITY" >&2
      exit 1
    fi
  else
    AGENTSWAP_RESOLVED_SIGN_IDENTITY="-"
  fi
fi

AGENTSWAP_PRODUCT="$AGENTSWAP_ROOT/build/DerivedData/Build/Products/Release/AgentSwap.app"
AGENTSWAP_PRODUCT_EXECUTABLE="$AGENTSWAP_PRODUCT/Contents/MacOS/AgentSwap"
while IFS= read -r AGENTSWAP_RUNNING_EXECUTABLE; do
  if [[ "$AGENTSWAP_RUNNING_EXECUTABLE" == "$AGENTSWAP_PRODUCT_EXECUTABLE" ]]; then
    echo "Quit the DerivedData copy of AgentSwap before building it again: $AGENTSWAP_PRODUCT"
    exit 1
  fi
done < <(/bin/ps -ww -axo comm=)

xcodebuild \
  -project "$AGENTSWAP_ROOT/AgentSwap.xcodeproj" \
  -scheme AgentSwap \
  -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$AGENTSWAP_ROOT/build/DerivedData" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_ENTITLEMENTS="$AGENTSWAP_ROOT/AgentSwapApp/AgentSwap-AdHoc.entitlements" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build

# DerivedData is a nonrunning staging product. The installer verifies the
# frozen nested code before the outer signature is replaced, including ad-hoc
# builds. Never use --deep while signing: that would replace the service identity.
"$AGENTSWAP_ROOT/scripts/install-vault-service.sh" "$AGENTSWAP_VAULT_PIN" "$AGENTSWAP_PRODUCT"
/usr/bin/codesign \
  --force \
  --options runtime \
  --preserve-metadata=entitlements \
  --sign "$AGENTSWAP_RESOLVED_SIGN_IDENTITY" \
  --timestamp=none \
  "$AGENTSWAP_PRODUCT"
/usr/bin/codesign --verify --deep --strict "$AGENTSWAP_PRODUCT"
/usr/bin/python3 "$AGENTSWAP_ROOT/scripts/fetch-vault-service.py" \
  --pin "$AGENTSWAP_VAULT_PIN" \
  --verify-bundle "$AGENTSWAP_PRODUCT/Contents/XPCServices/AgentSwapVaultService.xpc"

AGENTSWAP_INSTALLED_EXECUTABLE="$AGENTSWAP_ROOT/build/AgentSwap.app/Contents/MacOS/AgentSwap"
while IFS= read -r AGENTSWAP_RUNNING_EXECUTABLE; do
  if [[ "$AGENTSWAP_RUNNING_EXECUTABLE" == "$AGENTSWAP_INSTALLED_EXECUTABLE" ]]; then
    echo "Built: $AGENTSWAP_PRODUCT"
    echo "Quit AgentSwap before re-running this script to install into build/AgentSwap.app."
    exit 0
  fi
done < <(/bin/ps -ww -axo comm=)

mkdir -p "$AGENTSWAP_ROOT/build"
ditto "$AGENTSWAP_PRODUCT" "$AGENTSWAP_ROOT/build/AgentSwap.app"
/usr/bin/codesign --verify --deep --strict "$AGENTSWAP_ROOT/build/AgentSwap.app"
/usr/bin/python3 "$AGENTSWAP_ROOT/scripts/fetch-vault-service.py" \
  --pin "$AGENTSWAP_VAULT_PIN" \
  --verify-bundle "$AGENTSWAP_ROOT/build/AgentSwap.app/Contents/XPCServices/AgentSwapVaultService.xpc"
echo "Built: $AGENTSWAP_ROOT/build/AgentSwap.app"
