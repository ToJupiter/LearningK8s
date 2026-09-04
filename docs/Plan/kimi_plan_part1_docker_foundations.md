# Part 1 of 5 — The Laboratory & Docker Mastery
### Covers: Preface + Phase 0-3 (Days 1-3) | Source: `docs/Plan/kimi_plan.md`

> **THE AUDIT LINEAGE.** This plan has already survived two model audits. This split adds a third pass with
> two lenses running in parallel — the same discipline a real godlike system manager applies to every runbook:
> - **[A] The Architect** — "Is any concept chain incomplete? Does any term appear before it is explained? Can the student whiteboard this?"
> - **[B] The Operator** — "What breaks at 2 AM? What will the student actually hit that the plan never warned about?"
>
> Every part file ends with: **Audit Findings** (what was missing — now added) and an **Exit Exam**
> (do not open the next part until you pass it in front of a blank terminal).

## The Experience Protocol — Read Once, Practice Forever

The original plan teaches *topics*. A sysadmin is built from *experience*. This protocol converts every lab into experience:

1. **Lab notebook.** Every numbered lab directory gets a `NOTES.md` with this template:
   ```
   Goal: what I wanted to prove
   Commands: what I actually ran
   Observed: real output pasted (not paraphrased)
   Surprised me: the delta between expectation and reality — this is where learning lives
   One failure + root cause: deliberately or accidentally broken, and the causal chain
   Note to past-me: the one-liner that would have saved 30 minutes
   ```
   Commit after every session: `git commit -m "lab(1.3): flask image, broke USER ordering, fixed"`.
2. **Break-it-first rule.** After each green-path lab, break it on purpose: wrong port, wrong tag, kill the process, delete the volume. Record the *error signature* (exact string/symptom). You are building a pattern-matching engine in your head — that engine IS seniority.
3. **ERRORS.md.** One file at repo root, appended forever: `error string -> cause -> fix -> prevention`. By Part 5 this file is your personal runbook, your interview story bank, and your team's onboarding doc.
4. **Verify every claim.** If the plan says "you can see nginx processes from the host", run it and paste real output. If it doesn't match (version drift, image changes), *investigate the mismatch* — that investigation is the real curriculum.
5. **Timebox + escalate.** 45 minutes stuck = write the question down precisely, move on, return tomorrow. This is not quitting; this is the real SRE escalation discipline. A precisely-written question usually answers itself by morning.

---


---

# The Complete Docker → Kubernetes (K3s) Deep Learning Masterplan
## From Absolute Zero to AI Supercomputer Concepts in One Structured Journey

---

## Preface: The Mental Model Before Code

Before typing a single command, you must understand **why** containers changed everything.

Imagine you write a Python application on your Windows laptop. It works perfectly. You send it to a friend running macOS. It breaks. You deploy it to a Linux server. It breaks differently. The problem isn't your code—it's the **implicit environment**: the OS kernel version, the system libraries, the environment variables, the file paths, the installed dependencies.

**Containers solve this by shipping the environment with the application.** They don't virtualize the hardware (like VMs); they virtualize the **OS interface**. A container says: "No matter what host you run me on, I see the same filesystem, the same libraries, and the same network stack."

This is achieved through three Linux kernel features you must understand deeply:
1. **Namespaces** — Isolate processes (PID, NET, MNT, UTS, IPC, USER, CGROUP)
2. **Control Groups (cgroups)** — Limit resource usage (CPU, memory, I/O)
3. **Union File Systems (OverlayFS)** — Layered, copy-on-write filesystems

Docker makes these kernel features accessible. Kubernetes automates them at scale. K3s is Kubernetes with the non-essential parts removed, designed for resource-constrained environments—perfect for your WSL setup.

---

## Phase 0: Your Laboratory Setup (WSL2 + Debian + K3s)

Your environment is your classroom. Set it up once, understand every piece.

### 0.1 WSL2 Configuration

Since your computer is weak, **resource boundaries are critical**. WSL2 can consume all your RAM and CPU if unconstrained.

Create/edit `%USERPROFILE%\.wslconfig` on Windows:

