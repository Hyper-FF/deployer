#!/usr/bin/env bash
#
# StarRocks Docker Deployer
# One-click deployment of a StarRocks cluster in either single-node (allin1)
# or multi-node mode (separate FE / BE containers).
#
# Usage:
#   ./deploy.sh up      [--mode single|multi] [--fe N] [--be M]
#   ./deploy.sh down    [--volumes]
#   ./deploy.sh status
#   ./deploy.sh logs    [service]
#   ./deploy.sh sql     [-- mysql args...]
#   ./deploy.sh restart
#   ./deploy.sh regen          # regenerate multi-node compose file from .env
#
# Configuration lives in .env (see .env.example).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_DIR="$SCRIPT_DIR/compose"
GENERATED_DIR="$SCRIPT_DIR/generated"
SINGLE_COMPOSE="$COMPOSE_DIR/single-node.yml"
MULTI_COMPOSE="$GENERATED_DIR/multi-node.yml"
MODE_FILE="$GENERATED_DIR/.mode"

color() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info()  { color "0;36" "==> $*"; }
warn()  { color "0;33" "[!] $*" >&2; }
die()   { color "0;31" "[x] $*" >&2; exit 1; }

ensure_env() {
    if [ ! -f "$ENV_FILE" ]; then
        warn ".env not found, copying defaults from .env.example"
        cp .env.example "$ENV_FILE"
    fi
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    : "${STARROCKS_VERSION:=latest}"
    : "${RUN_MODE:=shared_nothing}"
    : "${CLUSTER_NAME:=starrocks}"
    : "${FE_COUNT:=3}"
    : "${BE_COUNT:=3}"
    : "${FE_QUERY_PORT:=9030}"
    : "${FE_HTTP_PORT:=8030}"
    : "${ROOT_PASSWORD:=}"
    export STARROCKS_VERSION RUN_MODE CLUSTER_NAME FE_COUNT BE_COUNT \
           FE_QUERY_PORT FE_HTTP_PORT ROOT_PASSWORD
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose --env-file "$ENV_FILE")
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose --env-file "$ENV_FILE")
    else
        die "neither 'docker compose' nor 'docker-compose' is available"
    fi
}

# ---- mode tracking ------------------------------------------------------------

save_mode() {
    mkdir -p "$GENERATED_DIR"
    echo "$1" > "$MODE_FILE"
}

current_mode() {
    [ -f "$MODE_FILE" ] && cat "$MODE_FILE" || echo ""
}

compose_file_for_mode() {
    case "$1" in
        single) echo "$SINGLE_COMPOSE" ;;
        multi)  echo "$MULTI_COMPOSE" ;;
        *)      die "unknown mode: $1" ;;
    esac
}

regen_multi() {
    mkdir -p "$GENERATED_DIR"
    bash "$SCRIPT_DIR/scripts/gen-multi-node.sh" > "$MULTI_COMPOSE"
    info "regenerated $MULTI_COMPOSE"
}

# ---- post-up actions ----------------------------------------------------------

apply_root_password() {
    [ -z "$ROOT_PASSWORD" ] && return 0
    local fe_container="$1"
    info "setting root password on $fe_container"
    docker exec "$fe_container" mysql -h 127.0.0.1 -P 9030 -u root \
        -e "SET PASSWORD FOR 'root' = PASSWORD('${ROOT_PASSWORD}');" \
        >/dev/null 2>&1 || warn "could not set root password (it may already be set)"
}

# ---- commands -----------------------------------------------------------------

cmd_up() {
    local mode=""
    local fe_override="" be_override=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode) mode="$2"; shift 2 ;;
            --fe)   fe_override="$2"; shift 2 ;;
            --be)   be_override="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    ensure_env
    require_docker

    [ -n "$fe_override" ] && export FE_COUNT="$fe_override"
    [ -n "$be_override" ] && export BE_COUNT="$be_override"

    if [ -z "$mode" ]; then
        if [ "${FE_COUNT}" -eq 1 ] && [ "${BE_COUNT}" -eq 1 ]; then
            mode="single"
        else
            mode="multi"
        fi
        info "auto-selected mode: $mode (FE_COUNT=$FE_COUNT, BE_COUNT=$BE_COUNT)"
    fi

    case "$mode" in
        single)
            info "deploying single-node StarRocks (allin1, version=$STARROCKS_VERSION)"
            "${COMPOSE[@]}" -f "$SINGLE_COMPOSE" --project-name "$CLUSTER_NAME" up -d
            save_mode single
            info "waiting for cluster to become ready..."
            bash "$SCRIPT_DIR/scripts/wait-ready.sh" "${CLUSTER_NAME}-allin1" 1 1 300
            apply_root_password "${CLUSTER_NAME}-allin1"
            ;;
        multi)
            info "deploying multi-node StarRocks (FE=$FE_COUNT, BE=$BE_COUNT, version=$STARROCKS_VERSION)"
            regen_multi
            "${COMPOSE[@]}" -f "$MULTI_COMPOSE" --project-name "$CLUSTER_NAME" up -d
            save_mode multi
            info "waiting for cluster to become ready..."
            bash "$SCRIPT_DIR/scripts/wait-ready.sh" "${CLUSTER_NAME}-fe-0" "$FE_COUNT" "$BE_COUNT" 600
            apply_root_password "${CLUSTER_NAME}-fe-0"
            ;;
        *) die "invalid --mode: $mode (expected: single|multi)" ;;
    esac

    info "StarRocks is up. Connect with:"
    echo "    mysql -h 127.0.0.1 -P ${FE_QUERY_PORT} -u root"
}

