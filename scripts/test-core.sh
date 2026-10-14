#!/bin/zsh
set -euo pipefail

AGENTSWAP_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
AGENTSWAP_TEST_SCRATCH_PATH="${AGENTSWAP_TEST_SCRATCH_PATH:-$AGENTSWAP_ROOT/build/CoreTests}"

xcrun swift test \
  --package-path "$AGENTSWAP_ROOT/AgentSwapCore" \
  --build-system native \
  --scratch-path "$AGENTSWAP_TEST_SCRATCH_PATH" \
  "$@"