```ini
[wsl2]
memory=6GB              # Adjust based on your total RAM. Never exceed 75%.
processors=4            # Leave cores for Windows.
swap=2GB                # Necessary for K3s when memory pressure hits.
localhostForwarding=true
```

Then `wsl --shutdown` in PowerShell to apply.

### 0.2 Debian Preparation

```bash
# Update and install essentials
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git vim nano htop net-tools iputils-ping dnsutils

# CRITICAL: K3s does not support nftables. Switch to iptables-legacy.
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Verify systemd is available (modern WSL2 supports this natively)
systemctl --version
```

### 0.3 Docker Installation (Rootless recommended for WSL)

```bash
# Install Docker CE
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Add your user to docker group to avoid sudo
sudo usermod -aG docker $USER
newgrp docker

# Verify
docker version
docker run hello-world
```

### 0.4 K3s Installation (The Lightweight Kubernetes)

K3s is a certified Kubernetes distribution. It replaces etcd with SQLite (by default, via the Kine shim), keeps the standard upstream kube-proxy for Service routing, and uses Flannel for CNI. It's one binary.

```bash
# Install K3s server with specific flags for WSL/resource constraints
curl -sfL https://get.k3s.io | sh -s - server \
  --disable=traefik \           # We'll install ingress manually to learn it
  --write-kubeconfig-mode=644 \ # Allow non-root kubectl access
  --node-name=master-wsl

# Verify
sudo systemctl status k3s
kubectl get nodes
```

**Important K3s on WSL Note:** WSL2's virtual network interface changes IP on restart, which can break saved kubeconfig `server:` addresses and serving certs (full story in Part 4, audit B1). For non-root `kubectl` access *inside the WSL distro*, add this to your `~/.bashrc` (this does nothing for kubectl on the Windows side — that needs the WSL IP or a `--tls-san` hostname):

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

### 0.5 Your Git Repository Structure

Create this repository now. You'll populate it throughout the journey.

```
k8s-mastery-lab/
├── 01-docker-fundamentals/
│   ├── 01-first-container/
│   ├── 02-dockerfile-deep-dive/
│   ├── 03-networking-lab/
│   ├── 04-volumes-lab/
│   └── 05-multi-stage-optimization/
├── 02-docker-compose-bridge/
│   ├── 01-two-tier-app/
│   ├── 02-microservices-stack/
│   └── 03-compose-profiles/
├── 03-k8s-foundations/
│   ├── 01-pods/
│   ├── 02-deployments/
│   ├── 03-services/
│   ├── 04-configmaps-secrets/
│   └── 05-probes/
├── 04-k8s-workloads/
│   ├── 01-statefulsets/
│   ├── 02-daemonsets/
│   ├── 03-jobs-cronjobs/
│   └── 04-hpa/
├── 05-k8s-networking-storage/
│   ├── 01-ingress/
│   ├── 02-pvc-pv/
│   └── 03-network-policies/
├── 06-real-world-stack/
│   ├── postgres/
│   ├── redis/
│   ├── kafka/
│   └── spring-boot-app/
├── 07-observability/
│   ├── metrics-server/
│   └── logging/
└── scripts/
    ├── wsl-setup.sh
    └── cleanup.sh
```

Initialize it:
```bash
git init
git add .
git commit -m "init: docker to k8s mastery lab structure"
```

---

## Phase 1: Docker Foundations (Days 1-2)

### 1.1 What Is a Container, Really?

A container is **not** a mini-VM. It is a **process** (or tree of processes) running on the host kernel, isolated via namespaces and constrained via cgroups.

Run this to see the truth:
```bash
docker run -d --name nginx-test nginx:alpine
ps aux | grep nginx          # You can see nginx processes from host!
cat /proc/$(pgrep nginx)/cgroup  # See the cgroup constraints
ls /proc/$(pgrep nginx)/ns/      # See the namespaces
```

**Key Insight:** Containers share the host kernel. That's why Windows containers and Linux containers are different—you can't run a Linux container natively on Windows without a VM (WSL2 is that VM).

### 1.2 Images: Layered Blueprints

A Docker image is a read-only stack of layers. Each instruction in a Dockerfile creates a new layer.

