# HANDS_ON.md — Type it yourself, understand it, then deploy

This is the **typing workbook**. Its job is to make you **write every line of
the lab by hand** before you are allowed to run it. You will not copy-paste
finished files: you type them, you read what each line does, you break one
thing on purpose, you verify, and only then do you move on.

| | |
|---|---|
| Reference guide | `docs/MONGODB_HA_LAB_GUIDE.md` (concepts, decisions, troubleshooting) |
| Answer key / reference copy | `docs/lab/` (compare your typed files against it) |
| Air-gap tooling | `docs/offline/` |
| Lab directory you create | `~/mongodb-ha-lab` |

## Discipline — read once, then follow it

1. **No `docker compose up` until Phase 3 (self-check) is green.**
2. **One file per session.** Type it, verify it, understand it, only then
   open the next one.
3. **Type, do not paste.** Muscle memory + reading is the point. If you
   paste, you learn nothing.
4. **After every file, run its verification command.** If it fails, fix the
   file before moving on. Never "come back to it".
5. **Break it on purpose** in the marked experiments. Seeing the failure is
   how you learn what the line is for.
6. **Self-check before deploy:** `diff -ru docs/lab ~/mongodb-ha-lab` must
   print nothing. That proves you typed it right.
7. **Record results** in the worksheet (§W). In the server room, paper + pen.

You will write **14 files**. Total: roughly 700 lines. Plan ~2 hours.

---

## Phase 0 — One-time host preparation

```bash
id -un
cat /etc/os-release | head -3
uname -r
docker --version
docker compose version
```

Expected: your username, Debian 11/12/13, Docker 24+, Compose v2+.

### 0.1 Docker permission

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "docker DENIED"
```

If `docker DENIED`:

```bash
sudo usermod -aG docker "$(id -un)"
sg docker -c 'docker info >/dev/null && echo "docker OK now"'
```

If `sg docker` still fails, the daemon is down: `sudo systemctl start docker`.

### 0.2 Subnet free?

```bash
ip -4 route show | grep 172.30.77 || echo "lab subnet 172.30.77.0/24 is free"
```

If it is taken, change the subnet now — guide §3.8 (do this **before** typing
the files, because IPs are baked into the configs).

---

## Phase 1 — Empty tree (no code yet)

```bash
mkdir -p ~/mongodb-ha-lab/health ~/mongodb-ha-lab/proxy ~/mongodb-ha-lab/scripts
cd ~/mongodb-ha-lab
tree . 2>/dev/null || find . -type d
```

Expected: four directories, no files. **Do not copy anything from docs/lab yet.**
The point of this workbook is that you create the files yourself.

---

## Phase 2 — Type every file

Work through TS-01 … TS-14 in order. Each session: read the short intro,
type the heredoc, run the verification, read the line table, do the experiment.

---

### TS-01 — `health/requirements.txt` (2 lines)

**Why first:** the smallest file. It pins the only Python dependency so a
rebuild tomorrow gives the same result. `==` means "exactly this version";
`>=` would let a future release break the lab silently.

Type it:

```bash
cd ~/mongodb-ha-lab
cat > health/requirements.txt <<'EOF'
# Pinned so a rebuild (connected machine OR air-gapped wheelhouse) gives the
# same result. Upgrade deliberately, not by accident.
pymongo==4.10.1
EOF
```

**Verify:**

```bash
cat health/requirements.txt
pip download --dry-run -r health/requirements.txt 2>/dev/null && echo "name parses"
```

Expected: the two lines above.

**Experiment:** change `==` to `>=` and imagine a future PyMongo 5.0 that
renames `isWritablePrimary`. That is why we pin.

---

### TS-02 — `health/Dockerfile` (16 lines)

**Why:** one image, one job: run the checker as an unprivileged user. The
`USER 65534:65534` line is the security boundary — the checker binds port 9201
(>1024) and only talks to mongod, so it needs no privileges.

Type it:

```bash
cat > health/Dockerfile <<'EOF'
FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install -r /app/requirements.txt

COPY health.py /app/health.py

# The checker only binds a high port and talks to mongod - no privileges needed.
USER 65534:65534

EXPOSE 9201

