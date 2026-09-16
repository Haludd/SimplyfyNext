#!/bin/sh
# Railway remounts the persistent volume root-owned on every container start,
# regardless of any ownership set in a previous run. Fix it up here (while still
# root) before dropping to the unprivileged runtime user for the actual process.
set -e

chown -R simplynext:simplynext /app/spend

exec setpriv --reuid=simplynext --regid=simplynext --init-groups "$@"
