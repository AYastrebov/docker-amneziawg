#!/bin/sh
set -e

# --- Sidecar-specific defaults (different from VPN container defaults) ---
export CONFIG_DIR="${CONFIG_DIR:-/config}"
export ACTIVE_CONFS_PATH="${ACTIVE_CONFS_PATH:-/config/server/activeconfs}"
export BUILD_VERSION_PATH="${BUILD_VERSION_PATH:-/config/server/build_version}"
export S6_ENV_DIR="${S6_ENV_DIR:-/config/server/s6env}"
export AWG_BINARY_PATH="${AWG_BINARY_PATH:-/usr/bin/awg}"
export API_PORT="${API_PORT:-8081}"

# --- Token management ---
if [ -z "$API_TOKEN" ]; then
    if [ -f "$CONFIG_DIR/server/api_token" ]; then
        API_TOKEN=$(cat "$CONFIG_DIR/server/api_token")
    else
        API_TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        mkdir -p "$CONFIG_DIR/server"
        # Create with the restrictive mode already in place — chmod after the
        # write leaves the token world-readable in between.
        (umask 077; printf '%s' "$API_TOKEN" > "$CONFIG_DIR/server/api_token")
        echo "API token generated: $API_TOKEN"
        echo "Save this token — it will not be shown again"
    fi
    export API_TOKEN
fi

# --- Wait for VPN container to populate config (optional) ---
if [ "${WAIT_FOR_CONFIG:-false}" = "true" ]; then
    echo "Waiting for VPN container to populate $CONFIG_DIR/server..."
    timeout=${WAIT_TIMEOUT:-60}
    elapsed=0
    while [ ! -f "$CONFIG_DIR/server/publickey-server" ] && [ "$elapsed" -lt "$timeout" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if [ ! -f "$CONFIG_DIR/server/publickey-server" ]; then
        echo "Warning: timed out waiting for config after ${timeout}s, starting anyway"
    fi
fi

exec /usr/bin/awg-api "$@"