CMD ["python", "-u", "/app/health.py"]
EOF
```

**Line by line**

| Lines | Meaning |
|---|---|
| 1 | Debian-based Python 3.12 image (bookworm, matches the proxy's Debian) |
| 3–6 | don't write `.pyc`, flush stdout, no pip cache, no version-check noise |
| 8 | work in `/app` |
| 10–11 | install deps **before** copying health.py, so a code change doesn't re-run pip |
| 13 | copy the checker |
| 16 | run as nobody (uid 65534) — privilege drop |
| 18–20 | document the port and the entrypoint |

**Verify:**

```bash
docker build -t mongodb-ha-lab-health:test ./health 2>&1 | tail -5
```

Expected: `Successfully tagged mongodb-ha-lab-health:test` (needs internet once;
on the air-gapped host this build is skipped — images are loaded instead).

**Experiment:** remove the `USER` line and rebuild. The container now runs as
root for no reason. That is the habit to avoid.

---

### TS-03 — `health/health.py` (122 lines, 4 chunks)

**Why:** the whole sidecar design lives here. A wrong checker (e.g. one that
follows replica-set discovery) would make HAProxy route writes to a secondary.
Type it in four chunks so you read each part.

**Chunk A — imports and config (lines 1–40):**

```bash
cat > health/health.py <<'EOF'
"""MongoDB primary health checker for the HA lab.

Exposes, on every health container:

    GET /primary   200 + "PRIMARY\n"       node is the writable primary of the set
                          503 + "NOT_PRIMARY"  node is secondary/recovering/unreachable
    GET /healthz   200 + "OK\n"           process liveness only

HAProxy polls GET /primary once a second and only routes MongoDB traffic to
servers whose checker answers 200. That is why TCP-27017 checks alone are not
enough: in a replica set, *every* member listens on 27017.

directConnection=True is essential: without it PyMongo would talk to whatever
node the replica set tells it to, so the checker would not test the node it was
asked to test.
"""

import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from pymongo import MongoClient

MONGO_HOST = os.getenv("MONGO_HOST", "mongo1")
MONGO_PORT = int(os.getenv("MONGO_PORT", "27017"))
REPLICA_SET = os.getenv("REPLICA_SET", "labrs")
LISTEN_PORT = int(os.getenv("LISTEN_PORT", "9201"))
TIMEOUT_MS = int(os.getenv("CHECK_TIMEOUT_MS", "1000"))

client = MongoClient(
    host=MONGO_HOST,
    port=MONGO_PORT,
    directConnection=True,
    serverSelectionTimeoutMS=TIMEOUT_MS,
    connectTimeoutMS=TIMEOUT_MS,
    socketTimeoutMS=TIMEOUT_MS,
    maxPoolSize=2,
    appname="lab-primary-health",
)
EOF
```

**Chunk A line table**

| Lines | Meaning |
|---|---|
| 18–20 | stdlib only + threading for the lock |
| 22 | PyMongo — the only third-party dependency |
| 25–29 | all behaviour comes from env vars; one image, three instances |
| 31–40 | `directConnection=True` + 1 s timeouts. This is the most important 10 lines in the file |

**Chunk B — state-transition logging (append):**

```bash
cat >> health/health.py <<'EOF'


# HAProxy polls every second: log state *transitions* only, not every probe.
_state_lock = threading.Lock()
_last_healthy = None


def log_state(healthy, detail):
    global _last_healthy
    with _state_lock:
        if healthy == _last_healthy:
            return
        _last_healthy = healthy
        print(
            "state change %s:%d -> %s (%s)"
            % (
                MONGO_HOST,
                MONGO_PORT,
                "PRIMARY" if healthy else "NOT_PRIMARY",
                detail,
            ),
            flush=True,
        )
EOF
```

**Chunk B line table**

| Lines | Meaning |
|---|---|
| 42–44 | shared state guarded by a lock (the server is threaded) |
| 47–62 | print only when the answer *changes* — otherwise docker logs drown |

**Chunk C — the HTTP handler (append):**

```bash
cat >> health/health.py <<'EOF'


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _respond(self, code, body):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/healthz":
            self._respond(200, "OK\n")
            return

        if self.path != "/primary":
            self._respond(404, "NOT_FOUND\n")
            return

        healthy = False
        detail = "unknown"
        try:
            hello = client.admin.command("hello")
            healthy = (
                hello.get("isWritablePrimary") is True
                and hello.get("setName") == REPLICA_SET
            )
            detail = "isWritablePrimary=%s secondary=%s setName=%s" % (
                hello.get("isWritablePrimary"),
                hello.get("secondary"),
                hello.get("setName"),
            )
        except Exception as exc:  # must never crash: report 503 and keep serving
            detail = "error=%s" % exc

        log_state(healthy, detail)
        self._respond(
            200 if healthy else 503,
            "PRIMARY\n" if healthy else "NOT_PRIMARY\n",
        )

    def log_message(self, fmt, *args):
        # Default access log would flood docker logs (1 request/second/server).
        return
EOF
```

**Chunk C line table**

| Lines | Meaning |
|---|---|
| 65 | HTTP/1.1 handler (needs Content-Length, which we set) |
| 68–76 | one helper to send a correct response (no partial reads by HAProxy) |
| 78–85 | `/healthz` liveness, everything else 404 |
| 87–107 | the actual test: `hello` must report writable primary AND the right set name |
| 100 | **never crash**: a dead mongod becomes a 503, not a dead checker |
| 109–111 | silence the per-request access log |

**Chunk D — start the server (append):**

```bash
cat >> health/health.py <<'EOF'


print(
    "health checker starting: mongo=%s:%d set=%s listen=%d timeout_ms=%d"
    % (MONGO_HOST, MONGO_PORT, REPLICA_SET, LISTEN_PORT, TIMEOUT_MS),
    flush=True,
)

server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
server.daemon_threads = True
server.serve_forever(poll_interval=0.5)
EOF
```

**Verify:**

```bash
python3 -m py_compile health/health.py && echo "python syntax OK" \
  || echo "(no python3 on this host - the container will compile it at build)"
