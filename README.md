# StarRocks Docker Deployer

One-click Docker deployment for a StarRocks cluster **from a user-supplied
installation tarball** — no public image pulls. Supports both single-node
(FE=1 + BE=1) and multi-node (configurable N FE + M BE) topologies from the
same CLI.

## How it works

1. You drop a custom StarRocks tarball into `./packages/`.
2. `deploy.sh` builds a local runtime image (`runtime/Dockerfile`): a slim
   JDK base + the unpacked tarball + thin FE/BE entrypoints.
3. `deploy.sh` renders a docker-compose file for the requested number of FE
   and BE containers and brings the cluster up. FE-0 bootstraps; the others
   join as followers via `ALTER SYSTEM ADD FOLLOWER`; BEs register via
   `ALTER SYSTEM ADD BACKEND`.

## Prerequisites

- Docker 20.10+ with the Compose plugin (`docker compose`) or legacy
  `docker-compose`.
- A StarRocks tarball whose top-level directory contains `fe/` and `be/`
  subdirectories — i.e. the standard layout produced by StarRocks' build
  pipeline. Quick check on your tarball:
  ```bash
  tar -tzf packages/StarRocks-x.y.z.tar.gz | head
  # expected first lines:
  # StarRocks-x.y.z/
  # StarRocks-x.y.z/fe/...
  # StarRocks-x.y.z/be/...
  ```
- Around 4 GB RAM free for a 1FE+1BE cluster, or ~2 GB per FE/BE container
  for larger topologies.

## Quick start

```bash
# 1. Configure
cp .env.example .env
$EDITOR .env                       # set PACKAGE_FILE, FE_COUNT, BE_COUNT, ...

# 2. Put your tarball in place
cp /path/to/StarRocks-3.4.0.tar.gz packages/

# 3. Deploy (image is built automatically on first run)
./deploy.sh up                     # honours FE_COUNT/BE_COUNT from .env
./deploy.sh up --mode single       # alias for --fe 1 --be 1
./deploy.sh up --mode multi --fe 3 --be 3

# 4. Connect
./deploy.sh sql                    # interactive MySQL shell on FE-0
# or
mysql -h 127.0.0.1 -P 9030 -u root
```

## Commands

| Command | What it does |
| --- | --- |
| `./deploy.sh build [--no-cache]` | Build the runtime image from `packages/$PACKAGE_FILE`. |
| `./deploy.sh up [--mode single\|multi] [--fe N] [--be M] [--build]` | Deploy. Builds the image first if it doesn't exist or `--build` is given. |
| `./deploy.sh down [--volumes\|-v] [--image]` | Stop the cluster. `--volumes` deletes data, `--image` removes the runtime image. |
| `./deploy.sh status` | Show container status. |
| `./deploy.sh logs [service...]` | Tail logs (follows). |
| `./deploy.sh sql` | Interactive MySQL shell on FE-0. |
| `./deploy.sh restart` | Restart all containers in place. |
| `./deploy.sh regen` | Re-render the compose file from `.env`. |

## Configuration (`.env`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `PACKAGE_FILE` | _(required)_ | Filename of the tarball under `./packages/`. |
| `IMAGE_TAG` | `starrocks-local:latest` | Tag for the locally built runtime image. |
| `BASE_IMAGE` | `eclipse-temurin:17-jdk-jammy` | JDK-bearing base image. |
| `CLUSTER_NAME` | `starrocks` | Prefix for container, network and volume names. |
| `FE_COUNT` | `3` | Number of FE nodes (use odd values for quorum). |
| `BE_COUNT` | `3` | Number of BE nodes. |
| `FE_QUERY_PORT` | `9030` | Host port mapped to FE-0 query port. |
| `FE_HTTP_PORT` | `8030` | Host port mapped to FE-0 HTTP port. |
| `ROOT_PASSWORD` | _(empty)_ | If set, `root` password is applied after first start. |

`conf/fe.conf` and `conf/be.conf` are mounted read-only into every container
at `/etc/starrocks/conf`. The entrypoints overlay them onto the bundled
config at startup; run `./deploy.sh restart` to apply edits.

## Layout

```
deployer/
├── deploy.sh                # main CLI
├── .env.example             # configuration template
├── packages/                # drop your StarRocks-*.tar.gz here  (git-ignored)
├── runtime/
│   ├── Dockerfile           # builds the runtime image from the tarball
│   ├── fe-entrypoint.sh     # FE join/bootstrap logic
│   └── be-entrypoint.sh     # BE auto-register logic
├── conf/
│   ├── fe.conf              # FE config overlay
│   └── be.conf              # BE config overlay
├── scripts/
│   ├── gen-compose.sh       # renders the compose file from .env
│   └── wait-ready.sh        # polls cluster readiness
└── generated/               # generated compose file + deploy marker
```

## Notes

- The image is rebuilt only when you pass `--build` or the image tag does
  not exist locally. Bump `IMAGE_TAG` in `.env` when you ship a new tarball
  to keep old and new builds side-by-side.
- `down --volumes` wipes all FE meta and BE storage. Without it, volumes
  persist and the cluster can be brought back up with state intact.
- The deployer assumes the tarball is for the same architecture as the host
  (typically `linux/amd64`). For cross-arch deployments, set `BASE_IMAGE`
  to an image matching the tarball's arch.
- For production, run FE on 3 or 5 nodes (odd), use dedicated hosts, and
  configure storage paths via `conf/be.conf`.
