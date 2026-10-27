#!/bin/sh
# Container entrypoint: run HAProxy + Keepalived as supervised foreground
# processes. This replaces systemd, which the lab cannot test inside Docker.
#
# Lifecycle contract:
#   - SIGTERM/SIGINT (docker compose stop) -> graceful stop, exit 0
#   - either daemon dies                   -> exit 1 so docker restarts the
#                                             container (restart: unless-stopped)

set -eu

log() { printf '[start.sh] %s\n' "$*"; }

case "${PROXY_ID:-}" in
    a) KEEPALIVED_CONF=/etc/keepalived-a.conf ;;
    b) KEEPALIVED_CONF=/etc/keepalived-b.conf ;;
    *)
        log "FATAL: PROXY_ID must be 'a' or 'b', got '${PROXY_ID:-}'"
        exit 64
        ;;
esac

cp "$KEEPALIVED_CONF" /etc/keepalived/keepalived.conf

log "validating haproxy.cfg"
haproxy -c -f /etc/haproxy/haproxy.cfg

log "validating keepalived.conf ($KEEPALIVED_CONF)"
keepalived -t -f /etc/keepalived/keepalived.conf

# --- haproxy (foreground in background shell) -----------------------------
haproxy -db -f /etc/haproxy/haproxy.cfg &
HAPROXY_PID=$!

# Do not start keepalived before haproxy really listens, otherwise the VIP
# could be announced while nothing answers on 27017.
i=0
while [ "$i" -lt 50 ]; do
    if ss -lnt 2>/dev/null | grep -q ':27017 '; then
        break
    fi
    i=$((i + 1))
    sleep 0.2
done
if ! ss -lnt 2>/dev/null | grep -q ':27017 '; then
    log "FATAL: haproxy did not start listening on 27017"
    kill "$HAPROXY_PID" 2>/dev/null || true
    exit 1
fi

# --- keepalived (foreground, console logging -> docker logs) ---------------
keepalived -n -l -f /etc/keepalived/keepalived.conf &
KEEPALIVED_PID=$!

log "haproxy pid=$HAPROXY_PID keepalived pid=$KEEPALIVED_PID proxy_id=${PROXY_ID}"

terminating=0
cleanup() {
    trap - INT TERM
    kill "$KEEPALIVED_PID" "$HAPROXY_PID" 2>/dev/null || true
    wait "$KEEPALIVED_PID" 2>/dev/null || true
    wait "$HAPROXY_PID" 2>/dev/null || true
    if [ "$terminating" -eq 1 ]; then
        exit 0
    fi
    exit 1
}
trap 'terminating=1; cleanup' INT TERM

while kill -0 "$HAPROXY_PID" 2>/dev/null && kill -0 "$KEEPALIVED_PID" 2>/dev/null; do
    sleep 1
done

log "a child process died - exiting so docker restarts the container"
cleanup