```

**Experiment:** change `hello.get("isWritablePrimary") is True` to `== True`.
A secondary's `hello` returns `isWritablePrimary: false`, and `False == True` is
false, so it still works — but `is True` is the correct identity check and
also rejects a missing key. Always use `is True`/`is False` for booleans.

---

### TS-04 — `proxy/check-haproxy.sh` (21 lines)

**Why:** keepalived runs this every 2 s. Exit 0 = healthy, exit 1 = demote.
It checks only the proxy (process + listener), never MongoDB.

Type it:

```bash
cat > proxy/check-haproxy.sh <<'EOF'
#!/bin/sh
# Keepalived tracking script (vrrp_script chk_haproxy).
#
#   exit 0 = HAProxy is healthy
#   exit 1 = HAProxy is unhealthy  -> proxy's VRRP priority is demoted by 30
#
# It checks ONLY the proxy layer, not MongoDB. This is deliberate:
# during a MongoDB election there is no primary for a few seconds; the VIP
# must survive that window so applications get fast "no backend" errors
# instead of a VIP that flaps between two proxies every few seconds.

set -eu

# 1) the haproxy process must exist
pidof haproxy >/dev/null 2>&1 || exit 1

# 2) haproxy must actually listen on the MongoDB frontend port
#    (ss output: "0.0.0.0:27017" is followed by whitespace)
ss -lnt 2>/dev/null | grep -q ':27017 ' || exit 1

exit 0
EOF
chmod +x proxy/check-haproxy.sh
```

**Line table**

| Lines | Meaning |
|---|---|
| 12 | `set -eu`: fail fast; a failing command exits the script |
| 15 | `pidof` (from `procps`) checks the process exists |
| 19 | `ss` (from `iproute2`) checks the listener; the trailing space matches `:27017 ` not `:270170` |
| 21 | explicit success |

**Verify:**

```bash
sh -n proxy/check-haproxy.sh && echo "shell syntax OK"
```

**Experiment:** change `:27017 ` to `:27017` (no trailing space) and imagine a
listener on 270170. The trailing space is a real bug-prevention detail.

---

### TS-05 — `proxy/start.sh` (75 lines, 2 chunks)

**Why:** this is the container's PID 1 — it replaces systemd. It validates
configs, starts both daemons, waits for real readiness, and supervises them.

**Chunk A (lines 1–56):**

```bash
cat > proxy/start.sh <<'EOF'
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
EOF
```

**Chunk B (append — supervision):**

```bash
cat >> proxy/start.sh <<'EOF'

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
EOF
chmod +x proxy/start.sh
```

**Line table (key lines)**

| Lines | Meaning |
|---|---|
| 10 | `set -eu`: any failure stops the container (fail loud) |
| 14–21 | pick keepalived config from `PROXY_ID` (a or b) |
| 23–29 | validate both configs **before** starting anything |
| 32 | HAProxy in foreground (`-db`), backgrounded by the shell |
| 37–49 | wait up to 10 s for HAProxy to actually listen before announcing a VIP |
| 52 | keepalived in foreground with console logging (`-n -l`) |
| 57–67 | cleanup: on SIGTERM exit 0; on crash exit 1 → Docker restarts |
| 70–75 | supervise both PIDs; if either dies, tear down and restart |

**Verify:**

```bash
sh -n proxy/start.sh && echo "shell syntax OK"
```

**Experiment:** remove the `haproxy -c` line and introduce a typo in
`haproxy.cfg`. The container now starts, HAProxy fails to bind, keepalived
announces a VIP with nothing behind it. That is why validation comes first.

---

### TS-06 — `proxy/haproxy.cfg` (63 lines)

**Why:** the primary-aware router. The crucial trick is `check addr`/`port`
pointing at the sidecar while data goes to mongod.

Type it:

```bash
cat > proxy/haproxy.cfg <<'EOF'
# HAProxy for the MongoDB HA lab (Debian bookworm HAProxy 2.6).
#
# Two independent paths exist:
#   data path        client -> VIP:27017 -> HAProxy -> PRIMARY mongod:27017
#   health check path HAProxy -> healthN:9201/primary -> (PyMongo) -> mongodN:27017
#
# The check target is deliberately NOT the same address as the data target:
# mongod cannot answer "am I the primary?" over plain TCP, so a sidecar
# health checker answers an HTTP question about a specific mongod.

global
    log stdout format raw local0 info
    maxconn 5000

    # Run the proxy as the unprivileged user created by the haproxy package.
    user haproxy
    group haproxy

    # HAProxy statistics socket - inspect with:
    #   echo "show stat"     | socat - stdio UNIX-CONNECT:/var/run/haproxy.sock
    #   echo "show servers state 1" | socat - stdio UNIX-CONNECT:/var/run/haproxy.sock
    stats socket /var/run/haproxy.sock mode 660 level admin
    stats timeout 30s

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull

    timeout connect 3s
    timeout check 1s      # a health check must answer within 1s
    timeout client 1h     # long-lived mongosh / driver sessions
    timeout server 1h