cmd_down() {
    local prune_volumes=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --volumes|-v) prune_volumes=1; shift ;;
            *) die "unknown option: $1" ;;
        esac
    done
    ensure_env
    require_docker

    local mode
    mode="$(current_mode)"
    [ -z "$mode" ] && { warn "no recorded mode; nothing to do."; return 0; }

    local compose_file
    compose_file="$(compose_file_for_mode "$mode")"
    [ "$mode" = "multi" ] && [ ! -f "$compose_file" ] && regen_multi

    local args=(down)
    [ "$prune_volumes" -eq 1 ] && args+=(-v)
    info "stopping cluster (mode=$mode, volumes=$prune_volumes)"
    "${COMPOSE[@]}" -f "$compose_file" --project-name "$CLUSTER_NAME" "${args[@]}"
    [ "$prune_volumes" -eq 1 ] && rm -f "$MODE_FILE"
}

cmd_status() {
    ensure_env; require_docker
    local mode; mode="$(current_mode)"
    [ -z "$mode" ] && { echo "cluster is not deployed."; return 0; }
    local f; f="$(compose_file_for_mode "$mode")"
    [ "$mode" = "multi" ] && [ ! -f "$f" ] && regen_multi
    "${COMPOSE[@]}" -f "$f" --project-name "$CLUSTER_NAME" ps
}

cmd_logs() {
    ensure_env; require_docker
    local mode; mode="$(current_mode)"
    [ -z "$mode" ] && die "cluster is not deployed."
    local f; f="$(compose_file_for_mode "$mode")"
    [ "$mode" = "multi" ] && [ ! -f "$f" ] && regen_multi
    "${COMPOSE[@]}" -f "$f" --project-name "$CLUSTER_NAME" logs --tail=200 -f "$@"
}

cmd_sql() {
    ensure_env; require_docker
    local mode; mode="$(current_mode)"
    local fe
    case "$mode" in
        single) fe="${CLUSTER_NAME}-allin1" ;;
        multi)  fe="${CLUSTER_NAME}-fe-0" ;;
        *)      die "cluster is not deployed." ;;
    esac
    local pwd_opt=()
    [ -n "$ROOT_PASSWORD" ] && pwd_opt=(-p"$ROOT_PASSWORD")
    docker exec -it "$fe" mysql -h 127.0.0.1 -P 9030 -u root "${pwd_opt[@]}" "$@"
}

cmd_restart() {
    ensure_env; require_docker
    local mode; mode="$(current_mode)"
    [ -z "$mode" ] && die "cluster is not deployed."
    local f; f="$(compose_file_for_mode "$mode")"
    [ "$mode" = "multi" ] && [ ! -f "$f" ] && regen_multi
    "${COMPOSE[@]}" -f "$f" --project-name "$CLUSTER_NAME" restart
}

usage() {
    cat <<EOF
StarRocks Docker Deployer

Commands:
  up [--mode single|multi] [--fe N] [--be M]
        Deploy the cluster. Mode is auto-detected from FE_COUNT/BE_COUNT
        in .env when omitted (FE=1 & BE=1 -> single, otherwise multi).

  down [--volumes|-v]
        Stop and remove containers. With --volumes also deletes all data.

  status
        Show container status for the current cluster.

  logs [service...]
        Tail container logs (follows). Pass service names to filter.

  sql [-- mysql args...]
        Open an interactive MySQL shell into the cluster's leader FE.

  restart
        Restart all containers without recreating them.

  regen
        Regenerate the multi-node compose file from the current .env.

Configuration is read from ./.env (see .env.example for defaults).
EOF
}

main() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        up)       cmd_up "$@" ;;
        down)     cmd_down "$@" ;;
        status|ps) cmd_status ;;
        logs)     cmd_logs "$@" ;;
        sql|mysql) cmd_sql "$@" ;;
        restart)  cmd_restart ;;
        regen)    ensure_env; regen_multi ;;
        ""|-h|--help|help) usage ;;
        *) die "unknown command: $cmd (run '$0 --help')" ;;
    esac
}

main "$@"
