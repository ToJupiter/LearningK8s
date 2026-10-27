#!/usr/bin/env bash
# Wait until one member of replica set "labrs" reports isWritablePrimary=true.
#
#   bash scripts/wait-for-primary.sh [timeout_seconds]   # default 90
#
# Used by init-replica.sh, and handy during failover labs:
#   bash scripts/wait-for-primary.sh 30

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TIMEOUT="${1:-90}"
MONGO_SERVICES=(mongo1 mongo2 mongo3)

start=$(date +%s)
while :; do
    for svc in "${MONGO_SERVICES[@]}"; do
        # A stopped / paused container makes this command fail -> simply skip.
        if docker compose exec -T "$svc" mongosh --quiet \
             --eval 'try { print(db.hello().isWritablePrimary) } catch (e) { print("false") }' \
             2>/dev/null | grep -qx 'true'; then
            elapsed=$(( $(date +%s) - start ))
            echo "PRIMARY: $svc (after ${elapsed}s)"
            docker compose exec -T "$svc" mongosh --quiet --eval '
              const h = db.hello();
              print("  setName=" + h.setName + " me=" + h.me + " primary=" + h.primary);
            ' 2>/dev/null || true
            exit 0
        fi
    done
    if [ $(( $(date +%s) - start )) -ge "$TIMEOUT" ]; then
        echo "NO PRIMARY after ${TIMEOUT}s"
        echo "  Check: docker compose ps   and   bash scripts/status.sh"
        exit 1
    fi
    sleep 1
done