frontend mongodb_frontend
    bind 0.0.0.0:27017
    default_backend mongodb_primary

backend mongodb_primary
    mode tcp

    # "first" = always pick the first server in the list that is UP.
    # Only the primary ever passes the HTTP check, so exactly one server
    # (the primary) is UP at any time. If mongo1 is down, the list moves
    # to mongo2, then mongo3.
    balance first

    # HTTP health check: ask the sidecar, expect 200 (only the primary).
    option httpchk
    http-check send meth GET uri /primary ver HTTP/1.1 hdr Host mongo-health
    http-check expect status 200

    # every 1s: DOWN after 2 failed probes, UP after 2 successful ones
    default-server inter 1s fall 2 rise 2

    server mongo1 172.30.77.11:27017 check addr 172.30.77.21 port 9201
    server mongo2 172.30.77.12:27017 check addr 172.30.77.22 port 9201
    server mongo3 172.30.77.13:27017 check addr 172.30.77.23 port 9201

    # NOTE: there is intentionally NO "backup" server and no fallback to a
    # secondary. With no primary, all three servers are DOWN and writes via
    # the VIP fail - which is correct behaviour for a write endpoint.
EOF
```

**Line table (non-obvious lines)**

| Lines | Meaning |
|---|---|
| 16–17 | drop privileges to the `haproxy` user created by the package |
| 22 | stats socket (mode 660, only root/haproxy can read) |
| 31–34 | connect 3 s, health check 1 s, client/server 1 h (long-lived driver sessions) |
| 47 | `balance first` — deterministic single-primary routing |
| 50–52 | HTTP check against the sidecar, expect 200 |
| 55 | 1 s probes, DOWN after 2, UP after 2 |
| 57–59 | **data** → mongod:27017, **check** → healthN:9201 |

**Verify:**

```bash
# needs haproxy binary; use the one from the proxy image later, or install locally
haproxy -c -f proxy/haproxy.cfg 2>&1 | tail -3
```

Expected (on a Debian host with haproxy installed): `Configuration file is valid`.

**Experiment:** change `balance first` to `balance roundrobin`. Rebuild and
watch HAProxy send writes to secondaries. That failure is why `first` matters.

---

### TS-07 — `proxy/keepalived-a.conf` (62 lines)

**Why:** VRRP instance with priority 120. The `weight -30` line is the most
misread setting in keepalived — read the table twice.

Type it:

```bash
cat > proxy/keepalived-a.conf <<'EOF'
# Keepalived for Proxy A (priority 120 -> preferred VIP owner).
#
# VRRP in one sentence: both proxies claim to be the same "router"; the one
# with the highest *effective* priority owns the VIP and sends gratuitous ARP
# so the Docker bridge learns where 172.30.77.100 lives.
#
# NOTE: both instances use "state BACKUP" on purpose. With state MASTER on
# both, each would assume it owns the VIP at boot and you would briefly have
# two VIPs. Starting from BACKUP everywhere forces a clean priority election.

global_defs {
    router_id LAB_PROXY_A
    enable_script_security   # refuse scripts writable by non-root
    script_user root
}

# Local health check: is HAProxy alive and listening?
#
# weight semantics (this is the single most misread Keepalived setting):
#   weight 0 (default)  -> script failure puts the instance in FAULT (VIP drops)
#   weight != 0         -> script failure only lowers the priority by |weight|
# Here -30 means: HAProxy dead -> effective priority 120-30 = 90 < 110, so
# proxy B wins the VIP. When HAProxy recovers -> 120 > 110 -> preemption.
vrrp_script chk_haproxy {
    script "/usr/local/bin/check-haproxy.sh"
    interval 2        # run every 2s
    timeout 2         # script must finish within 2s
    fall 2            # 2 consecutive failures = down
    rise 2            # 2 consecutive successes = up again
    weight -30        # demote priority, do NOT enter FAULT
    user root
}

