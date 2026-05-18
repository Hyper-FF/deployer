#!/usr/bin/env bash
#
# StarRocks Docker Deployer (no docker build)
#
# Workflow:
#   1. Drop StarRocks-x.y.z.tar.gz into ./packages/
#   2. Edit .env  (PACKAGE_FILE, FE_COUNT, BE_COUNT, ...)
#   3. ./deploy.sh up
#
# 'up' extracts the tarball once into ./runtime-shared/ on the host, creates
# per-container private data dirs under ./data/, and starts FE / BE containers
# from the stock BASE_IMAGE with everything bind-mounted. No image build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
GENERATED_DIR="$SCRIPT_DIR/generated"
COMPOSE_FILE="$GENERATED_DIR/cluster.yml"
DEPLOY_MARKER="$GENERATED_DIR/.deployed"
PACKAGES_DIR="$SCRIPT_DIR/packages"
SHARED_DIR="$SCRIPT_DIR/runtime-shared"
DATA_DIR="$SCRIPT_DIR/data"

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
    : "${PACKAGE_FILE:?PACKAGE_FILE must be set in .env}"
    : "${BASE_IMAGE:=eclipse-temurin:17-jdk-jammy}"
    : "${CLUSTER_NAME:=starrocks}"
    : "${FE_COUNT:=3}"
    : "${BE_COUNT:=3}"
    : "${FE_QUERY_PORT:=9030}"
    : "${FE_HTTP_PORT:=8030}"
    : "${ROOT_PASSWORD:=}"
    export PACKAGE_FILE BASE_IMAGE CLUSTER_NAME \
           FE_COUNT BE_COUNT FE_QUERY_PORT FE_HTTP_PORT ROOT_PASSWORD
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

# ---- helpers ------------------------------------------------------------------

prepare_shared() {
    bash "$SCRIPT_DIR/scripts/prepare.sh" "$@"
}

ensure_data_dirs() {
    for i in $(seq 0 $((FE_COUNT - 1))); do
        mkdir -p "$DATA_DIR/fe-$i/meta" "$DATA_DIR/fe-$i/log"
    done
    for i in $(seq 0 $((BE_COUNT - 1))); do
        mkdir -p "$DATA_DIR/be-$i/storage" "$DATA_DIR/be-$i/log"
    done
}

regen_compose() {
    mkdir -p "$GENERATED_DIR"
    bash "$SCRIPT_DIR/scripts/gen-compose.sh" > "$COMPOSE_FILE"
    info "rendered $COMPOSE_FILE  (FE=$FE_COUNT, BE=$BE_COUNT)"
}

apply_root_password() {
    [ -z "$ROOT_PASSWORD" ] && return 0
    local fe_container="$1"
    info "setting root password on $fe_container"
    docker exec "$fe_container" mysql -h 127.0.0.1 -P 9030 -u root \
        -e "SET PASSWORD FOR 'root' = PASSWORD('${ROOT_PASSWORD}');" \
        >/dev/null 2>&1 || warn "could not set root password (it may already be set)"
}

mark_deployed() { mkdir -p "$GENERATED_DIR" && touch "$DEPLOY_MARKER"; }

require_deployed() {
    [ -f "$DEPLOY_MARKER" ] || die "cluster is not deployed (run './deploy.sh up' first)"
    [ -f "$COMPOSE_FILE" ] || regen_compose
}

# ---- commands -----------------------------------------------------------------

cmd_prepare() {
    local force=0
    [ "${1:-}" = "--force" ] && force=1
    ensure_env
    if [ "$force" -eq 1 ]; then
        prepare_shared --force
    else
        prepare_shared
    fi
}

cmd_up() {
    local mode="" fe_override="" be_override="" reprepare=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode)    mode="$2"; shift 2 ;;
            --fe)      fe_override="$2"; shift 2 ;;
            --be)      be_override="$2"; shift 2 ;;
            --prepare) reprepare=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    ensure_env
    require_docker

    case "$mode" in
        "")      ;;  # honour FE_COUNT/BE_COUNT from .env / overrides
        single)  fe_override="${fe_override:-1}"; be_override="${be_override:-1}" ;;
        multi)
            [ "$FE_COUNT" -eq 1 ] && [ -z "$fe_override" ] && fe_override=3
            [ "$BE_COUNT" -eq 1 ] && [ -z "$be_override" ] && be_override=3
            ;;
        *) die "invalid --mode: $mode (expected: single|multi)" ;;
    esac
    [ -n "$fe_override" ] && export FE_COUNT="$fe_override"
    [ -n "$be_override" ] && export BE_COUNT="$be_override"

    if [ "$reprepare" -eq 1 ]; then
        prepare_shared --force
    else
        prepare_shared
    fi
    ensure_data_dirs
    regen_compose

    info "starting cluster ($CLUSTER_NAME): FE=$FE_COUNT, BE=$BE_COUNT, base=$BASE_IMAGE"
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" --project-name "$CLUSTER_NAME" up -d
    mark_deployed

    info "waiting for cluster to become ready..."
    bash "$SCRIPT_DIR/scripts/wait-ready.sh" "${CLUSTER_NAME}-fe-0" \
        "$FE_COUNT" "$BE_COUNT" 600
    apply_root_password "${CLUSTER_NAME}-fe-0"

    info "StarRocks is up. Connect with:"
    echo "    mysql -h 127.0.0.1 -P ${FE_QUERY_PORT} -u root"
}

