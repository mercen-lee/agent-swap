#!/bin/zsh
set -euo pipefail
umask 022

# Assemble only a build/staging app. The caller signs its outer bundle after
# this step; this script never signs, launches, or replaces an installed app.
if (( $# < 2 || $# > 3 )); then
    print -u2 -r -- "Usage: $0 PIN_MANIFEST STAGING_APP [LOCAL_ARCHIVE]"
    exit 64
fi
AGENTSWAP_ROOT="${0:A:h:h}"
AGENTSWAP_VAULT_PIN="$1"
AGENTSWAP_VAULT_APP="${2:A}"
[[ -d "$AGENTSWAP_VAULT_APP/Contents" && ! -L "$AGENTSWAP_VAULT_APP" ]] || {
    print -u2 -r -- 'A staging app directory is required.'
    exit 1
}
[[ "$AGENTSWAP_VAULT_APP" == "$AGENTSWAP_ROOT/build/"* ]] || {
    print -u2 -r -- 'Vault assembly is restricted to staging apps under this checkout build directory.'
    exit 1
}
AGENTSWAP_VAULT_CONTAINER="$AGENTSWAP_VAULT_APP/Contents/XPCServices"
[[ ! -L "$AGENTSWAP_VAULT_CONTAINER" ]] || {
    print -u2 -r -- 'XPCServices cannot be a symlink.'
    exit 1
}
/bin/mkdir -p "$AGENTSWAP_VAULT_CONTAINER"
AGENTSWAP_VAULT_DESTINATION="$AGENTSWAP_VAULT_CONTAINER/AgentSwapVaultService.xpc"
if [[ -e "$AGENTSWAP_VAULT_DESTINATION" || -L "$AGENTSWAP_VAULT_DESTINATION" ]]; then
    /usr/bin/python3 "$AGENTSWAP_ROOT/scripts/fetch-vault-service.py" \
        --pin "$AGENTSWAP_VAULT_PIN" --verify-bundle "$AGENTSWAP_VAULT_DESTINATION"
else
    AGENTSWAP_VAULT_ARGUMENTS=(--pin "$AGENTSWAP_VAULT_PIN" --destination "$AGENTSWAP_VAULT_DESTINATION")
    if (( $# == 3 )); then
        AGENTSWAP_VAULT_ARGUMENTS+=(--archive "$3")
    fi
    /usr/bin/python3 "$AGENTSWAP_ROOT/scripts/fetch-vault-service.py" "${AGENTSWAP_VAULT_ARGUMENTS[@]}"
fi