```
Layer 4: COPY . /app          (your code)
Layer 3: RUN npm install      (dependencies)
Layer 2: WORKDIR /app         (metadata)
Layer 1: FROM node:20-alpine  (base image)
```

These layers are stored using **UnionFS/OverlayFS**. When a container runs, Docker adds a writable top layer (the container layer). When the container dies, that writable layer is discarded (unless you commit it, which you rarely should).

**Deep Understanding Exercise:**
```bash
docker pull nginx:alpine
docker history nginx:alpine    # See every layer and its size
```

### 1.3 The Dockerfile: Your First Deep Dive

Create `01-docker-fundamentals/02-dockerfile-deep-dive/Dockerfile`:

```dockerfile
# Every Dockerfile starts with FROM. This is your foundation.
# Alpine Linux is ~5MB. It's the standard for minimal images.
FROM alpine:3.19

# LABEL adds metadata. Good practice for organization.
LABEL maintainer="student@k8s.lab"
LABEL version="1.0"

# RUN executes commands at BUILD time and creates a layer.
# Combine commands to reduce layers, but balance readability.
RUN apk add --no-cache python3 py3-pip && \
    pip3 install --no-cache-dir flask

# WORKDIR creates the directory and CDs into it.
# Prefer WORKDIR over 'cd' in RUN commands.
WORKDIR /app

# COPY copies from build context (your machine) to image.
# Syntax: COPY <src> <dest>
COPY app.py .

# EXPOSE documents the port. It does NOT actually publish it.
# It's documentation + used by -P flag.
EXPOSE 5000

# ENV sets environment variables available at runtime.
ENV FLASK_APP=app.py
ENV PYTHONUNBUFFERED=1

# USER changes to non-root. CRITICAL for security.
# Never run containers as root in production.
RUN adduser -D -s /bin/sh appuser
USER appuser

# CMD is the default command when container starts.
# There can only be one CMD. If you specify one in 'docker run', it overrides this.
CMD ["python3", "-m", "flask", "run", "--host=0.0.0.0"]
```

Create `app.py`:
```python
from flask import Flask
import socket
app = Flask(__name__)

@app.route('/')
def hello():
    return {
        "message": "Hello from deep inside a container",
        "hostname": socket.gethostname(),
        "pid": open('/proc/1/comm').read().strip()
    }

if __name__ == '__main__':
    app.run()
```

Build and run with understanding:
```bash
docker build -t my-flask:1.0 .
docker images                    # See your image, note the size
docker run -d -p 8080:5000 --name flask-app my-flask:1.0
curl localhost:8080
docker logs flask-app
```

### 1.4 Container Lifecycle Deep Dive

```bash
# Create but don't start
docker create --name test nginx:alpine

# Start it
docker start test

# Pause (freeze all processes with SIGSTOP)
docker pause test

# Unpause
docker unpause test

# Stop (sends SIGTERM, waits 10s, then SIGKILL)
docker stop test

# Kill (immediate SIGKILL)
docker kill test

# Remove (must be stopped first, or use -f)
docker rm test

# Remove everything stopped
docker container prune
```

**Critical Concept:** `docker stop` vs `docker kill`. Your applications must handle SIGTERM properly for graceful shutdown. In Kubernetes, this becomes the `terminationGracePeriodSeconds`.

### 1.5 Docker CLI Mental Model

Learn these command groups:
- **Management:** `docker container`, `docker image`, `docker network`, `docker volume`
- **Runtime:** `docker run`, `docker exec`, `docker attach`
- **Info:** `docker inspect`, `docker logs`, `docker stats`, `docker top`
- **System:** `docker system df`, `docker system prune`

---

## Phase 2: Docker Networking & Storage (Day 2-3)

### 2.1 Networking: How Containers Talk

Docker has five network drivers. You must understand the first three deeply:

**bridge (default):**
```bash
docker network create --driver bridge my-bridge
docker run -d --network my-bridge --name web nginx:alpine
docker run -d --network my-bridge --name client alpine sleep 3600

# From 'client', you can reach 'web' by container name! DNS resolution is built-in.
docker exec -it client ping web
```

