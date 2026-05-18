#!/usr/bin/env bash
# Extract the StarRocks tarball from ./packages/ into ./runtime-shared/ on the
# host. The extracted tree is mounted (read-only) into every FE / BE container
# at /opt/starrocks, so this only needs to happen once per release.
#
# Usage: prepare.sh [--force]
#   --force  remove an existing runtime-shared/ and re-extract

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${PACKAGE_FILE:?PACKAGE_FILE is required}"

force=0
[ "${1:-}" = "--force" ] && force=1

pkg="$ROOT_DIR/packages/$PACKAGE_FILE"
shared="$ROOT_DIR/runtime-shared"
stamp="$shared/.deployer-pkg"

if [ ! -f "$pkg" ]; then
    echo "package not found: $pkg" >&2
    exit 1
fi

# Sanity-check the tarball layout: expect a single top-level dir
# containing fe/bin/start_fe.sh and be/bin/start_be.sh.
top=$(tar -tzf "$pkg" 2>/dev/null | awk -F/ 'NF>0 {print $1; exit}')
[ -n "$top" ] || { echo "tarball appears empty: $pkg" >&2; exit 1; }
if ! tar -tzf "$pkg" 2>/dev/null | grep -qE "^${top}/fe/bin/start_fe\.sh\$"; then
    echo "tarball $PACKAGE_FILE missing ${top}/fe/bin/start_fe.sh" >&2; exit 1
fi
if ! tar -tzf "$pkg" 2>/dev/null | grep -qE "^${top}/be/bin/start_be\.sh\$"; then
    echo "tarball $PACKAGE_FILE missing ${top}/be/bin/start_be.sh" >&2; exit 1
fi

# Skip if already extracted from this same package.
sig=$(sha256sum "$pkg" | awk '{print $1}')
if [ "$force" -eq 0 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$sig" ]; then
    echo "runtime-shared/ already populated from $PACKAGE_FILE — skipping extract"
    exit 0
fi

echo "extracting $PACKAGE_FILE -> runtime-shared/"
rm -rf "$shared"
mkdir -p "$shared"
tar -xzf "$pkg" -C "$shared" --strip-components=1

# Make sure the BE binary is executable; start_be.sh chmods it at runtime
# but the shared tree is mounted read-only.
chmod -R a+rX "$shared"
chmod 755 "$shared/be/lib"/starrocks_be 2>/dev/null || true
chmod 755 "$shared/be/bin"/*.sh "$shared/fe/bin"/*.sh 2>/dev/null || true

echo "$sig" > "$stamp"
echo "runtime-shared/ ready ($(du -sh "$shared" | awk '{print $1}'))"
