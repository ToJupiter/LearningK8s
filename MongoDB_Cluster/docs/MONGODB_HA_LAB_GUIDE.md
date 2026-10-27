# MongoDB + HAProxy + Keepalived HA Lab on Debian (Docker)

**Deployment and learning guide — complete, offline-friendly, self-contained.**

| | |
|---|---|
| Source material | `MongoDB_Debian.md` (Vietnamese lab plan, kept next to this file) |
| Lab files | `docs/lab/` (copy this directory to run the lab) |
| Command workbook | `../HANDS_ON.md` — every command to type, in order |
| Air-gap tooling | `docs/offline/` |
| Authoring environment | Debian 13 (trixie) on WSL2, Docker 29.7.2, Compose v5.5.0 |

## Verification status — read this first

This guide was produced **without executing the full Docker lab** (the authoring
machine's user had no Docker daemon permission). What *was* executed and passed:

| Component | Verified how | Result |
|---|---|---|
| `compose.yaml` | `docker compose config --quiet` (Compose v5.5.0) | parses, static IPs/network valid |
| all shell scripts | `bash -n` / `sh -n` | syntax OK |
| `proxy/haproxy.cfg` | `haproxy -c` on real Debian **bookworm HAProxy 2.6.12** | `Configuration file is valid` |
| `keepalived-a/b.conf` | `keepalived -t` on real Debian **bookworm keepalived 2.2.7** | all directives parse; the only check not reproducible here is `enable_script_security`'s root-ownership rule for the tracked script (it always reports "insecure" for a non-root user, whatever the path). Inside the image the script is root-owned `0755`, so `keepalived -t` in `start.sh` will validate it for real at container start |
| `health/health.py` | executed with a stub PyMongo driver | `200 PRIMARY`, `503 NOT_PRIMARY`, `404`, survives mongod down, wrong `setName`, logs state transitions only |
| HAProxy behaviour | real HAProxy 2.6 + real `health.py` + stub mongods, ports remapped | `check addr` works, `balance first` works, fall/rise timing works, **no fallback to secondaries**, stats socket fields used by `status.sh` confirmed |
| `check-haproxy.sh` | executed against a live HAProxy | exits 0 when listening, 1 when dead |
| MongoDB election, VRRP VIP move, WSL/Docker ARP | **NOT executed** | follow `../HANDS_ON.md` on a Docker-capable host |

Everything marked "expected" below is either taken from those live runs or from
official documentation. When you run the workbook, compare your output with the
expected output and treat any mismatch as a finding.

---

# 1. What you are building

## 1.1 Topology

```text
                      one Debian host (WSL2 / bare metal)
                                 |
                             Docker Engine
                                 |
             Docker bridge network mongo-ha-net  172.30.77.0/24
                                 |
                          client 172.30.77.41
                                 |
                                 v
                       VIP 172.30.77.100 :27017      <--- the only endpoint
                                 |                        the application uses
                 +---------------+---------------+
                 |                               |
            proxy1 172.30.77.31             proxy2 172.30.77.32
            HAProxy + Keepalived            HAProxy + Keepalived
            VRRP priority 120               VRRP priority 110
                 |                               |
                 +---------------+---------------+
                                 |
            primary-aware routing (HTTP check via sidecars)
                                 |
          +----------------------+----------------------+
          |                      |                      |
     mongo1 .11:27017       mongo2 .12:27017       mongo3 .13:27017
     priority 2             priority 1             priority 1
          |                      |                      |
          +----------------------+----------------------+
                                 |
                        replica set  labrs
          health1 .21:9201   health2 .22:9201   health3 .23:9201
```

Nine containers: 3 MongoDB + 3 health checkers + 2 proxies + 1 client.

## 1.2 Address plan

| Component | Lab IP | Port(s) | Role |
|---|---|---|---|
| mongo1/2/3 | 172.30.77.11/.12/.13 | 27017 | replica set `labrs` members |
| health1/2/3 | 172.30.77.21/.22/.23 | 9201 | "is that mongod the primary?" HTTP checker |
| proxy1/proxy2 | 172.30.77.31/.32 | 27017 | HAProxy + Keepalived |
| VIP | 172.30.77.100 | 27017 | application endpoint (owned by one proxy) |
| client | 172.30.77.41 | — | simulates the application |

All addresses are private Docker-bridge addresses. They never touch your real
LAN, VPN, or company network. If `172.30.77.0/24` collides with something on
your host, change it (see §3.8).

## 1.3 The core lesson: three independent control loops

Most HA outages come from confusing these three loops. The lab separates them
so you can watch each one move **on its own**:

```text
Loop 1 - MongoDB election
  mongod heartbeats -> no primary -> secondaries elect a new primary
  changes: which mongod is primary
  does NOT change: where the VIP is

Loop 2 - HAProxy backend selection
  HTTP check /primary -> 200 only on the primary -> HAProxy marks others DOWN
  changes: which mongod receives NEW TCP connections
  does NOT change: which proxy holds the VIP, and existing TCP sessions

Loop 3 - Keepalived VRRP
  VRRP advertisements + local HAProxy check -> one proxy owns the VIP
  changes: which proxy answers ARP for 172.30.77.100
  does NOT change: which mongod is primary
```

The application only sees: `VIP:27017`. It must tolerate the fact that the
server behind it changes for reasons it cannot observe.

## 1.4 What this lab proves — and what it does not

**Proves:** MongoDB election and replication; MongoDB-aware HTTP health check;
HAProxy backend switching; VRRP VIP migration and preemption; quorum loss;
client reconnect behaviour; rollback risk with `w:1`.

**Does not prove:** real hardware failure; systemd behaviour; network partition
between physically separate machines; split-brain fencing; performance/SLA;
authentication/TLS (not enabled here); anything about power loss (killing one
container is not losing a rack).

---

# 2. Prerequisites

## 2.1 Host sizing

| Resource | Minimum | Comfortable |
|---|---|---|
| CPU | 3 vCPU | 4+ vCPU |
| RAM | 6 GB free for Docker | 8 GB |
| Disk | 5 GB free | 10 GB (image + volumes + logs) |
| OS | Debian 11/12/13, x86_64 | Debian 12/13 |
| Docker | Engine 24+ with Compose v2 plugin | Engine 27+ |

The lab pins mongod's WiredTiger cache to 0.25 GB per node
(`--wiredTigerCacheSizeGB 0.25`) so three nodes fit in an 8 GB WSL2 VM.

## 2.2 One-time Docker access setup

The Docker socket is owned by `root:docker`. If your user is not in the
`docker` group, every command in this guide fails with
`permission denied while trying to connect to the docker API`.

```bash
# run as yourself, sudo will ask for YOUR password
sudo usermod -aG docker "$(id -un)"
```

Then, **without logging out**, make the new group effective for new shells:

```bash
sg docker -c 'docker info >/dev/null && echo DOCKER OK'
```

New terminal sessions (or `wsl --terminate Debian` from Windows) pick the group
up automatically. Verify:

```bash
docker version          # both Client and Server sections must be present
docker compose version
docker info             # must NOT print "permission denied"
```

`docker version` printing only the Client section means the daemon was not
reachable (wrong group, or the daemon is not running).

## 2.3 Internet requirement — and the air-gap split

The **first build** needs internet to pull three images:

| Image | Used by | Approx. size |
|---|---|---|
| `mongo:7.0` | mongo1/2/3 + client | ~800 MB |
| `python:3.12-slim-bookworm` | health checker build | ~130 MB |
| `debian:bookworm-slim` | proxy build | ~75 MB |

The proxy image additionally runs `apt-get install haproxy keepalived ...`
at build time (needs internet once).

For an air-gapped target you therefore **build once, save, transfer, load**
(§4). Never rely on `docker compose build` or `docker pull` on the target.

## 2.4 Subnet preflight

```bash
ip -4 route show | grep 172.30.77 || echo "lab subnet is free"
docker network ls | grep mongo-ha-net || echo "no leftover lab network"
```

If the route exists (VPN, another Docker network, a physical LAN), pick another
subnet — §3.8 shows the one-command change.

---

# 3. Write it yourself, then deploy

> **Discipline.** Do not run `docker compose up` until you have typed every file
> in §3.2–§3.15 and passed §3.16 (self-check). The whole point of this lab
> is that you understand every line before anything runs — in a server room
> with no internet and no SSH, that is the only thing standing between you
> and a 2 a.m. outage.

## 3.0 How to use this section

1. Create an empty `~/mongodb-ha-lab` with the four directories (Phase 1 of
   `../HANDS_ON.md`).
2. Work through TS-01 … TS-14 in `../HANDS_ON.md`. Each session gives you
   the exact heredoc to type, a line-by-line table, a verification command
   with its expected output, and a "break it on purpose" experiment.
3. After each file, run its verification command. A failure means a typo —
   fix it before opening the next file.
4. §3.16 (self-check) is the gate: `diff -ru docs/lab ~/mongodb-ha-lab`
   must print nothing.
5. Only then go to §5 (deploy).

## 3.1 Layout

```text
docs/lab/
├── compose.yaml               # 9 services, bridge network, named volumes
├── health/
│   ├── Dockerfile             # python:3.12-slim-bookworm + pymongo
│   ├── requirements.txt       # pinned pymongo==4.10.1
│   └── health.py              # GET /primary -> 200 iff writable primary
├── proxy/
│   ├── Dockerfile             # debian:bookworm-slim + haproxy + keepalived
│   ├── haproxy.cfg            # TCP frontend, primary-aware backend
│   ├── keepalived-a.conf      # proxy1, priority 120
│   ├── keepalived-b.conf      # proxy2, priority 110
│   ├── check-haproxy.sh       # tracking script for keepalived
│   └── start.sh               # PID 1: validate, launch, supervise both daemons
└── scripts/
    ├── preflight.sh           # host + file + subnet checks
    ├── init-replica.sh        # rs.initiate() once, wait for primary
    ├── wait-for-primary.sh    # poll until one member is writable primary
    └── status.sh              # everything at a glance (read-only)
```

## 3.2 `compose.yaml` — the important decisions

| Decision | Where | Why |
|---|---|---|
| Fixed `ipv4_address` per service | `networks.mongo-ha-net` | keepalived and haproxy configs contain literal IPs; DNS would hide moves but the configs need stability |
| `--wiredTigerCacheSizeGB 0.25` | mongo command | three mongods must fit in 8 GB WSL2 |
| `cap_add: NET_ADMIN, NET_RAW` | proxies | keepalived assigns/removes the VIP (NET_ADMIN) and exchanges VRRP frames (NET_RAW). Without them: `Netlink: Operation not permitted` and no VIP |
| `init: true` | all services | tini as PID 1 reaps zombies and forwards signals to `start.sh` |
| `stop_grace_period: 20s/30s` | proxies / mongos | keepalived must be able to remove the VIP; mongod must flush and lock its data files |
| `restart: unless-stopped` | all services | a crashed HAProxy or mongod comes back by itself (mirrors systemd `Restart=always` in production) |
| `image:` + `build:` | health, proxy | gives the images stable names (`mongodb-ha-lab-*:local`) so `docker save`/`docker load` work offline |
| named volumes `mongo*_data` | mongos | data survives `docker compose down`; only `down -v` wipes it |
| log rotation options | `x-logging` | failover tests produce lots of logs; 3 × 10 MB max per container |

`docker compose down` removes containers and the network but **keeps the data
volumes**. `docker compose down -v` deletes the data too.

## 3.3 The health checker — why it exists

A plain TCP check on 27017 is useless here: in a replica set **every** member
listens on 27017, primary or not. HAProxy 2.6 has no native MongoDB
"isPrimary" check, so each mongod gets a tiny sidecar:

```text
HAProxy --HTTP GET /primary--> healthN:9201 --PyMongo hello--> mongodN:27017
                                   |
                    200 PRIMARY   if  isWritablePrimary == true
                                  and setName == "labrs"
                    503 NOT_PRIMARY otherwise (secondary, STARTUP2,
                                  RECOVERING, no primary, unreachable)
```

Three properties matter and are all covered by live tests:

1. **`directConnection=True`** — without it PyMongo would follow replica-set
   discovery and the checker might query a *different* node than the one it is
   supposed to test. With it, the checker tests exactly `MONGO_HOST`.
2. **1 s timeouts everywhere** (`serverSelectionTimeoutMS`,
   `connectTimeoutMS`, `socketTimeoutMS`) — a dead node must be reported as 503
   quickly, not hang for 30 s.
3. **State-transition logging only** — HAProxy polls once per second per
   server; per-probe logging would drown `docker compose logs`.

Observed live (stub mongod):

```text
:19201 -> 200 PRIMARY          :19202 -> 503 NOT_PRIMARY
:19201/healthz -> 200          :19201/other -> 404
state change stub1:27017 -> NOT_PRIMARY (error=connection refused (stub))
state change stub1:27017 -> NOT_PRIMARY (isWritablePrimary=True secondary=False setName=wrongset)
```

The container runs as `USER 65534:65534` (nobody): it only binds 9201 and talks
to mongod, so it needs no privileges.

## 3.4 `haproxy.cfg` — the important decisions

| Directive | Meaning |
|---|---|
| `mode tcp` everywhere | MongoDB is not HTTP; HAProxy must be a dumb TCP pipe |
| `frontend bind 0.0.0.0:27017` | the proxy answers on every local address; the VIP just moves *to* it |
| `balance first` | always the first server in list order that is UP. Only the primary is UP, so order is effectively "primary first, then whichever node became primary" |
| `option httpchk` + `http-check send meth GET uri /primary` | poll the sidecar instead of the data port |
| `http-check expect status 200` | only 200 counts as UP (503 = DOWN) |
| `default-server inter 1s fall 2 rise 2` | ~2 s to declare DOWN, ~2 s to declare UP again |
| `timeout check 1s` | a health check must answer within 1 s |
| `server mongoN 172.30.77.1N:27017 check addr 172.30.77.2N port 9201` | **data** goes to mongod:27017, the **check** goes to healthN:9201. The `check addr`/`port` pair is what makes the sidecar design possible |
| no `backup` server, no fallback | with no primary all servers are DOWN and connections are refused — correct for a write endpoint |
| `stats socket /var/run/haproxy.sock` | inspect live states during labs |

Verified live with real HAProxy 2.6.12: only the "primary" server is UP; when
the checker flips to secondary, HAProxy switches traffic to the next UP server
within fall/rise (~3–5 s); when every checker dies, HAProxy refuses connections
instead of routing writes to a secondary.

## 3.5 `keepalived-a.conf` / `keepalived-b.conf` — the important decisions

| Directive | Meaning |
|---|---|
| `state BACKUP` on **both** | if both said MASTER, both would claim the VIP at boot (two VIPs = split brain). BACKUP + priority forces one clean election |
| `virtual_router_id 77` | must match on both proxies; different VRRP routers = independent elections = two VIPs |
| `priority 120` vs `110` | proxy1 is the *preferred* owner when both are healthy. Unrelated to which mongod is primary |
| `advert_int 1` | master-down detection ≈ 3× advert = ~3 s |
| `unicast_src_ip` / `unicast_peer` | unicast VRRP; the Docker bridge does not carry VRRP multicast reliably |
| `preempt_delay 5` | when proxy1 recovers, wait 5 s before taking the VIP back — gives HAProxy time to listen and be checked |
| `garp_master_*` | repeat gratuitous ARP so the bridge re-learns the VIP location quickly after a move |
| `virtual_ipaddress { 172.30.77.100/24 dev eth0 }` | the VIP itself |
| `track_script { chk_haproxy }` + `weight -30` | see below |

**`weight` semantics — the single most misread keepalived setting:**

| Configuration | Script fails → behaviour |
|---|---|
| `weight 0` (the default) | instance enters **FAULT**: VIP is removed, no matter what the peer's priority is |
| `weight -30` (used here) | priority is demoted: 120→90 (A) or 110→80 (B); the healthy peer wins. Instance keeps running |

With `-30`: if proxy1's HAProxy dies, 90 < 110 → proxy2 takes the VIP while
proxy1's keepalived stays alive. If *both* HAProxy processes die, both are
demoted and **nobody** holds the VIP — which is exactly right, because a VIP
pointing at a dead load balancer is worse than no VIP.

> Lab caveat: in this lab both daemons live in one container supervised by
> `start.sh`. Killing HAProxy therefore tears down the whole container, and the
> VIP moves because the peer disappeared, not because of the demotion. The
> *end state* is identical; the *mechanism* differs from production, where
> systemd supervises each daemon separately and the weight-based demotion
> keeps the standby proxy's keepalived alive. Treat `weight` as production
> behaviour you must reason about, and the container restart as a lab shortcut.

## 3.6 `start.sh` and `check-haproxy.sh`

`start.sh` is the container's PID 1 (production uses systemd):

1. select keepalived config from `PROXY_ID` (a|b),
2. `haproxy -c` and `keepalived -t` — **refuse to start on a broken config**,
3. start HAProxy and wait until 27017 is actually listening (do not announce
   a VIP with nothing behind it),
4. start keepalived in the foreground with console logging,
5. supervise both: clean stop on SIGTERM (exit 0), crash → exit 1 so Docker
   restarts the container.

`check-haproxy.sh` (keepalived tracking script) checks only the *proxy* layer:

```sh
pidof haproxy ... || exit 1
ss -lnt | grep -q ':27017 ' || exit 1
exit 0
```

Deliberately NOT checking whether a MongoDB primary exists: during an election
(10–30 s) the VIP must stay put so applications get a fast "no backend" instead
of a VIP that flaps between two proxies every few seconds.

## 3.7 The helper scripts

| Script | Purpose |
|---|---|
| `preflight.sh` | files, permissions, docker, compose parse, subnet clash, RAM/disk. Never changes anything |
| `init-replica.sh` | wait for all three mongods, `rs.initiate()` with mongo1 priority 2, wait for a primary. Idempotent (code 23 = already initialised) |
| `wait-for-primary.sh [seconds]` | poll all three members until one reports `isWritablePrimary=true` |
| `status.sh` | containers + `rs.status()` summary + checker HTTP codes + VIP owner + HAProxy `show stat` + a write probe through the VIP |

`status.sh` HAProxy section uses the stats socket CSV; the column names
(`svname`, `status`, `chkfail`, `chkdown`, `lastchg`) were confirmed present in
real HAProxy 2.6 output.

## 3.8 Changing the lab subnet

Every lab IP appears in exactly these files:

```bash
cd ~/mongodb-ha-lab
NEW=172.31.99
sed -i "s/172\.30\.77\.0\/24/${NEW}.0\/24/" compose.yaml
sed -i "s/172\.30\.77\.100/${NEW}.100/g"     compose.yaml proxy/haproxy.cfg \
                                             proxy/keepalived-a.conf proxy/keepalived-b.conf \
                                             scripts/status.sh
sed -i "s/172\.30\.77\.11/${NEW}.11/g; s/172\.30\.77\.12/${NEW}.12/g; s/172\.30\.77\.13/${NEW}.13/g" \
     compose.yaml proxy/haproxy.cfg
sed -i "s/172\.30\.77\.21/${NEW}.21/g; s/172\.30\.77\.22/${NEW}.22/g; s/172\.30\.77\.23/${NEW}.23/g" \
     compose.yaml proxy/haproxy.cfg
sed -i "s/172\.30\.77\.31/${NEW}.31/g; s/172\.30\.77\.32/${NEW}.32/g" \
     compose.yaml proxy/keepalived-a.conf proxy/keepalived-b.conf
grep -rn '172\.30\.77' . || echo "all lab IPs migrated"
```

---

## 3.16 Pre-deployment self-check (the gate)

You have typed all 14 files. None of them has been run yet. Verify before
deploying:

```bash
cd ~/mongodb-ha-lab
sh -n proxy/start.sh && sh -n proxy/check-haproxy.sh && echo "sh OK"
bash -n scripts/preflight.sh scripts/init-replica.sh \
      scripts/wait-for-primary.sh scripts/status.sh && echo "bash OK"
docker compose config --quiet && echo "compose OK"
chmod +x scripts/*.sh proxy/*.sh
# the real self-test: your typed copy must be byte-identical to the reference
diff -ru /home/haiph/K8sLearning/MongoDB_Cluster/docs/lab ~/mongodb-ha-lab
echo "diff exit code: $?"   # must be 0
bash scripts/preflight.sh   # must end with PREFLIGHT OK
```

Expected: four `OK` lines, an empty diff, exit code 0, and `PREFLIGHT OK`.

If the diff is non-empty, you have a typo. Fix it now — in the server room
you will not have the reference copy to diff against. That is the whole reason
this self-check exists.

---

# 4. Air-gapped operation

## 4.1 Principle

```text
INTERNET-CONNECTED host                    AIR-GAPPED host
--------------------                       ------------------
docker compose build  ──┐                  docker load -i images/*.tar
docker pull mongo:7.0 ──┤   USB / scp      docker compose up -d --no-build
docker save  ───────────┼────────────────> sha256sum -c SHA256SUMS
tar bundle  ────────────┘                  (no build, no pull, ever)
```

The target host **never** needs internet, a package repository, PyPI, or a
Docker registry. Everything it runs is in the bundle.

## 4.2 Build the bundle (connected host)

```bash
cd /path/to/MongoDB_Cluster
bash docs/offline/build-bundle.sh
```

What it does, in order: builds `mongodb-ha-lab-health:local` and
`mongodb-ha-lab-proxy:local` (this is where `apt-get`/`pip` run, while online),
pulls `mongo:7.0`, saves all three images with `docker save`, copies the lab,
docs and workbook, writes `SHA256SUMS`, and produces
`mongodb-ha-lab-bundle.tar.gz` + its own `.sha256`.

Useful variants:

```bash
PLATFORM=linux/arm64 bash docs/offline/build-bundle.sh   # ARM target
WITH_BASES=1       bash docs/offline/build-bundle.sh     # also save python:3.12-slim-bookworm
                                                             # and debian:bookworm-slim so the
                                                             # images can be REBUILT offline
bash docs/offline/build-bundle.sh /media/usb/mongo-lab   # build straight onto a USB stick
```

## 4.3 Transfer + verify (air-gapped host)

```bash
# copy mongodb-ha-lab-bundle.tar.gz and .tar.gz.sha256 over
sha256sum -c mongodb-ha-lab-bundle.tar.gz.sha256   # verify the archive itself
tar -xzf mongodb-ha-lab-bundle.tar.gz
cd mongodb-ha-lab-bundle
bash docs/offline/verify-bundle.sh                  # verifies every file inside
```

`verify-bundle.sh` runs `sha256sum -c SHA256SUMS` over all extracted files —
this is your protection against a corrupted USB copy or a truncated transfer.

## 4.4 Deploy (air-gapped host)

```bash
bash docs/offline/load-images.sh
cd docs/lab
bash scripts/preflight.sh
docker compose up -d --no-build
bash scripts/init-replica.sh
bash scripts/status.sh
```

`--no-build` is mandatory: without it compose may try to build the images and
the `RUN pip install` / `RUN apt-get install` steps would need internet. If
your compose version supports it, belt-and-braces:

```bash
docker compose up -d --no-build --pull never
```

## 4.5 Air-gap checklist

- [ ] bundle `.tar.gz` **and** its `.sha256` transferred
- [ ] `sha256sum -c` passes for the archive and for the contents
- [ ] `docker load` reported 3 images (`mongo:7.0`, `mongodb-ha-lab-health:local`,
      `mongodb-ha-lab-proxy:local`)
- [ ] target architecture matches (`docker image inspect mongo:7.0 --format '{{.Os}}/{{.Arch}}'`)
- [ ] `docker compose up -d --no-build` used — never `--build`
- [ ] target user in the `docker` group (§2.2) — the air-gapped host needs the
      same one-time setup
- [ ] `bash scripts/preflight.sh` reports PREFLIGHT OK
- [ ] a copy of this guide exists **on the target host** (you will not be able
      to re-download it)

## 4.6 Rebuilding inside the air gap (advanced)

Only needed if you must modify configs offline. Two options:

1. **Config-only changes** (haproxy.cfg, keepalived-*.conf, health.py): rebuild
   just the affected image with `WITH_BASES=1` images loaded:
   ```bash
   docker load -i images/python_3.12-slim-bookworm.tar
   docker load -i images/debian_bookworm-slim.tar
   docker compose build --pull=false
   ```
   `docker compose build` uses local base images when present; make sure no
   `--pull` sneaks in.
2. **Dependency changes**: pre-download on the connected host
   (`pip download -r health/requirements.txt -d health/wheels/`) and change the
   Dockerfile to `pip install --no-index --find-links=/wheels -r requirements.txt`.
   This path is *not* covered by the bundle scripts; test it before you need it.

---

# 5. First deployment (baseline)

Only run this after §3.16 passed (all files typed, diff empty, preflight OK).
Full command sequence with expected output lives in `../HANDS_ON.md`. The
reference flow:

```bash
cp -a docs/lab ~/mongodb-ha-lab
cd ~/mongodb-ha-lab
bash scripts/preflight.sh                 # expect: PREFLIGHT OK
docker compose up -d --build              # 9 containers starting
docker compose ps                         # 9 rows, State "running" (Up may be healthless)
bash scripts/init-replica.sh              # initiates labrs, waits for PRIMARY
bash scripts/status.sh                    # 1 PRIMARY + 2 SECONDARY, VIP on proxy1,
                                          # health1=200 health2=503 health3=503
```

First `docker compose up --build` pulls ~1 GB; subsequent starts are instant.

Baseline acceptance (must all pass before the failover labs):

| ID | Check | How |
|---|---|---|
| AC01 | 9 containers running | `docker compose ps` |
| AC02 | replica set initiated | `rs.status().ok == 1` |
| AC03 | exactly 1 PRIMARY, 2 SECONDARY | `bash scripts/status.sh` |
| AC04 | only the primary's checker returns 200 | status.sh health section |
| AC05 | exactly one proxy holds the VIP | status.sh VIP section |
| AC06 | write through VIP works, read back works | `mongosh` via VIP |

---

# 6. Concepts you need: MongoDB replica sets

## 6.1 Election, majority, priority, votes

- A replica set needs a **majority** (of *voting* members) to elect a primary
  and to commit writes with `w:"majority"`. With 3 voting members, majority = 2.
- An election needs a majority: if only 1 of 3 members is reachable, that
  member **cannot** become/stay primary. This is LAB09 and it is the whole
  point of "not automatically writing to a secondary".
- `priority` (0–100, default 1) makes a member *more likely* to win an
  election; priority 0 members can never be primary (useful for hidden
  analytics secondaries).
- `votes` defaults to 1; you may have at most 7 members with votes, and the
  number of *data-bearing* members with votes must stay majority-compatible.
- Elections take roughly `electionTimeoutMillis` (10 s default, randomized) to
  detect a dead primary, plus a few seconds to elect. Expect 10–30 s of write
  unavailability in this lab — normal, and the reason applications need retries.

## 6.2 What `hello` tells you

```javascript
db.hello()
// isWritablePrimary: true|false
// secondary: true|false        (implied when isWritablePrimary is false)
// setName: "labrs"
// primary: "mongo1:27017"      (who the current primary is, as seen by this node)
// me: "mongo2:27017"
```

`isWritablePrimary` (not the legacy `ismaster`) is what the health checker
uses.

## 6.3 Write concern, read preference, retry

| Setting | Meaning in this lab |
|---|---|
| `w:1` (default here) | primary acknowledges immediately; a failover right after can lose/rollback the write |
| `w:"majority"` | acknowledged only after a majority durable copy; a failover cannot lose it; writes fail while no primary exists |
| `readPreference: secondary` | reads may go to secondaries (fresh data only as fast as replication) |
| `directConnection=true` | driver stays on ONE server (used in the lab so traffic goes through HAProxy, not around it) |
| retryable writes | require a replica-set (non-direct) connection; disabled in the lab URIs on purpose |

The lab URIs therefore look like:

```text
mongodb://172.30.77.100:27017/labtest?directConnection=true&w=majority
```

Production URIs drop `directConnection` and use replica-set discovery plus
`retryWrites=true` — see §12.

## 6.4 Inspecting replication

```javascript
rs.status()                        // states, health, optimes, last election
rs.printSecondaryReplicationInfo() // replication lag per secondary
db.getMongo().setReadPref("secondary")
db.checks.find().sort({ $natural: -1 }).limit(3)
rs.stepDown(60)                    // planned stepdown (from the primary)
rs.freeze(120)                     // refuse to become primary for 120 s
db.adminCommand({ replSetResizeOplog: { maxSize: 1024 } })  // oplog sizing
```

---

# 7. Concepts you need: HAProxy

| Concept | In this lab |
|---|---|
| frontend / backend | one frontend on 27017, one backend `mongodb_primary` |
| L4 (`mode tcp`) | HAProxy never parses MongoDB wire protocol |
| health check | HTTP GET to the sidecar every 1 s; `fall 2`/`rise 2` gate the state |
| `check addr/port` | check a *different* host:port than the data target |
| `balance first` | first UP server in list order — with one UP server, deterministic |
| existing sessions | **never** moved: a session established to the old primary stays there (and usually dies when that node steps down) |
| stats socket | `echo "show stat" \| socat - stdio UNIX-CONNECT:/var/run/haproxy.sock` |
| logs | `docker compose logs -f proxy1` shows TCP log lines for new sessions and check failures |

The gap you must remember: HAProxy knows the primary *as of the last probe*.
A connection opened in that window may still hit a node that is stepping down.
Applications must retry; HAProxy cannot fix this.

---

# 8. Concepts you need: Keepalived / VRRP

| Concept | In this lab |
|---|---|
| VRRP instance | `VI_MONGO`, router id 77, unicast between .31 and .32 |
| MASTER/BACKUP | highest *effective* priority becomes MASTER and owns the VIP |
| advertisement | every 1 s; the BACKUP declares the master dead after ~3 s |
| preemption | default on; `preempt_delay 5` slows the takeover-back on recovery |
| GARP | MASTER broadcasts "who has 172.30.77.100?" so the bridge relearns |
| tracking script | local HAProxy health; `weight -30` demotes instead of FAULT |
| split-brain | two VIPs at once — what you must never accept as "working" |

Symptoms and their real causes:

| Symptom | Likely cause |
|---|---|
| no VIP anywhere | both proxies demoted/dead, or `NET_ADMIN` missing, or VRRP blocked |
| VIP on both proxies | different `virtual_router_id`, multicast instead of unicast, or a bridge that floods VRRP |
| VIP never moves on failure | keepalived not running, `NET_RAW` missing, or `unicast_peer` points at the wrong IP |
| VIP moves but apps still fail | HAProxy has no UP backend (no primary) — that is MongoDB's loop, not keepalived's |

Docker/WSL specifics: keepalived needs `NET_ADMIN` (VIP) and `NET_RAW` (VRRP).
Unicast is used because VRRP multicast is unreliable on the Docker bridge.
On some Docker Desktop/WSL setups the bridge still behaves oddly; if the VIP
never appears, run `docker compose logs proxy1 proxy2` and look for
`Netlink`, `Operation not permitted`, or `VRRP_Instance` lines before blaming
the config.

---

# 9. Failover exercises

Each exercise: **Goal → Commands → Expected → Why → Restore.**
Run them in order; every one builds on the baseline of §5.
`../HANDS_ON.md` contains the same sequence in pure copy-paste form.

## LAB01 — Baseline: 1 primary, 2 secondaries, VIP owner

**Goal.** See the steady state and learn to read it.

```bash
bash scripts/status.sh
docker compose logs health1 health2 health3 | tail -20
```

**Expected.** `mongo1` PRIMARY (`priority: 2` wins the first election),
`health1` prints `200`, `health2`/`health3` print `503`, exactly one proxy
shows `HOLDS THE VIP`, HAProxy stats show `mongo1 UP` and the other two DOWN.

**Why.** This is the state every later exercise perturbs. If baseline is
wrong, every failover result is uninterpretable.

## LAB02 — Write and read through the VIP

**Goal.** Prove the whole data path: client → VIP → HAProxy → primary.

```bash
docker compose exec client mongosh --quiet \
  'mongodb://172.30.77.100:27017/labtest?directConnection=true&w=majority' \
  --eval '
    db.checks.insertOne({ event: "baseline", at: new Date(), w: "majority" });
    print("hello.isWritablePrimary=" + db.hello().isWritablePrimary);
    printjson(db.checks.find().toArray());
  '
```

**Expected.** `insertedId` printed, `hello.isWritablePrimary=true`, the document
is returned by the find.

**Why.** `directConnection=true` is mandatory here: without it the driver would
discover all three members and connect to `mongo1:27017` directly, silently
bypassing HAProxy and proving nothing.

## LAB03 — Replication really happened

**Goal.** Read the same document from a secondary.

```bash
docker compose exec client mongosh --quiet \
  'mongodb://172.30.77.12:27017/labtest?directConnection=true' \
  --eval '
    db.getMongo().setReadPref("secondary");
    printjson(db.checks.find().toArray());
  '
```

**Expected.** The `baseline` document is present. If not, wait 1–2 s and retry
(replication is asynchronous by default).

**Why.** Failover only preserves data that reached a majority. With `w:1` and a
fast kill you can lose the newest write — LAB10.

## LAB04 — MongoDB primary failover (stop a mongod)

**Goal.** Loop 1 moves; observe that Loop 3 does *not*.

```bash
bash scripts/wait-for-primary.sh 5     # remember which node is primary
docker compose stop mongo1             # kill the primary
watch -n2 bash scripts/status.sh       # or run it repeatedly
bash scripts/wait-for-primary.sh 60
```

**Expected (typical).** 5–30 s after the stop, one of mongo2/mongo3 reports
`isWritablePrimary=true`. `health` for the new primary flips to `200`. HAProxy
stats flip within another ~2–5 s (fall/rise). **The VIP stays on proxy1.**

Then write again:

```bash
docker compose exec client mongosh --quiet \
  'mongodb://172.30.77.100:27017/labtest?directConnection=true&w=majority' \
  --eval 'db.checks.insertOne({ event: "after_failover", at: new Date() }); print("write ok");'
```

**Expected.** Either it succeeds (after the switch) or fails with
`ReplicaSetNoPrimary`/`not primary` for a few seconds — that is the window
between election and HAProxy's next probe. Retry once; it must succeed.

**Why.** This is the single most important observation of the whole lab: a
MongoDB failover does not move the VIP. The two elections are independent.

**Restore.**

```bash
docker compose start mongo1
# mongo1 rejoins as SECONDARY - priority 2 does NOT instantly reclaim primary
bash scripts/wait-for-primary.sh 60
```

## LAB05 — Old primary rejoins (priority and re-election)

**Goal.** Understand what happens when mongo1 comes back.

```bash
docker compose exec mongo1 mongosh --quiet --eval '
  const h = db.hello();
  print("me=" + h.me + " primary=" + h.primary + " isWritablePrimary=" + h.isWritablePrimary);
  rs.status().members.forEach(m => print(m.name + " " + m.stateStr));
'
```

**Expected.** mongo1 `SECONDARY`, the LAB04 survivor still PRIMARY, all three
`health` = 1. mongo1 stays secondary until an election happens (kill the
current primary, or use `rs.stepDown`).

Optional — planned stepdown from the *current* primary:

```bash
docker compose exec mongo2 mongosh --quiet --eval 'rs.stepDown(60); print("stepped down");'
bash scripts/wait-for-primary.sh 60
```

**Expected.** mongo2 becomes SECONDARY for at least 60 s (`freeze`), an
election runs, and mongo1 (priority 2) typically wins. HAProxy follows within
seconds.

**Why.** Priority biases elections; it never grants the primary role by fiat.
`rs.stepDown` is the *planned* way to move a primary without waiting for a
crash — production changes use it.

## LAB06 — Keepalived VIP failover (stop the VIP owner)

**Goal.** Loop 3 moves; observe that Loop 1 does not.

```bash
docker compose exec proxy1 ip -4 addr show dev eth0 | grep 172.30.77.100 \
  && echo "proxy1 owns the VIP"
docker compose stop proxy1
sleep 5
docker compose exec proxy2 ip -4 addr show dev eth0 | grep 172.30.77.100 \
  && echo "proxy2 now owns the VIP"
```

**Expected.** ~3–5 s after stopping proxy1, proxy2 shows `172.30.77.100/24`.
`docker compose logs proxy2 | grep -i vrrp` shows the MASTER transition.
MongoDB is untouched: the same mongod is still primary.

Verify the app path:

```bash
docker compose exec client bash -c \
  'timeout 3 bash -c "</dev/tcp/172.30.77.100/27017" && echo VIP port open'
docker compose exec client mongosh --quiet \
  'mongodb://172.30.77.100:27017/?directConnection=true' \
  --eval 'print("isWritablePrimary=" + db.hello().isWritablePrimary)'
```

**Restore (watch preemption).**

```bash
docker compose start proxy1
sleep 10
docker compose exec proxy1 ip -4 addr show dev eth0 | grep 172.30.77.100 \
  && echo "proxy1 took the VIP back (preempt_delay=5)"
```

**Expected.** proxy1 preempts after ~5 s: priority 120 > 110. Any TCP session
that was using proxy2 is dropped at that moment — applications must reconnect.

**Why.** A VIP move breaks *existing* TCP connections on both sides. HAProxy
and keepalived cannot migrate sessions; only the client's reconnect logic can.

## LAB07 — HAProxy dies inside the proxy container

**Goal.** See the local tracking script in action.

```bash
docker compose exec -T proxy1 pkill -x haproxy || true
docker compose logs --tail 20 proxy1
docker compose ps proxy1          # restarting: start.sh exited 1 -> docker restarts
sleep 10
docker compose exec proxy2 ip -4 addr show dev eth0 | grep 172.30.77.100 \
  && echo "VIP moved to proxy2"
```

**Expected.** start.sh detects the dead HAProxy, stops keepalived, exits 1;
Docker restarts proxy1; after HAProxy listens and keepalived stabilises,
proxy1 preempts the VIP back.

**Why.** In production (two systemd units) the keepalived instance stays alive
and is *demoted* by `weight -30`, which is smoother. The lab's coupled
container reaches the same end state with an extra restart. Know which
mechanism you are looking at before you debug production.

## LAB08 — Quorum loss (no primary, no writes)

**Goal.** Prove the system refuses to write to a secondary.

```bash
bash scripts/wait-for-primary.sh 5
docker compose stop mongo2 mongo3      # 1 of 3 members left = no majority
sleep 15
docker compose exec mongo1 mongosh --quiet --eval 'print("isWritablePrimary=" + db.hello().isWritablePrimary)'
```

**Expected.** `isWritablePrimary=false` after ~10–30 s (mongo1 stepped down
once it noticed it lost the majority).

```bash
docker compose exec client mongosh --quiet \
  'mongodb://172.30.77.100:27017/labtest?directConnection=true&w=majority' \
  --eval 'try { db.checks.insertOne({ event: "quorum_loss" }); print("write ok"); }
          catch (e) { print("write refused: " + e.message); }'
```

**Expected.** `write refused` (or a connection error), because HAProxy has no
UP backend (`health1` also returns 503). There is no silent fallback to the
single remaining node.

**Restore.**

```bash
docker compose start mongo2 mongo3
bash scripts/wait-for-primary.sh 90
```

**Expected.** A new election; usually mongo1 (priority 2) becomes primary again.

**Why.** "No writes during a minority" is the correct behaviour: the alternative
is a split-brain where two nodes both believe they are primary and diverge.

## LAB09 — Unresponsive node (pause instead of stop)

**Goal.** Simulate a hung machine (no clean shutdown, no TCP close).

```bash
docker compose stop mongo1 mongo2      # leave mongo3, then:
docker compose start mongo1
sleep 3
docker compose pause mongo1            # frozen: no heartbeats, TCP stays "open"
bash scripts/wait-for-primary.sh 60
```

**Expected.** mongo3 (with mongo2 down, mongo1 frozen) — only 2 of 3 members
can ever answer; if both mongo2 and mongo1 are effectively gone, no majority →
no primary. For a *clean* demonstration of "2 of 3 elect a new primary", use:

```bash
docker compose unpause mongo1
docker compose stop mongo1             # mongo1 dead, mongo2+mongo3 alive
bash scripts/wait-for-primary.sh 60    # -> PRIMARY: mongo2 or mongo3
docker compose start mongo1            # old primary rejoins as SECONDARY
```

**Why.** A frozen process is nastier than a stopped one: the OS keeps the TCP
connection, so clients see timeouts instead of connection-refused. MongoDB's
heartbeat timeout (10 s) is what eventually drives the election.

## LAB10 — Write concern and data-loss risk

**Goal.** Feel the difference between `w:1` and `w:"majority"`.

```bash
# restore a healthy 3-member set first (see LAB08 restore)
docker compose exec client mongosh --quiet \
  'mongodb://172.30.77.100:27017/labtest?directConnection=true&w:1' \
  --eval 'db.unsafe.insertOne({ n: 1, at: new Date() }); print("w:1 acked");'

docker compose exec client mongosh --quiet \
  'mongodb://172.30.77.100:27017/labtest?directConnection=true&w=majority' \
  --eval 'db.safe.insertOne({ n: 2, at: new Date() }); print("w:majority acked");'

# now kill the primary IMMEDIATELY and inspect the survivors
PRIMARY=$(docker compose exec -T client mongosh --quiet \
  'mongodb://172.30.77.100:27017/?directConnection=true' \
  --eval 'print(db.hello().me.split(":")[0])')
docker compose stop "$PRIMARY"
sleep 5
docker compose start "$PRIMARY"
# after rejoin, look for rollback files:
docker compose exec "$PRIMARY" sh -c 'ls -la /data/db/journal 2>/dev/null; ls /data/db/*.bson 2>/dev/null'
```

**Expected / interpretation.** A `w:"majority"` write that was acknowledged
*must* survive. A `w:1` write acknowledged moments before the kill may be
rolled back (the node returns as secondary and discards the uncommitted write).
Whether you actually observe it depends on timing — that is the lesson:
`w:1` gives you *no guarantee*, `w:"majority"` gives you one.

**Why.** This is why production replicas use `w:"majority"` (or journal-ack
plus an explicit risk review), and why "the write said ok" is not the same as
"the write is safe".

## LAB11 — Clean shutdown, persistence, full reset

**Goal.** Prove data survives a restart, then wipe cleanly.

```bash
docker compose exec client mongosh --quiet \
  'mongodb://172.30.77.100:27017/labtest?directConnection=true' \
  --eval 'print("count=" + db.checks.countDocuments({}))'

docker compose down            # containers + network gone, VOLUMES kept
docker compose up -d           # no --build needed; images still exist
bash scripts/init-replica.sh   # idempotent: "already initialised"
docker compose exec client mongosh --quiet \
  'mongodb://172.30.77.100:27017/labtest?directConnection=true' \
  --eval 'print("count=" + db.checks.countDocuments({}))'   # same number

docker compose down -v         # DELETES the data volumes - full reset
docker volume ls | grep mongo || echo "lab volumes removed"
```

**Why.** `down` ≠ `down -v`. Knowing which one destroys data is the difference
between a restart and an outage.

---

# 10. Troubleshooting

| Symptom | Checks (in order) |
|---|---|
| `permission denied ... docker API` | §2.2: `sg docker -c 'docker info'`, re-login, `systemctl is-active docker` |
| build fails pulling images | connected host needed once; or load the air-gap bundle and use `--no-build` |
| `docker compose up` fails: port/IP in use | another `mongo-ha-net` exists: `docker compose down`, `docker network rm mongo-ha-net`, or change the subnet (§3.8) |
| 9 containers but no PRIMARY | `bash scripts/init-replica.sh` (must be run once); `docker compose logs mongo1 \| grep -i error`; check memory (`mongod` refusing to start on low RAM) |
| all health checkers 503 | replica set not initiated, or election in progress — `bash scripts/wait-for-primary.sh 90` |
| one checker 503 forever | `docker compose logs healthN`; `docker compose exec healthN python -c 'print("ok")'`; restart `docker compose restart healthN` |
| HAProxy: all servers DOWN, VIP answers nothing | no primary (LAB08 state) or checkers failing — `docker compose logs proxy1 \| grep -i check` |
| no VIP on any proxy | `docker compose logs proxy1 proxy2 \| grep -iE 'vrrp\|netlink\|error'`; confirm `cap_add` in compose; confirm `interface eth0` matches (`docker compose exec proxy1 ip -o link`); confirm `check-haproxy.sh` is root-owned 0755 (keepalived disables an "insecure" script and then the VIP never appears) |
| VIP on BOTH proxies | must never be accepted as working: check identical `virtual_router_id`, `unicast_peer` correctness, then isolate one proxy and re-test |
| VIP present but writes fail | mongo in election (wait ≤30 s), or HAProxy hasn't probed yet (≤5 s), or the *client URI* bypasses the VIP |
| client connects to the wrong node | missing `directConnection=true` in the URI — the driver is doing replica-set discovery |
| writes hang after failover | long `w:"majority"` with a minority; or an old TCP session to the old primary — reconnect |
| `keepalived: Disabling track script ... insecure` | the tracked script is not root-owned/not 0755: rebuild the proxy image, check `chmod 0755 /usr/local/bin/check-haproxy.sh` in the Dockerfile |
| containers restart in a loop | `docker compose logs proxy1` — start.sh refuses to start on a config error by design; read the first error line |
| everything dies together | that is the single-host limit of this lab: one WSL2/VM outage kills all nine containers. Real HA needs ≥2 hosts |

Diagnostic one-liners used constantly:

```bash
docker compose ps                                   # who is running
bash scripts/status.sh                              # full picture
docker compose logs -f --tail 50 proxy1 proxy2      # haproxy + keepalived
docker compose logs -f --tail 50 mongo1             # mongod
docker compose exec proxy1 sh -c 'echo "show stat" | socat - stdio UNIX-CONNECT:/var/run/haproxy.sock' | cut -d, -f1,2,18
docker compose top                                  # processes inside containers
docker stats --no-stream                            # cpu/ram of the 9 containers
```

---

# 11. Cleanup

```bash
docker compose stop          # stop, keep everything (data included)
docker compose start         # start again
docker compose down          # remove containers + network, keep data volumes
docker compose down -v       # remove data volumes too
docker volume ls | grep mongo-ha-lab
docker image rm mongodb-ha-lab-health:local mongodb-ha-lab-proxy:local
docker network rm mongo-ha-net
```

Do **not** use `docker system prune --volumes` to clean this lab: it will eat
every other project on the machine.

---

# 12. From the lab to production (untested — read before adapting)

Everything in this section is intentionally *not* enabled in the lab and must
be designed, tested and reviewed before real deployment.

## 12.1 Authentication first

Without auth, anyone who can reach 27017 owns your data. Minimum viable:

```bash
# on each mongod host
openssl rand -base64 756 > /etc/mongodb-keyfile
chown mongod:mongod /etc/mongodb-keyfile
chmod 400 /etc/mongodb-keyfile
# mongod command line or yaml: --keyFile /etc/mongodb-keyfile  (implies auth)
```

Then create users *before* opening the port:

```javascript
use admin
db.createUser({
  user: "clusterAdmin",
  pwd: passwordPrompt(),          // store in a secret manager
  roles: [ { role: "clusterAdmin", db: "admin" } ]
});
use appdb
db.createUser({
  user: "app",
  pwd: passwordPrompt(),
  roles: [ { role: "readWrite", db: "appdb" } ]
});
```

URI becomes `mongodb://user:pass@vip:27017/appdb?authSource=admin&w=majority&retryWrites=true`.

## 12.2 TLS

Use internal CA certificates (or `mongod`'s `net.tls` with `clusterAuthX509`),
enable `net.tls.mode: requireTLS`, and configure HAProxy with
`ssl ca-file ... verify required` on the frontend/backend if you terminate TLS
at the proxy, or `mode tcp` pass-through if MongoDB handles TLS itself.
Pass-through keeps HAProxy ignorant of the protocol (what this lab does) but
loses per-user logging; termination gives visibility but you must handle
MongoDB's x509 cluster auth mapping.

## 12.3 systemd on real VMs

```ini
# /etc/systemd/system/haproxy.service.d/override.conf
[Service]
ExecReload=/usr/sbin/haproxy -c -f /etc/haproxy/haproxy.cfg
Restart=always
RestartSec=2

# /etc/systemd/system/keepalived.service.d/override.conf
[Service]
ExecStartPre=/usr/sbin/keepalived --config-test -f /etc/keepalived/keepalived.conf
Restart=always
```

Production layout: HAProxy+Keepalived on two *dedicated* VMs (or on the
application nodes), MongoDB on three (or five) *separate* failure domains,
VIP in the real subnet, `net.ipv4.ip_nonlocal_bind=1` on the proxies if HAProxy
must bind the VIP explicitly.

## 12.4 Monitoring and alerting

| Signal | Source | Alert when |
|---|---|---|
| primary changed | `rs.status().members[].stateStr` or MongoDB exporter | any change (page) |
| replication lag | `rs.printSecondaryReplicationInfo()` / `db.serverStatus().repl` | > 60 s |
| secondaries | `mongosh --eval 'db.hello().secondary'` | < expected count |
| HAProxy backend | stats socket / Prometheus exporter | `mongodb_primary` has 0 UP servers |
| VIP owner | keepalived notify script / SNMP | owner changed, or none |
| elections | `db.serverStatus().electionMetrics` | > 1/hour |

Keepalived notify hooks (production):

```text
vrrp_instance VI_MONGO {
    notify_master "/usr/local/bin/notify.sh MASTER"
    notify_backup "/usr/local/bin/notify.sh BACKUP"
    notify_fault  "/usr/local/bin/notify.sh FAULT"
}
```

## 12.5 Backups

```bash
mongodump --uri='mongodb://user:pass@vip:27017/?replicaSet=labrs' \
          --archive=/backup/$(date +%F).archive --gzip --oplog
# restore drill (do it regularly, a backup you never restored is a hope):
mongorestore --uri='mongodb://user:pass@newhost:27017/?directConnection=true' \
             --archive=/backup/2026-10-27.archive --gzip --drop
```

Point-in-time recovery needs a backup tool with oplog/PITR (Ops Manager,
community PITR tooling) — plan it, do not improvise during an incident.

## 12.6 Security notes for the lab itself

- The lab has **no auth, no TLS, no firewall**, and the client container can do
  anything. It is isolated only by being a private Docker bridge. Never expose
  these ports (`ports:` publish) on a shared or public network.
- Run the lab as a non-privileged user in the `docker` group only; membership
  in `docker` is effectively root on that host.
- Pin image digests in production (`docker pull mongo@sha256:...`) and mirror
  them into your internal registry; the lab pins tags only.

---

# 13. Final acceptance checklist

| ID | Criterion | Exercise |
|---|---|---|
| AC01 | 9 containers running | §5 |
| AC02 | replica set `labrs` initiated | §5 |
| AC03 | exactly 1 PRIMARY + 2 SECONDARY | LAB01 |
| AC04 | only the primary's checker returns HTTP 200 | LAB01 |
| AC05 | exactly one proxy holds the VIP | LAB01 |
| AC06 | write + read through the VIP | LAB02, LAB03 |
| AC07 | stopping the primary elects a new one | LAB04 |
| AC08 | HAProxy switches to the new primary automatically | LAB04 |
| AC09 | stopping the VIP owner moves the VIP | LAB06 |
| AC10 | killing HAProxy alone still ends with a working VIP | LAB07 |
| AC11 | minority → no primary, writes refused, no silent secondary writes | LAB08 |
| AC12 | data survives `down`/`up`, `down -v` wipes it | LAB11 |

When all twelve pass on your machine, you have verified the full chain:

```text
MongoDB election → primary health check → HAProxy backend switch
    → Keepalived VIP failover → application reconnect
```

The next step beyond this lab is the same design on ≥2 hosts with systemd,
auth/TLS, real network partitions and fencing — everything §12 lists and this
lab cannot simulate.

---

# 14. References (download for offline reading)

- MongoDB — Deploy a Replica Set: https://www.mongodb.com/docs/manual/tutorial/deploy-replica-set
- MongoDB — Replica Set Elections: https://www.mongodb.com/docs/manual/core/replica-set-elections/
- MongoDB — Write Concern / Read Preference: https://www.mongodb.com/docs/manual/reference/write-concern/ · https://www.mongodb.com/docs/manual/core/read-preference/
- HAProxy — Health checks: https://www.haproxy.com/documentation/haproxy-configuration-tutorials/reliability/health-checks
- HAProxy 2.6 Configuration Manual: https://docs.haproxy.org/2.6/configuration.html
- Keepalived keepalived.conf(5): https://www.keepalived.org/documentation/keepalived-conf/
- VRRP RFC 5798: https://www.rfc-editor.org/rfc/rfc5798