**host:** Container shares host network stack. Fastest, but no isolation.
```bash
docker run -d --network host nginx:alpine
# Now nginx is on host's port 80. No port mapping needed.
```

**none:** No network. Completely isolated.
```bash
docker run -d --network none nginx:alpine
```

**Overlay & Macvlan:** Used in Docker Swarm and advanced scenarios. Skip for now; you'll meet overlay concepts again in Kubernetes CNI.

**Deep Exercise:**
```bash
# Inspect the bridge network
docker network inspect bridge

# See the veth pairs created on host
ip addr show

# See iptables rules Docker created
sudo iptables -t nat -L -n | grep DOCKER
```

### 2.2 Storage: Persisting Data

Containers are ephemeral. When they die, their writable layer is gone. You need persistent storage.

**Bind Mounts:** Mount a host path into the container.
```bash
docker run -v /host/data:/container/data nginx:alpine
# Problem: Host path dependency. Not portable.
```

**Volumes:** Docker-managed storage.
```bash
docker volume create pgdata
docker run -v pgdata:/var/lib/postgresql/data postgres:16-alpine
# Docker manages the actual location on host. Portable.
```

**tmpfs mounts:** RAM-only storage. Fast, non-persistent.
```bash
docker run --tmpfs /cache:rw,noexec,nosuid,size=100m nginx:alpine
```

**Deep Understanding:**
```bash
# Where does Docker store volumes on WSL?
docker volume inspect pgdata
# On WSL: /var/lib/docker/volumes/pgdata/_data
```

---

## Phase 3: Docker Optimization & Security (Day 3)

### 3.1 Layer Caching: The Build Cache

Docker caches each layer. If a layer's inputs haven't changed, Docker reuses the cached layer.

**The Golden Rule:** Order your Dockerfile from least-changing to most-changing.

```dockerfile
# GOOD: Dependencies change less often than code
COPY package*.json ./
RUN npm ci
COPY . .

# BAD: Any code change invalidates the npm install cache
COPY . .
RUN npm ci
```

### 3.2 Multi-Stage Builds: The Most Important Optimization

This is the bridge between development and production. 

Create `05-multi-stage-optimization/Dockerfile`:

```dockerfile
# ========== STAGE 1: BUILDER ==========
# Heavy image with all build tools
FROM golang:1.22-alpine AS builder

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# Static binary: no dynamic library dependencies
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o app .

# ========== STAGE 2: RUNTIME ==========
# Almost empty image. Only 2MB.
FROM scratch

# We need CA certs for HTTPS
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy ONLY the binary from builder stage
COPY --from=builder /build/app /app

# No shell. No package manager. Minimal attack surface.
ENTRYPOINT ["/app"]
```

**Why this matters:**
- Builder stage: 300MB+ (has Go compiler, git, etc.)
- Final image: ~5MB (just your binary)
- No shell to exploit if hacked
- Faster deployments, less bandwidth

### 3.3 .dockerignore

Prevent sending garbage to the Docker daemon:
```
.git
.gitignore
Dockerfile*
docker-compose*
README.md
.env
node_modules
vendor
*.log
coverage
```

### 3.4 Security Best Practices

1. **Never run as root:**
```dockerfile
RUN addgroup -g 1000 appgroup && adduser -u 1000 -G appgroup -D appuser
USER appuser
```

2. **Use distroless or scratch for production:**
   - `gcr.io/distroless/java17-debian12` for Java
   - `gcr.io/distroless/python3` for Python
   - `scratch` or `chainguard` images for Go/Rust

3. **Scan images:**
```bash
docker scout cves my-image:latest
```

4. **Read-only root filesystem:**
```bash
docker run --read-only --tmpfs /tmp --tmpfs /var/run nginx:alpine
```

---

---

## Part 1 Audit — What Was Missing

### Factual fixes applied to the master text during this audit