vrrp_instance VI_MONGO {
    state BACKUP
    interface eth0            # Docker container interface name
    virtual_router_id 77      # MUST be identical on both proxies
    priority 120              # A(120) > B(110): A is the preferred owner
    advert_int 1              # VRRP advertisement every 1 second

    preempt_delay 5           # wait 5s after recovery before taking the VIP
                              # back (lets HAProxy finish its own startup)

    # Unicast VRRP: the Docker bridge does not reliably carry VRRP multicast.
    unicast_src_ip 172.30.77.31
    unicast_peer {
        172.30.77.32
    }

    virtual_ipaddress {
        172.30.77.100/24 dev eth0
    }

    # Be loud about the new owner on the bridge when the VIP moves.
    garp_master_delay 1
    garp_master_repeat 3
    garp_master_refresh 5

    track_script {
        chk_haproxy
    }
}
EOF
```

**Line table (non-obvious lines)**

| Lines | Meaning |
|---|---|
| 11–15 | `enable_script_security` + `script_user root` are mandatory whenever a `vrrp_script` runs |
| 20–21 | weight 0 = FAULT, weight != 0 = demote — the single most misread setting |
| 26 | 2 s interval, 2 s timeout, 2 fails = down, 2 successes = up |
| 35 | `state BACKUP` on *both* (forces a clean election instead of a boot-time double VIP) |
| 38 | `virtual_router_id 77` must match on both proxies |
| 41 | `preempt_delay 5`: wait before taking the VIP back on recovery |
| 45–48 | unicast peer (multicast is unreliable on the Docker bridge) |
| 55–57 | gratuitous ARP repeat/refresh on VIP move |

**Verify:**

```bash
# keepalived -t needs root + a root-owned script path; on a non-root host it
# prints "insecure". Inside the container (root) it will pass. Syntax is still
# checked by the proxy image build.
keepalived -t -f proxy/keepalived-a.conf 2>&1 | tail -3
```

Expected on a non-root host: a warning about insecure scripts, **not** a
syntax error. Inside the image (root) it prints `Configuration is valid`.

**Experiment:** change `weight -30` to `weight 0`. Rebuild and kill HAProxy.
The proxy enters FAULT and drops the VIP — observe the difference. Then
restore `-30`.

---

### TS-08 — `proxy/keepalived-b.conf` (47 lines)

**Why:** identical to A except router_id, priority, and the unicast pair. We
type it by copying A and changing only the 6 lines that must differ — this
teaches that "everything else must stay identical, otherwise the two nodes
will not agree on the VRRP instance."

Type it:

```bash
cp proxy/keepalived-a.conf proxy/keepalived-b.conf
# now edit the 6 lines that must differ:
sed -i 's/router_id LAB_PROXY_A/router_id LAB_PROXY_B/' proxy/keepalived-b.conf
sed -i 's/priority 120              # A(120) > B(110): A is the preferred owner/priority 110              # standby: only wins when A is demoted\/dead/' proxy/keepalived-b.conf
sed -i 's/unicast_src_ip 172.30.77.31/unicast_src_ip 172.30.77.32/' proxy/keepalived-b.conf
sed -i 's/        172.30.77.32/        172.30.77.31/' proxy/keepalived-b.conf
sed -i 's/# Keepalived for Proxy A (priority 120 -> preferred VIP owner)./# Keepalived for Proxy B (priority 110 -> standby VIP owner)./' proxy/keepalived-b.conf
# fix the comment block at the top
sed -i 's/^# Identical to keepalived-a.conf except: router_id, priority and the$/# Identical to keepalived-a.conf except: router_id, priority and the/' proxy/keepalived-b.conf
```

Then open it and confirm only these six lines differ from A:

```bash
diff proxy/keepalived-a.conf proxy/keepalived-b.conf
```

Expected diff (exactly these lines):

```diff
< # Keepalived for Proxy A (priority 120 -> preferred VIP owner).
---
> # Keepalived for Proxy B (priority 110 -> standby VIP owner).
<     router_id LAB_PROXY_A
---
>     router_id LAB_PROXY_B
<     priority 120              # A(120) > B(110): A is the preferred owner
---
>     priority 110              # standby: only wins when A is demoted/dead
<     unicast_src_ip 172.30.77.31
---
>     unicast_src_ip 172.30.77.32
<         172.30.77.32
---
>         172.30.77.31
```

**Why this matters:** a typo in `virtual_router_id` or `virtual_ipaddress` on
one side produces two VIPs (split brain). Diffing the two files is the
cheapest way to catch it.

---

### TS-09 — `proxy/Dockerfile` (41 lines)

**Why:** the proxy image is where the configs are validated at build time
(`haproxy -c`, `keepalived -t`). A broken config fails the build instead of
crashing a container at 2 a.m.

Type it:

```bash
cat > proxy/Dockerfile <<'EOF'
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# haproxy     - primary-aware TCP proxy
# keepalived  - VRRP daemon that owns the VIP
# iproute2    - ss/ip (used by check-haproxy.sh and by you during tests)
# procps      - pidof (used by check-haproxy.sh)
# socat       - talk to the HAProxy stats socket during tests
# curl/ca-certificates - manual probing of the health checkers
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        haproxy \
        keepalived \
        iproute2 \
        procps \
        socat \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/keepalived /run/haproxy

COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY keepalived-a.conf /etc/keepalived-a.conf
COPY keepalived-b.conf /etc/keepalived-b.conf
COPY check-haproxy.sh /usr/local/bin/check-haproxy.sh
COPY start.sh /usr/local/bin/start.sh

# Fail the image build immediately if either config file is broken.
RUN chmod 0644 /etc/haproxy/haproxy.cfg /etc/keepalived-a.conf /etc/keepalived-b.conf \
    && chmod 0755 /usr/local/bin/check-haproxy.sh /usr/local/bin/start.sh \
    && haproxy -c -f /etc/haproxy/haproxy.cfg \
    && cp /etc/keepalived-a.conf /etc/keepalived/keepalived.conf \
    && keepalived -t -f /etc/keepalived/keepalived.conf \
    && keepalived -t -f /etc/keepalived-b.conf

EXPOSE 27017

STOPSIGNAL SIGTERM