cmd_down() {
    local prune_volumes=0 prune_data=0 prune_shared=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --volumes|-v) prune_volumes=1; shift ;;
            --data)       prune_data=1; prune_volumes=1; shift ;;
            --shared)     prune_shared=1; shift ;;
            --all)        prune_volumes=1; prune_data=1; prune_shared=1; shift ;;
            *) die "unknown option: $1" ;;
        esac
    done
    ensure_env; require_docker
    [ -f "$COMPOSE_FILE" ] || regen_compose

    local args=(down)
    [ "$prune_volumes" -eq 1 ] && args+=(-v)
    info "stopping cluster (volumes=$prune_volumes data=$prune_data shared=$prune_shared)"
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" --project-name "$CLUSTER_NAME" "${args[@]}"

    if [ "$prune_volumes" -eq 1 ]; then
        rm -f "$DEPLOY_MARKER"
    fi
    if [ "$prune_data" -eq 1 ]; then
        info "removing ./data/"
        rm -rf "$DATA_DIR"
    fi
    if [ "$prune_shared" -eq 1 ]; then
        info "removing ./runtime-shared/"
        rm -rf "$SHARED_DIR"
    fi
}

cmd_status() {
    ensure_env; require_docker
    [ -f "$DEPLOY_MARKER" ] || { echo "cluster is not deployed."; return 0; }
    [ -f "$COMPOSE_FILE" ] || regen_compose
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" --project-name "$CLUSTER_NAME" ps
}

cmd_logs() {
    ensure_env; require_docker; require_deployed
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" --project-name "$CLUSTER_NAME" \
        logs --tail=200 -f "$@"
}

cmd_sql() {
    ensure_env; require_docker; require_deployed
    local pwd_opt=()
    [ -n "$ROOT_PASSWORD" ] && pwd_opt=(-p"$ROOT_PASSWORD")
    docker exec -it "${CLUSTER_NAME}-fe-0" \
        mysql -h 127.0.0.1 -P 9030 -u root "${pwd_opt[@]}" "$@"
}

cmd_restart() {
    ensure_env; require_docker; require_deployed
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" --project-name "$CLUSTER_NAME" restart
}

cmd_regen() {
    ensure_env
    regen_compose
}

usage() {
    cat <<EOF
StarRocks Docker Deployer (no docker build)

Workflow:
  1. cp .env.example .env  &&  edit it
  2. Place StarRocks-x.y.z.tar.gz into ./packages/
  3. ./deploy.sh up

Commands:
  prepare [--force]
        Extract ./packages/\${PACKAGE_FILE} into ./runtime-shared/ on the host.
        Called automatically by 'up'; --force re-extracts.

  up [--mode single|multi] [--fe N] [--be M] [--prepare]
        Deploy the cluster. Auto-extracts the package on first run.
        --mode single forces FE=1,BE=1; --prepare forces a re-extract first.

  down [--volumes|-v] [--data] [--shared] [--all]
        Stop and remove containers.
          --volumes/-v  also remove docker volumes (apt cache, etc.)
          --data        also wipe ./data/ (FE meta, BE storage, all logs)
          --shared      also delete ./runtime-shared/
          --all         all of the above

  status            Show container status.
  logs [service...] Tail container logs (follows).
  sql               Interactive MySQL shell into FE-0.
  restart           Restart all containers.
  regen             Re-render the compose file from .env.

Configuration is read from ./.env (see .env.example for defaults).
EOF
}

main() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        prepare)           cmd_prepare "$@" ;;
        up)                cmd_up "$@" ;;
        down)              cmd_down "$@" ;;
        status|ps)         cmd_status ;;
        logs)              cmd_logs "$@" ;;
        sql|mysql)         cmd_sql "$@" ;;
        restart)           cmd_restart ;;
        regen)             cmd_regen ;;
        ""|-h|--help|help) usage ;;
        *) die "unknown command: $cmd (run '$0 --help')" ;;
    esac
}

main "$@"
