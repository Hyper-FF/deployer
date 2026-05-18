# StarRocks Docker Deployer

One-click Docker deployment for a StarRocks cluster **from a user-supplied
installation tarball, with no `docker build`**. The deployer:

1. Extracts your tarball **once** on the host into `./runtime-shared/`.
2. Starts FE / BE containers from a stock JDK Ubuntu image
   (`eclipse-temurin:17-jdk-jammy` by default), bind-mounting:
   - `./runtime-shared/` → `/opt/starrocks` (read-only, shared software root),
   - `./data/fe-<i>/{meta,log}` and `./data/be-<i>/{storage,log}` → private,
   - `./conf/{fe,be}.conf` → file-level config overlays,
   - `./runtime/*-entrypoint.sh` → `/opt/sr-deployer/` (read-only entrypoints).
3. FE-0 bootstraps as the leader; later FEs auto-join as followers via
   `ALTER SYSTEM ADD FOLLOWER`; BEs register via `ALTER SYSTEM ADD BACKEND`.

The entrypoints install `default-mysql-client` and `netcat-openbsd` on first
start of each container, cached in a shared Docker volume so subsequent
containers come up quickly.

## Prerequisites

- Docker 20.10+ with the Compose plugin (`docker compose`) or legacy
  `docker-compose`.
- Outbound network access on first container start to install the two apt
  packages above (after that they're cached in a docker volume).
- A StarRocks tarball whose top-level directory contains `fe/` and `be/`:
  ```bash
  tar -tzf packages/StarRocks-x.y.z.tar.gz | head -5
  # StarRocks-x.y.z/
  # StarRocks-x.y.z/fe/...
  # StarRocks-x.y.z/be/...
  ```
- ~4 GB RAM for a 1FE+1BE cluster, ~2 GB per additional FE/BE.

## Quick start

```bash
# 1. Configure
cp .env.example .env
$EDITOR .env                       # set PACKAGE_FILE, FE_COUNT, BE_COUNT, ...

# 2. Drop the tarball in
cp /path/to/StarRocks-3.4.0.tar.gz packages/

# 3. Deploy (extracts the package automatically on first run)
./deploy.sh up                     # FE_COUNT / BE_COUNT from .env
./deploy.sh up --mode single       # FE=1, BE=1
./deploy.sh up --mode multi --fe 3 --be 3

# 4. Connect
./deploy.sh sql
# or:
mysql -h 127.0.0.1 -P 9030 -u root
```

## Commands

| Command | What it does |
| --- | --- |
| `./deploy.sh prepare [--force]` | Extract `packages/$PACKAGE_FILE` into `runtime-shared/`. Auto-run by `up`. |
| `./deploy.sh up [--mode single\|multi] [--fe N] [--be M] [--prepare]` | Deploy. `--prepare` forces re-extracting the tarball first. |
| `./deploy.sh down [--volumes\|-v] [--data] [--shared] [--all]` | Stop and remove containers. Flags decide how much else to wipe. |
| `./deploy.sh status` | Show container status. |
| `./deploy.sh logs [service...]` | Tail logs (follows). |
| `./deploy.sh sql` | Interactive MySQL shell on FE-0. |
| `./deploy.sh restart` | Restart all containers in place. |
| `./deploy.sh regen` | Re-render the compose file from `.env`. |

## Configuration (`.env`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `PACKAGE_FILE` | _(required)_ | Filename of the tarball under `./packages/`. |
| `BASE_IMAGE` | `eclipse-temurin:17-jdk-jammy` | Ubuntu+JDK image used by every FE/BE container. |
| `CLUSTER_NAME` | `starrocks` | Prefix for container, network and volume names. |
| `FE_COUNT` | `3` | Number of FE nodes (use odd values for quorum). |
| `BE_COUNT` | `3` | Number of BE nodes. |
| `FE_QUERY_PORT` | `9030` | Host port mapped to FE-0 query port. |
| `FE_HTTP_PORT` | `8030` | Host port mapped to FE-0 HTTP port. |
| `ROOT_PASSWORD` | _(empty)_ | If set, the `root` password is applied after first start. |

`conf/fe.conf` and `conf/be.conf` are bind-mounted **as single files** over
the defaults from the tarball, so other config files (`hadoop_env.sh`,
`udf_security.policy`, …) keep coming from `runtime-shared/`. Edit either
file and run `./deploy.sh restart` to apply.

## Layout

```
deployer/
├── deploy.sh                     # main CLI
├── .env.example                  # configuration template
├── packages/                     # drop StarRocks-*.tar.gz here  (git-ignored)
├── runtime-shared/               # extracted once on host, shared RO        (gitignored)
├── data/                         # per-container meta / storage / log dirs  (gitignored)
│   ├── fe-0/{meta,log}/
│   └── be-0/{storage,log}/
├── conf/
│   ├── fe.conf                   # FE config overlay
│   └── be.conf                   # BE config overlay
├── runtime/
│   ├── fe-entrypoint.sh          # mounted into FE containers
│   └── be-entrypoint.sh          # mounted into BE containers
├── scripts/
│   ├── prepare.sh                # extract tarball into runtime-shared/
│   ├── gen-compose.sh            # render generated/cluster.yml from .env
│   └── wait-ready.sh             # poll cluster readiness
└── generated/                    # generated compose file + deploy marker   (gitignored)
```

## How a container is composed (no Dockerfile involved)

```
container:                              host (bind-mounted in):
/opt/starrocks/             (ro)   <─   ./runtime-shared/
/opt/sr-deployer/           (ro)   <─   ./runtime/                      (entrypoints)
/opt/starrocks/fe/conf/fe.conf (ro)<─   ./conf/fe.conf                  (overlay file)
/opt/starrocks/fe/meta/     (rw)   <─   ./data/fe-<i>/meta/
/opt/starrocks/fe/log/      (rw)   <─   ./data/fe-<i>/log/
/var/cache/apt              (rw)   <─   docker volume apt_cache         (shared across containers)
/var/lib/apt/lists          (rw)   <─   docker volume apt_lists
```

The container's `entrypoint:` is `/opt/sr-deployer/fe-entrypoint.sh` (or
`be-entrypoint.sh`). That script installs mysql/nc on the first run, then
runs `start_fe.sh --logconsole` / `start_be.sh --logconsole`. Restarts and
recreates re-use the cached apt volume.

## Notes

- `down --data` deletes FE meta + BE storage. `down --shared` deletes the
  extracted software root (a fresh `up` will re-extract). `down --all` is
  the full nuke.
- New tarball? Update `PACKAGE_FILE` in `.env` and run
  `./deploy.sh up --prepare` (or `./deploy.sh prepare --force` followed by
  `./deploy.sh up`).
- The extracted tree is mounted read-only, so the deployer applies
  `chmod -R a+rX` on the host once during prepare. `start_be.sh` also tries
  to `chmod 755` its own binary at startup; that no-ops harmlessly on the
  read-only mount.
- For production, run FE on 3 or 5 nodes (odd), use dedicated hosts, and
  point BE storage at fast disks via `conf/be.conf`.
