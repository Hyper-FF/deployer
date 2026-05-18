#!/usr/bin/env bash
# FE entrypoint, mounted into the container at /opt/sr-deployer/fe-entrypoint.sh.
#
# Expectations inside the container:
#   /opt/starrocks/                <- shared, read-only (whole tarball)
#   /opt/starrocks/fe/meta/        <- bind mount, private (writable)
#   /opt/starrocks/fe/log/         <- bind mount, private (writable)
#   /opt/starrocks/fe/conf/fe.conf <- bind mount, file overlay (read-only)
#
# Required env:
#   LEADER_HOST   - hostname of FE-0 (e.g. starrocks-fe-0)
# Optional env:
#   FE_QUERY_PORT (9030), FE_EDIT_LOG_PORT (9010), HOST_TYPE (FQDN)

set -euo pipefail

: "${LEADER_HOST:?LEADER_HOST is required}"
FE_QUERY_PORT="${FE_QUERY_PORT:-9030}"
FE_EDIT_LOG_PORT="${FE_EDIT_LOG_PORT:-9010}"
HOST_TYPE="${HOST_TYPE:-FQDN}"
FE_HOME="${STARROCKS_HOME:-/opt/starrocks}/fe"

log() { echo "[fe-entrypoint $(date +%H:%M:%S)] $*" >&2; }

# ---- one-time tool install (cached via shared apt volume) --------------------
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

# ---- derive pod index from hostname (e.g. starrocks-fe-2 -> 2) ---------------
MYSELF="$(hostname)"
INDEX="${MYSELF##*-}"
if ! [[ "$INDEX" =~ ^[0-9]+$ ]]; then
    log "could not derive numeric index from hostname '$MYSELF'; assuming leader (0)"
    INDEX=0
fi

mkdir -p "$FE_HOME/meta" "$FE_HOME/log"

START_OPTS=(--logconsole --host_type "$HOST_TYPE")

# Already initialised? Just restart.
if [ -f "$FE_HOME/meta/image/ROLE" ]; then
    log "existing FE meta detected, starting without bootstrap"
    exec "$FE_HOME/bin/start_fe.sh" "${START_OPTS[@]}"
fi

if [ "$INDEX" = "0" ]; then
    log "bootstrapping FE leader ($MYSELF)"
    exec "$FE_HOME/bin/start_fe.sh" "${START_OPTS[@]}"
fi

# Follower path: wait for the leader, register, then start with --helper.
log "waiting for leader $LEADER_HOST:$FE_QUERY_PORT..."
deadline=$(( $(date +%s) + 600 ))
until mysql --connect-timeout 2 -h "$LEADER_HOST" -P "$FE_QUERY_PORT" \
        -u root --skip-column-names --batch -e "SHOW FRONTENDS;" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        log "timed out waiting for leader"; exit 1
    fi
    sleep 2
done

log "registering self ($MYSELF:$FE_EDIT_LOG_PORT) as follower"
mysql --connect-timeout 2 -h "$LEADER_HOST" -P "$FE_QUERY_PORT" -u root \
    --skip-column-names --batch \
    -e "ALTER SYSTEM ADD FOLLOWER \"$MYSELF:$FE_EDIT_LOG_PORT\";" 2>&1 |
    grep -v "frontend already exists" || true

exec "$FE_HOME/bin/start_fe.sh" "${START_OPTS[@]}" \
    --helper "$LEADER_HOST:$FE_EDIT_LOG_PORT"
