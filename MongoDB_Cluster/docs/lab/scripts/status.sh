#!/usr/bin/env bash
# One-shot overview of the whole lab: containers, replica set, health
# checkers, VIP owner and HAProxy backend states.
#
#   bash scripts/status.sh
#
# Read-only; safe while any part of the lab is down.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== containers ==="
docker compose ps
echo

echo "=== replica set (per member) ==="
for svc in mongo1 mongo2 mongo3; do
    printf -- '-- %s --\n' "$svc"
    if docker compose exec -T "$svc" mongosh --quiet \
         --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1; then
        docker compose exec -T "$svc" mongosh --quiet --eval '
          try {
            const h = db.hello();
            print("  me=" + h.me
                  + " setName=" + h.setName
                  + " isWritablePrimary=" + h.isWritablePrimary
                  + " secondary=" + h.secondary
                  + " primary=" + h.primary);
            rs.status().members.forEach(function (m) {
              print("  member " + m.name + " state=" + m.stateStr + " health=" + m.health);
            });
          } catch (e) {
            print("  rs.status() error: " + e.message);
          }
        ' 2>/dev/null || true
    else
        echo "  (not reachable - container stopped/paused?)"
    fi
done
echo

echo "=== health checkers (200 = that mongod is the PRIMARY) ==="
# http.client (unlike urllib) does not raise on 503, so we can print the code.
for n in 1 2 3; do
    printf '  health%s: ' "$n"
    docker compose exec -T "health$n" python -c \
      'import http.client as h; c = h.HTTPConnection("127.0.0.1", 9201, timeout=2); c.request("GET", "/primary"); print(c.getresponse().status)' \
      2>/dev/null || echo "unreachable"
done
echo

echo "=== VIP 172.30.77.100 owner ==="
vip_found=0
for p in proxy1 proxy2; do
    printf '  %s: ' "$p"
    if docker compose exec -T "$p" ip -4 addr show dev eth0 2>/dev/null \
         | grep -q '172.30.77.100/24'; then
        echo "HOLDS THE VIP"
        vip_found=1
    else
        echo "no VIP"
    fi
done
if [ "$vip_found" -eq 0 ]; then
    echo "  WARNING: nobody holds the VIP"
fi
echo

echo "=== HAProxy backend mongodb_primary ==="
for p in proxy1 proxy2; do
    echo "  -- $p --"
    docker compose exec -T "$p" sh -c \
      'echo "show stat" | socat -t 2 stdio UNIX-CONNECT:/var/run/haproxy.sock' \
      2>/dev/null \
      | awk -F, '
          NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
          $1 == "mongodb_primary" {
            printf "    %-7s status=%-4s chkfail=%s chkdown=%s lastchg=%ss\n",
                   $c["svname"], $c["status"], $c["chkfail"], $c["chkdown"], $c["lastchg"]
          }' \
      || echo "    (proxy not reachable)"
done
echo

echo "=== quick write test through the VIP ==="
if docker compose exec -T client mongosh --quiet \
     'mongodb://172.30.77.100:27017/labtest?directConnection=true&w=majority' \
     --eval 'try {
                db.probe.insertOne({ at: new Date(), from: "status.sh" });
                print("  write OK, primary=" + db.hello().primary);
              } catch (e) {
                print("  write FAILED: " + e.message);
              }' 2>/dev/null; then
    :
else
    echo "  client or VIP unreachable"
fi
