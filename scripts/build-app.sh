#!/bin/zsh
set -euo pipefail

AGENTSWAP_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

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
  CODE_SIGN_IDENTITY="${AGENTSWAP_SIGN_IDENTITY:--}" \
  build

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
echo "Built: $AGENTSWAP_ROOT/build/AgentSwap.app"
