# StarRocks Docker Deployer

One-click Docker deployment for StarRocks clusters. Supports both **single-node**
(allin1 image, FE + BE + feproxy in one container) and **multi-node** (separate
FE / BE containers, configurable count) deployments from the same CLI.

## Prerequisites

- Docker 20.10+ with the Compose plugin (`docker compose`) — or legacy
  `docker-compose` is also accepted.
- Outbound access to Docker Hub (or a mirror) for the
  `starrocks/allin1-ubuntu`, `starrocks/fe-ubuntu`, and `starrocks/be-ubuntu`
  images.
- Linux/macOS host with at least 4 GB RAM free for a single-node cluster, or
  ~2 GB per FE/BE container for multi-node.

## Quick start

```bash
# 1. Configure (optional — defaults work)
cp .env.example .env
$EDITOR .env

# 2a. Single-node cluster
./deploy.sh up --mode single

# 2b. Multi-node cluster (3 FE + 3 BE by default; tune with --fe / --be or .env)
./deploy.sh up --mode multi --fe 3 --be 3

# 3. Connect
mysql -h 127.0.0.1 -P 9030 -u root
# or
./deploy.sh sql
```

If `--mode` is omitted, the deployer auto-selects: `FE_COUNT=1` and
`BE_COUNT=1` give single-node, otherwise multi-node.

## Commands

| Command | What it does |
| --- | --- |
| `./deploy.sh up [--mode single\|multi] [--fe N] [--be M]` | Deploy the cluster, wait for it to become ready, optionally set the root password. |
| `./deploy.sh down [--volumes]` | Stop and remove containers. With `--volumes` also deletes the data volumes. |
| `./deploy.sh status` | Show container status for the active deployment. |
| `./deploy.sh logs [service]` | Tail logs (follow). Optional service name(s) filter. |
| `./deploy.sh sql` | Open an interactive MySQL shell against the leader FE. |
| `./deploy.sh restart` | Restart all containers in place. |
| `./deploy.sh regen` | Re-render the multi-node compose file from `.env`. |

## Configuration

All knobs live in `.env`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `STARROCKS_VERSION` | `latest` | Image tag (e.g. `3.4-latest`, `3.3.11`). |
| `RUN_MODE` | `shared_nothing` | `shared_nothing` or `shared_data` (single-node only). |
| `CLUSTER_NAME` | `starrocks` | Prefix for containers, network and volumes. |
| `FE_COUNT` | `3` | Number of FE nodes (multi-node). Use odd numbers for quorum. |
| `BE_COUNT` | `3` | Number of BE nodes (multi-node). |
| `FE_QUERY_PORT` | `9030` | Host port mapped to FE-0 query port. |
| `FE_HTTP_PORT` | `8030` | Host port mapped to FE-0 HTTP port. |
| `ROOT_PASSWORD` | _(empty)_ | Set the `root` password automatically after first start. |

`conf/fe.conf` and `conf/be.conf` are mounted read-only into every container
via the in-image `CONFIGMAP_MOUNT_PATH` mechanism. Edit them to customise
FE/BE settings and run `./deploy.sh restart`.

## How it works

- **Single-node** uses the official `starrocks/allin1-ubuntu` image, which
  ships a supervisord-managed FE + BE + feproxy in one container.
- **Multi-node** uses `starrocks/fe-ubuntu` and `starrocks/be-ubuntu` images.
  The deployer renders a compose file with `FE_COUNT` FE containers
  (`<cluster>-fe-0`..`<cluster>-fe-N`) and `BE_COUNT` BE containers,
  all on a shared bridge network. The first FE (`-fe-0`) bootstraps as the
  leader; later FEs auto-join as followers and BEs register themselves via
  `ALTER SYSTEM ADD BACKEND`, driven by the entrypoints shipped in the
  official images.

After `up`, `./deploy.sh` polls `SHOW FRONTENDS` and `SHOW BACKENDS` until
the expected number of nodes report `Alive=true`.

## Layout

```
deployer/
├── deploy.sh                 # main CLI
├── .env.example              # configuration template
├── conf/
│   ├── fe.conf               # FE config (mounted into every FE)
│   └── be.conf               # BE config (mounted into every BE)
├── compose/
│   └── single-node.yml       # static allin1 compose file
├── scripts/
│   ├── gen-multi-node.sh     # renders multi-node compose from .env
│   └── wait-ready.sh         # polls cluster readiness
└── generated/                # generated compose files + mode marker
```

## Notes

- The deployer remembers the last-used mode under `generated/.mode`, so
  `down`, `status`, `logs`, etc. work without re-specifying `--mode`.
- `down --volumes` wipes all data (meta + storage). Without it the volumes
  persist and the cluster can be brought back up with state intact.
- For production, increase FE count to 3 or 5 (odd), provision separate
  hosts, and configure storage paths in `conf/be.conf`.
