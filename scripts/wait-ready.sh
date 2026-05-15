#!/usr/bin/env bash
# Wait until the StarRocks cluster has the expected number of alive FE / BE nodes.
#
# Usage: wait-ready.sh <fe_container> <expected_fe> <expected_be> [timeout_seconds]

set -euo pipefail

fe_container="${1:?fe container name is required}"
expected_fe="${2:-1}"
expected_be="${3:-1}"
timeout="${4:-300}"

run_mysql() {
    docker exec "$fe_container" mysql --connect-timeout 2 \
        -h 127.0.0.1 -P 9030 -u root --skip-column-names --batch -e "$1" 2>/dev/null
}

count_alive() {
    # Counts rows whose Alive column equals "true". The Alive column position
    # varies across versions, so we match the literal token instead.
    awk -F'\t' '{ for (i=1;i<=NF;i++) if ($i == "true") { c++; next } } END { print c+0 }'
}

start=$(date +%s)
while true; do
    fes_alive=$(run_mysql "SHOW FRONTENDS;" | count_alive || echo 0)
    bes_alive=$(run_mysql "SHOW BACKENDS;"  | count_alive || echo 0)
    printf '  FE alive: %s/%s   BE alive: %s/%s\n' "$fes_alive" "$expected_fe" "$bes_alive" "$expected_be"

    if [ "${fes_alive:-0}" -ge "$expected_fe" ] && [ "${bes_alive:-0}" -ge "$expected_be" ]; then
        echo "Cluster is ready."
        exit 0
    fi

    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
        echo "Timed out waiting for cluster to become ready." >&2
        exit 1
    fi
    sleep 5
done