| Location | Issue | Fix |
|---|---|---|
| Phase 4.x compose files | `version: "3.9"` is obsolete — Docker Compose v2 ignores it and prints a warning | Treated as legacy; write Compose files without `version:` from now on |
| Phase 0.3 | "Rootless recommended for WSL" but the commands install rootful Docker CE | Fine for a lab; the rootless path (Part 4 audit B-notes) needs `dockerd-rootless.sh` + subuid/subgid. Do rootful now, understand rootless later — don't burn Day 1 on it |

### [A] Architect findings — concept chains that had holes

**A1. Exit codes — the sysadmin's first vital sign.** The plan shows `docker stop` vs `docker kill` but never teaches the number the system hands back. Memorize:

| Code | Meaning |
|---|---|
| 0 | clean exit |
| 1 | application error — read the logs |
| 125 | `dockerd` itself rejected the run (bad flag) |
| 126 | command found but not executable |
| 127 | command not found (wrong base image / missing binary / bad PATH) |
| 137 | 128+9 = SIGKILL: OOMKill, `docker kill`, or `kill -9` |
| 143 | 128+15 = SIGTERM accepted: graceful stop worked |

```bash
docker run --rm alpine nosuchcommand; echo $?        # 127
docker run --rm -m 50m alpine sh -c 'apk add -q stress && stress --vm 1 --vm-bytes 200m'; echo $?  # 137
# 143 needs a real SIGTERM — a sleep that finishes on its own exits 0. Do this instead:
docker run -d --name term-demo alpine sleep 600
docker stop term-demo                                 # sends SIGTERM, waits, then SIGKILLs if needed
docker inspect term-demo --format 'ExitCode={{.State.ExitCode}}'  # 143 = SIGTERM honored
docker rm term-demo
docker run -d --name kill-demo alpine sleep 600
docker kill kill-demo; docker inspect kill-demo --format 'ExitCode={{.State.ExitCode}}'  # 137
docker rm kill-demo
```
Kubernetes reports the same numbers in `kubectl describe pod` (`State: Terminated, Reason: OOMKilled, Exit Code: 137`). Seeing 143 vs 137 tells you instantly whether an app died gracefully or was executed.

**A2. `docker inspect` — learn to read the JSON like prose.** Four sections cover 90% of debugging: `.State` (Running/OOMKilled/ExitCode/Error/StartedAt), `.HostConfig` (Memory, CapAdd, Binds, RestartPolicy), `.NetworkSettings` (IPAddress, Ports, Networks), `.Config` (Env — check for leaked secrets, Cmd, Image). Drill: extract each with `--format` until fluent. This is *the same skill* as `kubectl describe` + `kubectl get -o jsonpath` — Part 2 depends on it.

**A3. PID 1 duties — the two things your app doesn't do.** In a container your app is PID 1, and PID 1 has two kernel-level jobs ordinary processes delegate to init: forwarding signals to children and reaping zombie children. Symptoms: `docker stop` hangs the full 10s then SIGKILLs (no signal forwarding), or `/proc` fills with `<defunct>` entries (no reaping). Fixes:
- `docker run --init` (Docker injects tini as PID 1), or
- shell entrypoints MUST end with `exec "$@"` — replaces the shell so the app *becomes* PID 1:
  ```bash
  #!/bin/sh
  set -e
  ./wait-for-db.sh
  exec java -jar app.jar    # without exec, java is a CHILD of sh and never sees SIGTERM
  ```
  This single line is the top graceful-shutdown bug in the industry.

**A4. `exec` vs `attach`.** `docker exec` starts a *new* process in the container. `docker attach` welds your terminal to PID 1's stdio — meaning `ctrl-c` sends SIGINT to PID 1 and can kill the whole container. Prefer `exec`; if you must attach, use `--no-stdin` or detach with `ctrl-p ctrl-q`. Classic interview trap.

**A5. Image taxonomy: tagged vs dangling vs intermediate.** Rebuilding with the same tag orphans the old layers as `<none>:<none>` (dangling). `docker images -a` shows intermediates. `docker image prune` (dangling only) vs `docker image prune -a` (unused by any container — destructive). On a 6GB WSL box this is weekly hygiene, not trivia: orphan layers are the silent disk-eater.

