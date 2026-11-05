#!/usr/bin/env bash
# Initialise the MongoDB replica set "labrs" (run ONCE on a fresh lab).
#
#   bash scripts/init-replica.sh
#
# Safe to re-run: an already initialised set is detected and left alone.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

MONGO_SERVICES=(mongo1 mongo2 mongo3)

echo "=== 1/3 waiting for mongod on every member ==="
for svc in "${MONGO_SERVICES[@]}"; do
    printf '  %-7s ' "$svc"
    ready=0
    for _ in $(seq 1 120); do
        if docker compose exec -T "$svc" mongosh --quiet \
             --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -q '^1$'; then
            ready=1
            break
        fi
        sleep 1
    done
    if [ "$ready" -eq 1 ]; then
        echo "READY"
    else
        echo "TIMEOUT"
        echo "  mongod in $svc never answered. Check: docker compose logs $svc"
        exit 1
    fi
done

echo
echo "=== 2/3 rs.initiate() ==="
# mongo1 priority 2 => mongo1 is the *preferred* first primary (not guaranteed).
docker compose exec -T mongo1 mongosh --quiet --eval '
const config = {
  _id: "labrs",
  members: [
    { _id: 0, host: "mongo1:27017", priority: 2 },
    { _id: 1, host: "mongo2:27017", priority: 1 },
    { _id: 2, host: "mongo3:27017", priority: 1 }
  ]
};
try {
  rs.initiate(config);
  print("Replica set initiated: labrs");
} catch (e) {
  if (e.code === 23 || e.codeName === "AlreadyInitialized") {
    print("Replica set already initialised - nothing to do");
  } else {
    throw e;
  }
}
'

echo
echo "=== 3/3 waiting for a primary to be elected ==="
exec bash scripts/wait-for-primary.sh 90
