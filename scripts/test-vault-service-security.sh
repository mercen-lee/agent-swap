#!/bin/zsh
set -euo pipefail

AGENTSWAP_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec /usr/bin/python3 "$AGENTSWAP_ROOT/scripts/test-vault-service-security.py" "$@"
