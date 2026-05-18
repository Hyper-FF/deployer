#!/usr/bin/env bash
# BE entrypoint, mounted into the container at /opt/sr-deployer/be-entrypoint.sh.
#
# Expectations inside the container:
#   /opt/starrocks/                <- shared, read-only (whole tarball)
#   /opt/starrocks/be/storage/     <- bind mount, private (writable)
#   /opt/starrocks/be/log/         <- bind mount, private (writable)
#   /opt/starrocks/be/conf/be.conf <- bind mount, file overlay (read-only)
#
# Required env:
#   LEADER_HOST   - hostname of FE-0 (e.g. starrocks-fe-0)
# Optional env:
#   FE_QUERY_PORT (9030), BE_HEARTBEAT_PORT (9050)

set -euo pipefail

: "${LEADER_HOST:?LEADER_HOST is required}"
FE_QUERY_PORT="${FE_QUERY_PORT:-9030}"
BE_HEARTBEAT_PORT="${BE_HEARTBEAT_PORT:-9050}"
BE_HOME="${STARROCKS_HOME:-/opt/starrocks}/be"

log() { echo "[be-entrypoint $(date +%H:%M:%S)] $*" >&2; }

install_tools() {
    local need=()
    command -v mysql >/dev/null 2>&1 || need+=(default-mysql-client)
    command -v nc    >/dev/null 2>&1 || need+=(netcat-openbsd)
    [ ${#need[@]} -eq 0 ] && return 0
    log "installing tools: ${need[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends "${need[@]}" >/dev/null
}
install_tools

MYSELF="$(hostname)"
mkdir -p "$BE_HOME/storage" "$BE_HOME/log"

log "waiting for leader $LEADER_HOST:$FE_QUERY_PORT..."
deadline=$(( $(date +%s) + 600 ))
until mysql --connect-timeout 2 -h "$LEADER_HOST" -P "$FE_QUERY_PORT" \
        -u root --skip-column-names --batch -e "SHOW FRONTENDS;" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        log "timed out waiting for FE"; exit 1
    fi
    sleep 2
done

log "registering self ($MYSELF:$BE_HEARTBEAT_PORT) as backend"
mysql --connect-timeout 2 -h "$LEADER_HOST" -P "$FE_QUERY_PORT" -u root \
    --skip-column-names --batch \
    -e "ALTER SYSTEM ADD BACKEND \"$MYSELF:$BE_HEARTBEAT_PORT\";" 2>&1 |
    grep -v "backend already exists" || true

exec "$BE_HOME/bin/start_be.sh" --logconsole