CMD ["/usr/local/bin/start.sh"]
EOF
```

**Line table (non-obvious lines)**

| Lines | Meaning |
|---|---|
| 11–21 | install all runtime tools; clean apt lists; create keepalived/haproxy dirs |
| 23–27 | copy configs into the image's standard paths |
| 30–35 | **build-time validation**: chmod, `haproxy -c`, `keepalived -t` ×2. If any fails, the image does not build |
| 37–41 | expose the data port, signal, entrypoint |

**Verify (needs internet):**

```bash
docker build -t mongodb-ha-lab-proxy:test ./proxy 2>&1 | tail -8
```

Expected: `Successfully tagged mongodb-ha-lab-proxy:test` and, in the log,
`Configuration file is valid`.

---

### TS-10 — `scripts/wait-for-primary.sh` (38 lines)

**Why:** a reusable poller. Used by `init-replica.sh` and by you during every
failover. It skips stopped/paused containers instead of crashing.

Type it:

```bash
cat > scripts/wait-for-primary.sh <<'EOF'
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
EOF
chmod +x scripts/wait-for-primary.sh
```

**Line table (non-obvious lines)**

| Lines | Meaning |
|---|---|
| 9 | `set -uo pipefail` (no `-e`: a failing probe must not abort the loop) |
| 11 | `cd` to the lab dir so it works from anywhere |
| 13 | optional timeout argument, default 90 s |
| 16 | record start time for the "after Ns" message |
| 18–31 | try every member; the first one reporting `true` wins |
| 20–22 | `grep -qx 'true'` matches an exact line `true` |
| 32–36 | timeout → print diagnostics and exit 1 |

**Verify:**

```bash
bash -n scripts/wait-for-primary.sh && echo "shell syntax OK"
```

---

### TS-11 — `scripts/init-replica.sh` (61 lines)

**Why:** runs once on a fresh lab. It waits for all three mongods, issues
`rs.initiate()`, and waits for an election. Idempotent (code 23 =
already initialised).

Type it:

```bash
cat > scripts/init-replica.sh <<'EOF'
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
EOF
chmod +x scripts/init-replica.sh
```

**Line table (non-obvious lines)**

| Lines | Meaning |
|---|---|
| 12 | array of the three service names |
| 15–33 | wait up to 120 s per node for `ping:1` to return `1` |
| 38–57 | `rs.initiate()` with priority 2 on mongo1 (preferred, not guaranteed) |
| 49–55 | catch code 23 = "AlreadyInitialized" → idempotent |
| 61 | `exec` replaces the shell with the waiter (exit code propagates) |

**Verify:**

```bash
bash -n scripts/init-replica.sh && echo "shell syntax OK"
```

---

### TS-12 — `scripts/status.sh` (98 lines)

**Why:** your eyes during every lab. Read-only; safe while anything is down.
Uses `http.client` (not `urllib`) because urllib raises on 503 and we want
to print the code.

Type it:

```bash
cat > scripts/status.sh <<'EOF'
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
EOF
chmod +x scripts/status.sh
```

**Line table (non-obvious lines)**

| Lines | Meaning |
|---|---|
| 9 | `set -uo pipefail` (no `-e`: partial failures must not abort the overview) |
| 43–50 | http.client prints the code instead of raising (urllib raises on 503) |
| 53–67 | loop both proxies; exactly one should print `HOLDS THE VIP` |
| 70–83 | parse HAProxy's stats CSV by header name (robust against column reordering) |
| 86–98 | a real write probe through the VIP at the end |

**Verify:**

```bash
bash -n scripts/status.sh && echo "shell syntax OK"
```

---

### TS-13 — `scripts/preflight.sh` (123 lines)

**Why:** the "am I ready to deploy?" check. Never changes anything. Run it
before every deployment and after every change.

Type it:

```bash
cat > scripts/preflight.sh <<'EOF'
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
EOF
chmod +x scripts/preflight.sh
```

**Verify:**

```bash
bash -n scripts/preflight.sh && echo "shell syntax OK"
```

---

### TS-14 — `compose.yaml` (187 lines, 2 chunks)

**Why:** the whole topology in one file. YAML anchors (`x-mongo-common`) keep
the three mongos identical; `ipv4_address` makes the IPs stable; `cap_add`
gives keepalived the kernel capabilities it needs.

**Chunk A (anchors + services mongo1/2/3 + health1/2/3):**

```bash
cat > compose.yaml <<'EOF'
# MongoDB + HAProxy + Keepalived lab on a single Docker host.
#
# Topology (all IPs are fake lab addresses on a private Docker bridge):
#   mongo1 172.30.77.11   mongo2 172.30.77.12   mongo3 172.30.77.13
#   health1 172.30.77.21  health2 172.30.77.22  health3 172.30.77.23
#   proxy1 172.30.77.31 (HAProxy+Keepalived)   proxy2 172.30.77.32 (HAProxy+Keepalived)
#   VIP 172.30.77.100     client 172.30.77.41
#
# Run:  docker compose up -d --build
# Stop: docker compose down        (keeps MongoDB data volumes)
# Wipe: docker compose down -v     (DELETES MongoDB data volumes)

