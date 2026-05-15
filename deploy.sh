#!/usr/bin/env bash
#
# StarRocks Docker Deployer
# One-click deployment of a StarRocks cluster from a user-supplied tarball,
# in either single-node (FE=1 + BE=1) or multi-node (N FE + M BE) topology.
#
# Workflow:
#   1. Drop StarRocks-x.y.z.tar.gz into ./packages/
#   2. Edit .env (PACKAGE_FILE, FE_COUNT, BE_COUNT, ...)
#   3. ./deploy.sh up
#
# Configuration lives in .env (see .env.example).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
GENERATED_DIR="$SCRIPT_DIR/generated"
COMPOSE_FILE="$GENERATED_DIR/cluster.yml"
DEPLOY_MARKER="$GENERATED_DIR/.deployed"
PACKAGES_DIR="$SCRIPT_DIR/packages"

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
    : "${IMAGE_TAG:=starrocks-local:latest}"
    : "${BASE_IMAGE:=eclipse-temurin:17-jdk-jammy}"
    : "${CLUSTER_NAME:=starrocks}"
    : "${FE_COUNT:=3}"
    : "${BE_COUNT:=3}"
    : "${FE_QUERY_PORT:=9030}"
    : "${FE_HTTP_PORT:=8030}"
    : "${ROOT_PASSWORD:=}"
    export PACKAGE_FILE IMAGE_TAG BASE_IMAGE CLUSTER_NAME \
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

regen_compose() {
    mkdir -p "$GENERATED_DIR"
    bash "$SCRIPT_DIR/scripts/gen-compose.sh" > "$COMPOSE_FILE"
    info "rendered $COMPOSE_FILE  (FE=$FE_COUNT, BE=$BE_COUNT)"
}

image_exists() {
    docker image inspect "$IMAGE_TAG" >/dev/null 2>&1
}

verify_package() {
    local path="$PACKAGES_DIR/$PACKAGE_FILE"
    [ -f "$path" ] || die "package not found: $path
Put the StarRocks tarball into ./packages/ and set PACKAGE_FILE in .env."
    # Quick structural check: expect a single top-level dir with fe/ and be/.
    local entries
    entries=$(tar -tzf "$path" 2>/dev/null | head -200 | awk -F/ '{print $1}' | sort -u | head -5)
    local top
    top=$(echo "$entries" | head -1)
    [ -n "$top" ] || die "could not read tarball: $path"
    if ! tar -tzf "$path" 2>/dev/null | grep -qE "^${top}/fe/bin/start_fe.sh\$"; then
        die "tarball $PACKAGE_FILE does not contain ${top}/fe/bin/start_fe.sh"
    fi
    if ! tar -tzf "$path" 2>/dev/null | grep -qE "^${top}/be/bin/start_be.sh\$"; then
        die "tarball $PACKAGE_FILE does not contain ${top}/be/bin/start_be.sh"
    fi
}

apply_root_password() {
    [ -z "$ROOT_PASSWORD" ] && return 0
    local fe_container="$1"
    info "setting root password on $fe_container"
    docker exec "$fe_container" mysql -h 127.0.0.1 -P 9030 -u root \
        -e "SET PASSWORD FOR 'root' = PASSWORD('${ROOT_PASSWORD}');" \
        >/dev/null 2>&1 || warn "could not set root password (it may already be set)"
}

mark_deployed() {
    mkdir -p "$GENERATED_DIR"
    touch "$DEPLOY_MARKER"
}

require_deployed() {
    [ -f "$DEPLOY_MARKER" ] || die "cluster is not deployed (run './deploy.sh up' first)"
    [ -f "$COMPOSE_FILE" ] || regen_compose
}

# ---- commands -----------------------------------------------------------------

cmd_build() {
    local no_cache=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-cache) no_cache=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done
    ensure_env
    require_docker
    verify_package

    info "building image $IMAGE_TAG from packages/$PACKAGE_FILE (base=$BASE_IMAGE)"
    local args=(build -f runtime/Dockerfile -t "$IMAGE_TAG"
                --build-arg "BASE_IMAGE=$BASE_IMAGE"
                --build-arg "PACKAGE_FILE=$PACKAGE_FILE")
    [ "$no_cache" -eq 1 ] && args+=(--no-cache)
    docker "${args[@]}" "$SCRIPT_DIR"
    info "image $IMAGE_TAG built"
}

cmd_up() {
    local mode="" fe_override="" be_override="" force_build=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode)  mode="$2"; shift 2 ;;
            --fe)    fe_override="$2"; shift 2 ;;
            --be)    be_override="$2"; shift 2 ;;
            --build) force_build=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    ensure_env
    require_docker

    case "$mode" in
        "")        ;;  # honour FE_COUNT/BE_COUNT from .env / overrides
        single)    fe_override="${fe_override:-1}"; be_override="${be_override:-1}" ;;
        multi)
            # Only force defaults if the user has FE=1/BE=1 in .env, which would
            # otherwise collapse to single-node.
            [ "$FE_COUNT" -eq 1 ] && [ -z "$fe_override" ] && fe_override=3
            [ "$BE_COUNT" -eq 1 ] && [ -z "$be_override" ] && be_override=3
            ;;
        *) die "invalid --mode: $mode (expected: single|multi)" ;;
    esac
    [ -n "$fe_override" ] && export FE_COUNT="$fe_override"
    [ -n "$be_override" ] && export BE_COUNT="$be_override"

    if [ "$force_build" -eq 1 ] || ! image_exists; then
        cmd_build
    else
        info "image $IMAGE_TAG already present (use --build to rebuild)"
    fi

    regen_compose
    info "starting cluster ($CLUSTER_NAME): FE=$FE_COUNT, BE=$BE_COUNT"
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
    local prune_volumes=0 prune_image=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --volumes|-v) prune_volumes=1; shift ;;
            --image)      prune_image=1; shift ;;
            *) die "unknown option: $1" ;;
        esac
    done
    ensure_env; require_docker
    [ -f "$COMPOSE_FILE" ] || regen_compose

    local args=(down)
    [ "$prune_volumes" -eq 1 ] && args+=(-v)
    info "stopping cluster (volumes=$prune_volumes)"
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" --project-name "$CLUSTER_NAME" "${args[@]}"
    [ "$prune_volumes" -eq 1 ] && rm -f "$DEPLOY_MARKER"
    if [ "$prune_image" -eq 1 ]; then
        info "removing image $IMAGE_TAG"
        docker image rm "$IMAGE_TAG" 2>/dev/null || warn "image $IMAGE_TAG was not present"
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
StarRocks Docker Deployer (package-based)

Workflow:
  1. cp .env.example .env  &&  edit it
  2. Place StarRocks-x.y.z.tar.gz into ./packages/
  3. ./deploy.sh up

Commands:
  build [--no-cache]
        Build the runtime image from ./packages/\${PACKAGE_FILE}.

  up [--mode single|multi] [--fe N] [--be M] [--build]
        Deploy the cluster. Builds the image first if it does not exist
        (or --build is given). --mode single forces FE=1,BE=1.

  down [--volumes|-v] [--image]
        Stop and remove containers. --volumes also deletes data volumes;
        --image also removes the locally built runtime image.

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
        build)             cmd_build "$@" ;;
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
