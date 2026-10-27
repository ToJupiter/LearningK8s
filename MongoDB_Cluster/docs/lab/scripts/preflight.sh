#!/usr/bin/env bash
# Host / lab preflight. Safe to run any number of times, changes nothing.
#
#   bash scripts/preflight.sh
#
# Exit code 0 = everything required is OK, you may run docker compose up.

set -uo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBNET="172.30.77.0/24"
VIP="172.30.77.100"

REQUIRED_FILES=(
    compose.yaml
    health/Dockerfile
    health/requirements.txt
    health/health.py
    proxy/Dockerfile
    proxy/haproxy.cfg
    proxy/keepalived-a.conf
    proxy/keepalived-b.conf
    proxy/check-haproxy.sh
    proxy/start.sh
    scripts/init-replica.sh
    scripts/wait-for-primary.sh
    scripts/status.sh
)

fail=0
ok()   { printf '  [ OK ] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=1; }

echo "=== MongoDB HA lab preflight ==="
echo "lab dir : $LAB_DIR"
echo

echo "-- lab files --"
for f in "${REQUIRED_FILES[@]}"; do
    if [ -f "$LAB_DIR/$f" ]; then ok "$f"; else bad "$f missing"; fi
done
for f in proxy/check-haproxy.sh proxy/start.sh scripts/init-replica.sh \
         scripts/wait-for-primary.sh scripts/status.sh; do
    [ -f "$LAB_DIR/$f" ] || continue
    if [ -x "$LAB_DIR/$f" ]; then ok "$f executable"; else bad "$f not executable (chmod +x)"; fi
done

echo
echo "-- docker --"
if command -v docker >/dev/null 2>&1; then
    ok "docker client: $(docker --version)"
else
    bad "docker client not installed"
fi

if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable"
    ok "server: $(docker version --format '{{.Server.Version}}') ({{.Server.Os}}/{{.Server.Arch}})"
else
    bad "docker daemon not reachable for $(id -un)"
    echo "       fix: sudo usermod -aG docker $(id -un)   # then run docker via: sg docker -c '...'"
fi

if docker compose version >/dev/null 2>&1; then
    ok "compose: $(docker compose version | head -1)"
else
    bad "docker compose v2 plugin missing"
fi

echo
echo "-- compose file --"
if (cd "$LAB_DIR" && docker compose config --quiet >/dev/null 2>&1); then
    ok "compose.yaml parses"
else
    bad "compose.yaml does not parse: (cd $LAB_DIR && docker compose config)"
fi

echo
echo "-- lab subnet $SUBNET / VIP $VIP --"
if ip -4 route show | grep -q "$SUBNET"; then
    bad "$SUBNET is already routed on this host - pick another lab subnet in compose.yaml, haproxy.cfg and keepalived-*.conf"
else
    ok "$SUBNET not used by host routes"
fi
if docker info >/dev/null 2>&1; then
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx 'mongo-ha-net'; then
        warn "network mongo-ha-net already exists (leftover from a previous run?)"
    else
        ok "network mongo-ha-net not created yet"
    fi
    for img in mongo:7.0; do
        if docker image inspect "$img" >/dev/null 2>&1; then
            ok "image present: $img"
        else
            warn "image missing: $img (will be pulled on first 'docker compose up --build', needs internet unless you load the air-gap bundle)"
        fi
    done
fi

echo
echo "-- host resources --"
mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ "$mem_total_kb" -ge 6000000 ]; then
    ok "RAM $((mem_total_kb / 1024)) MB"
else
    warn "RAM $((mem_total_kb / 1024)) MB - 6 GB+ recommended (3 mongod + proxies)"
fi
disk_free_mb=$(df -Pm "$LAB_DIR" | awk 'NR==2 {print $4}')
if [ "$disk_free_mb" -ge 6000 ]; then
    ok "free disk ${disk_free_mb} MB"
else
    warn "only ${disk_free_mb} MB free - images alone need ~2 GB"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "PREFLIGHT OK - next: docker compose up -d --build"
    exit 0
else
    echo "PREFLIGHT FAILED - fix the [FAIL] items above"
    exit 1
fi