name: mongodb-ha-lab

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

# Every mongod: replica set member, small cache so three nodes fit in 8 GB WSL.
x-mongo-common: &mongo-common
  image: mongo:7.0
  command:
    - mongod
    - --replSet
    - labrs
    - --bind_ip_all
    - --wiredTigerCacheSizeGB
    - "0.25"
  restart: unless-stopped
  init: true
  stop_grace_period: 30s
  logging: *default-logging
  networks:
    mongo-ha-net:

# Health checker: one HTTP endpoint per mongod that answers
# "is this node the writable primary?" (200 yes / 503 no).
x-health-common: &health-common
  image: mongodb-ha-lab-health:local
  build:
    context: ./health
  restart: unless-stopped
  init: true
  logging: *default-logging
  networks:
    mongo-ha-net:

# Proxy: HAProxy (primary-aware TCP load balancer) + Keepalived (VRRP VIP owner).
x-proxy-common: &proxy-common
  image: mongodb-ha-lab-proxy:local
  build:
    context: ./proxy
  restart: unless-stopped
  init: true
  stop_grace_period: 20s
  cap_add:
    - NET_ADMIN # assign/remove the VIP
    - NET_RAW   # send/receive VRRP packets
  logging: *default-logging
  networks:
    mongo-ha-net:

services:

  mongo1:
    <<: *mongo-common
    hostname: mongo1
    volumes:
      - mongo1_data:/data/db
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.11

  mongo2:
    <<: *mongo-common
    hostname: mongo2
    volumes:
      - mongo2_data:/data/db
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.12

  mongo3:
    <<: *mongo-common
    hostname: mongo3
    volumes:
      - mongo3_data:/data/db
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.13

  health1:
    <<: *health-common
    hostname: health1
    environment:
      MONGO_HOST: mongo1
      MONGO_PORT: "27017"
      REPLICA_SET: labrs
      LISTEN_PORT: "9201"
      CHECK_TIMEOUT_MS: "1000"
    depends_on:
      - mongo1
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.21

  health2:
    <<: *health-common
    hostname: health2
    environment:
      MONGO_HOST: mongo2
      MONGO_PORT: "27017"
      REPLICA_SET: labrs
      LISTEN_PORT: "9201"
      CHECK_TIMEOUT_MS: "1000"
    depends_on:
      - mongo2
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.22

  health3:
    <<: *health-common
    hostname: health3
    environment:
      MONGO_HOST: mongo3
      MONGO_PORT: "27017"
      REPLICA_SET: labrs
      LISTEN_PORT: "9201"
      CHECK_TIMEOUT_MS: "1000"
    depends_on:
      - mongo3
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.23
EOF
```

**Chunk B (append — proxies, client, network, volumes):**

```bash
cat >> compose.yaml <<'EOF'

  proxy1:
    <<: *proxy-common
    hostname: proxy1
    environment:
      PROXY_ID: a # selects /etc/keepalived-a.conf (priority 120)
    depends_on:
      - health1
      - health2
      - health3
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.31

  proxy2:
    <<: *proxy-common
    hostname: proxy2
    environment:
      PROXY_ID: b # selects /etc/keepalived-b.conf (priority 110)
    depends_on:
      - health1
      - health2
      - health3
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.32

  client:
    image: mongo:7.0
    command: ["sleep", "infinity"]
    hostname: client
    restart: unless-stopped
    init: true
    logging: *default-logging
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.41

networks:
  mongo-ha-net:
    name: mongo-ha-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.77.0/24

volumes:
  mongo1_data:
  mongo2_data:
  mongo3_data:
EOF
```

**Line table (non-obvious lines)**

| Lines | Meaning |
|---|---|
| 15–19 | `x-logging` anchor: 3 × 10 MB log cap per container |
| 22–36 | `x-mongo-common` anchor: image, replSet, bind, 0.25 GB cache, restart, init, grace, logging, network |
| 40–48 | `x-health-common`: image + build context + restart + init + logging + network |
| 51–63 | `x-proxy-common`: image + build + restart + init + grace + `cap_add` NET_ADMIN/NET_RAW + logging + network |
| 67–92 | three mongos: anchor + hostname + volume + static IP |
| 94–137 | three health checkers: anchor + hostname + env + depends_on + static IP |
| 139–163 | two proxies: anchor + hostname + PROXY_ID + depends_on + static IP |
| 165–174 | client: mongo image, sleep forever, static IP |
| 176–187 | bridge network with the IPAM subnet + named volumes |

**Verify:**

```bash
docker compose config --quiet && echo "compose.yaml parses"
```

Expected: `compose.yaml parses` (no output from `--quiet` means success).

---

## Phase 3 — Pre-deployment self-check (no containers started yet)

You have now written all 14 files. **Do not run `docker compose up` until every
check below is green.**

### 3.1 Tree check

```bash
cd ~/mongodb-ha-lab
find . -type f | sort
```

Expected: exactly the 14 files listed in TS-01…TS-14 (plus nothing else).

### 3.2 Syntax checks (fast, offline)

```bash
cd ~/mongodb-ha-lab
sh -n proxy/start.sh && sh -n proxy/check-haproxy.sh && echo "sh OK"
bash -n scripts/preflight.sh scripts/init-replica.sh \
      scripts/wait-for-primary.sh scripts/status.sh && echo "bash OK"