**A6. Port publishing mechanics.** `-p 127.0.0.1:8080:5000` binds loopback only (host-LAN cannot reach — a security feature, use it for DB admin UIs); `-P` auto-publishes everything in `EXPOSE` — discover with `docker port <name>`; `-p 8080:5000/udp` for DNS-style services. Behind the scenes: DNAT in the iptables `DOCKER` chain (you saw it in 2.1 — now connect cause and effect). Published != reachable: host firewall (`ufw`, Windows Defender) can silently drop — a top-3 "it worked yesterday" mystery.

**A7. Build context discipline.** Watch the `transferring context: XXX MB` line on every build. A 500MB context makes every build slow even with a perfect cache. `.dockerignore` is not hygiene — it is iteration speed. Measure: `docker build --progress=plain . 2>&1 | grep -i context`.

**A8. Alpine musl vs glibc — the trap nobody warns juniors about.** Alpine uses musl libc, not glibc. You will personally hit: (1) Python packages with C extensions compile from source (slow, needs `gcc musl-dev`); (2) musl's DNS resolver behaves differently — historically serialized queries and ignored some `resolv.conf` options, causing slow DNS in Alpine containers (a known K8s saga); (3) native modules (grpc, bcrypt, sqlite3) sometimes need `libc6-compat`. Decision rule: minimal attack surface (alpine/distroless/chainguard) vs maximal compatibility (debian-slim). Know *why* you chose, per image.

### [B] Operator findings — Day-2 reality

**B1. `docker events` — the daemon's live wire.** `docker events --since 10m` answers "what just happened to my container?" — died? restarted? OOM? First tool when a container "just disappeared". Pairs with `docker inspect -f '{{.RestartCount}} {{.State.StartedAt}}'`.

**B2. Restart policies — rehearsal for ReplicaSets.** `--restart no|on-failure|always|unless-stopped`. The subtle one: after a *daemon* restart, `always` containers come back even if you had stopped them manually; `unless-stopped` respects your stop. Say out loud: "Docker restart policy is a rehearsal for Kubernetes ReplicaSets" — same self-healing instinct, smaller scale.

**B3. Housekeeping cadence for the weak machine.** Weekly: `docker system df` → prune dangling images → `docker volume ls -f dangling=true` (a dangling volume may be the database of a lab you *thought* you deleted — check before deleting). Put it in a `make tidy` target now. Disk-full on WSL kills both Docker *and* K3s (local-path PVCs live on the same disk) — one of the top 3 lab-killers.

**B4. The Windows side is part of your cluster.** `localhostForwarding=true` means Windows browser reaches WSL-published ports — until it doesn't: `wsl --shutdown` fixes ghosted forwarding; a Windows process stealing the port (`netstat -ano | findstr 8080` in PowerShell → `taskkill /PID x /F`) mimics "Docker is broken". Write both into ERRORS.md today.

**B5. Version drift rule.** The plan pins examples (alpine:3.19, postgres:16). Images move; `apk add` may fail when a repo rolls. Pin majors in labs, pin *digests* in prod (`image@sha256:...`). First lesson of supply-chain reality — and of why CI (Part 5) exists.

---

## Part 1 Exit Exam — pass in front of a blank terminal

1. Start an nginx container; from the HOST alone (no `docker inspect` hints) find its PID, its cgroup file, and its namespace links under `/proc`.
2. Start `docker run -d --name s alpine sh -c 'sleep 3600'` (shell form on purpose) and make `docker stop s` return in under 1 second. Then explain why plain `docker run -d alpine sleep 3600` (exec form) was already fast. (Hint: signal delivery, exec form vs shell form, PID 1.)
3. Produce exit codes 0, 1, 127, 137, 143 on demand and explain each in one sentence.
4. Delete a volume a running container uses; capture the exact error; recover both container and data.
5. Whiteboard to a rubber duck: image vs layer vs container vs volume vs bind mount vs registry — with arrows.
6. Your repo contains: NOTES.md for every lab done, and ERRORS.md with at least 3 documented failures with root causes.

If any item fails — that is not a setback, that is the *actual curriculum*. Fix it, log it, re-run.

Next: **Part 2 — The Compose Bridge & Kubernetes Core on K3s.**
