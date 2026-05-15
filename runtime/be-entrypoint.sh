#!/usr/bin/env bash
# BE entrypoint for cluster deployments backed by a user-supplied StarRocks tarball.
#
# Behaviour:
#   * Waits for the FE leader to be reachable.
#   * Registers itself via ALTER SYSTEM ADD BACKEND (idempotent).
#   * Overlays /etc/starrocks/conf/be.conf onto the bundled config if present.
#
# Required env:
#   LEADER_HOST   - hostname of FE index 0 (e.g. starrocks-fe-0)
# Optional:
#   FE_QUERY_PORT (default 9030), BE_HEARTBEAT_PORT (default 9050)

set -euo pipefail

: "${LEADER_HOST:?LEADER_HOST is required}"
FE_QUERY_PORT="${FE_QUERY_PORT:-9030}"
BE_HEARTBEAT_PORT="${BE_HEARTBEAT_PORT:-9050}"

SR_HOME="${STARROCKS_HOME:-/opt/starrocks}"
BE_HOME="$SR_HOME/be"
CONF_OVERLAY="/etc/starrocks/conf"

log() { echo "[be-entrypoint $(date +%H:%M:%S)] $*" >&2; }

if [ -d "$CONF_OVERLAY" ]; then
    for f in "$CONF_OVERLAY"/be.conf "$CONF_OVERLAY"/be.conf.d/*.conf; do
        [ -f "$f" ] || continue
        log "applying conf overlay: $f"
        cp -f "$f" "$BE_HOME/conf/$(basename "$f")"
    done
fi

MYSELF="$(hostname)"

log "waiting for leader $LEADER_HOST:$FE_QUERY_PORT..."
deadline=$(( $(date +%s) + 600 ))
until mysql --connect-timeout 2 -h "$LEADER_HOST" -P "$FE_QUERY_PORT" \
        -u root --skip-column-names --batch -e "SHOW FRONTENDS;" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        log "timed out waiting for FE"
        exit 1
    fi
    sleep 2
done

log "registering self ($MYSELF:$BE_HEARTBEAT_PORT) as backend"
mysql --connect-timeout 2 -h "$LEADER_HOST" -P "$FE_QUERY_PORT" -u root \
    --skip-column-names --batch \
    -e "ALTER SYSTEM ADD BACKEND \"$MYSELF:$BE_HEARTBEAT_PORT\";" 2>&1 |
    grep -v "backend already exists" || true

exec "$BE_HOME/bin/start_be.sh" --logconsole
