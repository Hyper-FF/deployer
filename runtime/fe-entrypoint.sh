#!/usr/bin/env bash
# FE entrypoint for cluster deployments backed by a user-supplied StarRocks tarball.
#
# Behaviour:
#   * The container's hostname must end in "-<index>" (e.g. starrocks-fe-0).
#     Index 0 bootstraps the cluster; non-zero indexes register themselves with
#     the leader via ALTER SYSTEM ADD FOLLOWER and start with --helper.
#   * On subsequent restarts (FE/meta/image/ROLE present) the FE just starts.
#   * A populated /etc/starrocks/conf directory overrides bundled FE config.
#
# Required env:
#   LEADER_HOST   - hostname of FE index 0 (e.g. starrocks-fe-0)
# Optional:
#   FE_QUERY_PORT (default 9030), FE_EDIT_LOG_PORT (default 9010), HOST_TYPE (default FQDN)

set -euo pipefail

: "${LEADER_HOST:?LEADER_HOST is required}"
FE_QUERY_PORT="${FE_QUERY_PORT:-9030}"
FE_EDIT_LOG_PORT="${FE_EDIT_LOG_PORT:-9010}"
HOST_TYPE="${HOST_TYPE:-FQDN}"

SR_HOME="${STARROCKS_HOME:-/opt/starrocks}"
FE_HOME="$SR_HOME/fe"
CONF_OVERLAY="/etc/starrocks/conf"

log() { echo "[fe-entrypoint $(date +%H:%M:%S)] $*" >&2; }

# Overlay user-provided fe.conf, if any.
if [ -d "$CONF_OVERLAY" ]; then
    for f in "$CONF_OVERLAY"/fe.conf "$CONF_OVERLAY"/fe.conf.d/*.conf; do
        [ -f "$f" ] || continue
        log "applying conf overlay: $f"
        cp -f "$f" "$FE_HOME/conf/$(basename "$f")"
    done
fi

MYSELF="$(hostname)"
# starrocks-fe-2 -> 2
INDEX="${MYSELF##*-}"
if ! [[ "$INDEX" =~ ^[0-9]+$ ]]; then
    log "could not derive numeric pod index from hostname '$MYSELF'; assuming leader (0)"
    INDEX=0
fi

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
log "waiting for leader $LEADER_HOST:$FE_QUERY_PORT to be reachable..."
deadline=$(( $(date +%s) + 600 ))
until mysql --connect-timeout 2 -h "$LEADER_HOST" -P "$FE_QUERY_PORT" \
        -u root --skip-column-names --batch -e "SHOW FRONTENDS;" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        log "timed out waiting for leader"
        exit 1
    fi
    sleep 2
done

log "registering self ($MYSELF:$FE_EDIT_LOG_PORT) as follower"
# Idempotent: ignore "already exists" errors.
mysql --connect-timeout 2 -h "$LEADER_HOST" -P "$FE_QUERY_PORT" -u root \
    --skip-column-names --batch \
    -e "ALTER SYSTEM ADD FOLLOWER \"$MYSELF:$FE_EDIT_LOG_PORT\";" 2>&1 |
    grep -v "frontend already exists" || true

exec "$FE_HOME/bin/start_fe.sh" "${START_OPTS[@]}" \
    --helper "$LEADER_HOST:$FE_EDIT_LOG_PORT"