docker compose config --quiet && echo "compose OK"
```

Expected: three `OK` lines.

### 3.3 Compare against the reference copy (the real self-test)

```bash
diff -ru ~/K8sLearning/Dev/MongoDB_Cluster/docs/lab ~/mongodb-ha-lab
echo "diff exit code: $?"
```

Expected: **no output** and exit code `0`. If diff shows anything, you have a
typo — fix it now, while you still have the reference open. In the server room
you will not have this safety net; that is why we do it here.

### 3.4 Executable bits

```bash
chmod +x scripts/*.sh proxy/*.sh
ls -l scripts/*.sh proxy/*.sh | grep -v '^-rwx' && echo "MISSING EXEC BIT" || echo "all executable"
```

### 3.5 Preflight

```bash
bash scripts/preflight.sh
```

Expected: `PREFLIGHT OK - next: docker compose up -d --build`.

**Only now are you cleared to deploy.**

---

## Phase 4 — Deploy (first time)

```bash
cd ~/mongodb-ha-lab
docker compose up -d --build        # pulls ~1 GB the first time
docker compose ps                   # 9 rows, all "running"
bash scripts/init-replica.sh        # initiates labrs, waits for PRIMARY
bash scripts/status.sh              # 1 PRIMARY + 2 SECONDARY, VIP on one proxy,
                                    # health 200/503/503, write OK
```

Air-gapped host (images already loaded, no internet):

```bash
docker compose up -d --no-build     # NEVER --build without internet
```

Baseline acceptance (must all pass before the failover labs):

| ID | Check |
|---|---|
| AC01 | 9 containers running |
| AC02 | replica set initiated (`rs.status().ok == 1`) |
| AC03 | exactly 1 PRIMARY + 2 SECONDARY |
| AC04 | only the primary's checker returns 200 |
| AC05 | exactly one proxy holds the VIP |
| AC06 | write + read through the VIP works |

---

## Phase 5 — Failover labs

(Commands unchanged from the reference workbook — see `../HANDS_ON.md` Phase 5
for the exact sequence with expected output. The labs are: LAB01 baseline,
LAB02 primary failover, LAB03 planned stepdown, LAB04 VIP failover,
LAB05 HAProxy death, LAB06 quorum loss, LAB07 unresponsive node,
LAB08 write concern, LAB09 connection behaviour, LAB10 persistence/reset.)

Run them in order. **Record observations in the worksheet (§W).**

---

## Phase 6 — Air-gap bundle (create on the connected machine)

```bash
cd ~/K8sLearning/Dev/MongoDB_Cluster
bash docs/offline/build-bundle.sh
sha256sum -c mongodb-ha-lab-bundle.tar.gz.sha256
```

On the air-gapped host:

```bash
sha256sum -c mongodb-ha-lab-bundle.tar.gz.sha256
tar -xzf mongodb-ha-lab-bundle.tar.gz
cd mongodb-ha-lab-bundle
bash docs/offline/verify-bundle.sh
bash docs/offline/load-images.sh
cp -a docs/lab ~/mongodb-ha-lab
cd ~/mongodb-ha-lab
# repeat Phase 2..4 (type the files, self-check, deploy)
```

Note: the bundle ships the **finished** files. In the server room you type them
yourself from this workbook; the bundle is your fallback if a file is lost.

---

## Phase 7 — Diagnostics (keep nearby)

```bash
docker compose ps
bash scripts/status.sh
docker compose logs -f --tail 50 proxy1 proxy2
docker compose exec proxy1 sh -c 'echo "show stat" | socat - stdio UNIX-CONNECT:/var/run/haproxy.sock' | cut -d, -f1,2,18
docker compose exec client bash -c 'timeout 3 bash -c "</dev/tcp/172.30.77.100/27017" && echo VIP open'
```

---

## §W Worksheet

| Step | Question | Your answer |
|---|---|---|
| AC01 | 9 containers running? | |
| AC02 | replica set initiated? | |
| AC03 | which node is PRIMARY at baseline? | |
| AC04 | health 200/503/503 pattern? | |
| AC05 | which proxy holds the VIP at baseline? | |
| LAB02 | how long until a new PRIMARY? | |
| LAB02 | did the VIP move? (must be NO) | |
| LAB04 | how long until the VIP moved to proxy2? | |
| LAB04 | did the MongoDB primary change during VIP failover? (must be NO) | |
| LAB06 | error message of the refused write? | |
| LAB08 | unsafe/safe document counts after rejoin? | |
| LAB10 | data count survived `down`/`up`? | |
| overall | hardest step to debug, and why | |

---

## Stopping for the day

```bash
docker compose stop     # keep everything, including data
docker compose start    # resume later
docker compose down     # remove containers/network, keep data
docker compose down -v  # DELETES DATA - full reset
```
