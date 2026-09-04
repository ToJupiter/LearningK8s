

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

K3s is a certified Kubernetes distribution. It replaces etcd with SQLite (by default), replaces kube-proxy with a simpler implementation, and uses Flannel for CNI. It's one binary.

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

**Important K3s on WSL Note:** WSL2's virtual network interface changes IP on restart. For consistent `kubectl` access from Windows, add this to your `~/.bashrc`:

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

## Phase 4: Docker Compose — The Bridge to Kubernetes (Days 3-4)

Docker Compose teaches you **service-oriented thinking**. This is exactly how Kubernetes thinks.

### 4.1 The Compose Mental Model

Instead of managing individual containers, you declare a **stack** of services:

```yaml
# 01-two-tier-app/docker-compose.yml
version: "3.9"

services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: myapp
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app"]
      interval: 5s
      timeout: 5s
      retries: 5

  api:
    build: ./api
    environment:
      DATABASE_URL: postgres://app:secret@db:5432/myapp
    ports:
      - "8080:8080"
    networks:
      - backend
      - frontend
    depends_on:
      db:
        condition: service_healthy  # Wait for DB to be ready!
    deploy:
      resources:
        limits:
          cpus: '0.50'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 256M

  web:
    build: ./web
    ports:
      - "80:80"
    networks:
      - frontend
    depends_on:
      - api

volumes:
  pgdata:

networks:
  backend:
    driver: bridge
  frontend:
    driver: bridge
```

**Key Concepts You're Learning for Kubernetes:**
- **Services** with names resolve via DNS (`db`, `api`, `web`)
- **Networks** isolate traffic (backend vs frontend)
- **Volumes** persist data
- **Environment variables** configure apps
- **Health checks** ensure readiness
- **Resource limits** prevent starvation
- **depends_on** controls startup order

### 4.2 Compose Commands to Master

```bash
docker compose up -d          # Detached start
docker compose down           # Stop and remove
docker compose down -v        # Stop and remove volumes (DESTRUCTIVE)
docker compose ps             # Status
docker compose logs -f        # Follow logs
docker compose exec api sh    # Shell into service
docker compose build          # Rebuild images
docker compose up -d --scale api=3  # Run 3 API instances (like K8s replicas!)
```

### 4.3 The Microservices Stack Lab

Create `02-microservices-stack/docker-compose.yml` with Redis and a worker:

```yaml
services:
  redis:
    image: redis:7-alpine
    volumes:
      - redisdata:/data
    command: redis-server --appendonly yes

  api:
    build: ./api
    environment:
      REDIS_URL: redis://redis:6379
    depends_on:
      - redis

  worker:
    build: ./worker
    environment:
      REDIS_URL: redis://redis:6379
    depends_on:
      - redis
    deploy:
      replicas: 2              # Multiple workers!

volumes:
  redisdata:
```

**Observation:** `deploy.replicas` is a Docker Swarm feature, but it previews Kubernetes' ReplicaSet concept.

---

## Phase 5: The Great Migration — Mapping Compose to Kubernetes (Day 4)

Before touching kubectl, understand this mapping. It will save you weeks of confusion:

| Docker Compose | Kubernetes | Notes |
|---|---|---|
| `services` | `Deployments` + `Pods` | K8s wraps containers in Pods |
| `networks` | `Services` (ClusterIP) | K8s Services provide DNS + load balancing |
| `volumes` | `PersistentVolumeClaims` | K8s abstracts storage |
| `environment` | `ConfigMaps` / `Secrets` | K8s separates config from code |
| `depends_on` | `initContainers` | K8s has explicit init logic |
| `healthcheck` | `livenessProbe` / `readinessProbe` | K8s has two distinct probes |
| `deploy.replicas` | `replicas` in Deployment | Same concept |
| `deploy.resources` | `resources.requests/limits` | Same concept, more powerful |
| `ports` | `Service` + `Ingress` | K8s separates internal and external exposure |

**The Pod Concept:** Kubernetes doesn't run containers directly. It runs **Pods**. A Pod is the smallest deployable unit. It can contain one or more containers that share:
- Network namespace (same IP, localhost communication)
- Storage volumes
- IPC namespace

Think of a Pod as a "logical host" for your application.

---

## Phase 6: Kubernetes Foundations with K3s (Days 4-5)

### 6.1 K3s Architecture Deep Dive

Since you're running K3s, understand what you're running:

```
Your WSL2 Instance
├── k3s server (single binary!)
│   ├── kube-apiserver      # The front door. All commands go here.
│   ├── kube-controller-manager  # Maintains desired state
│   ├── kube-scheduler      # Decides which node runs which pod
│   ├── etcd (or SQLite)    # Cluster state database
│   └── containerd          # Container runtime (Docker is NOT used here!)
├── kubelet                 # Node agent. Talks to containerd.
├── kube-proxy              # Manages network rules (iptables/IPVS)
└── flannel                 # CNI plugin. Pod networking.
```

**Critical:** K3s uses **containerd**, not Docker, as the runtime. Docker builds images; containerd runs them. That's why you use `kubectl` and `crictl`, not `docker ps`, to see running containers in K3s.

```bash
# See containers through containerd (K3s's runtime)
sudo k3s crictl ps

# Equivalent of docker logs
sudo k3s crictl logs <container-id>
```

### 6.2 kubectl: Your New Best Friend

```bash
# Imperative commands (quick, but not reproducible)
kubectl run nginx --image=nginx:alpine
kubectl expose pod nginx --port=80 --type=ClusterIP

# Declarative commands (the professional way)
kubectl apply -f manifest.yaml
kubectl delete -f manifest.yaml
```

### 6.3 The Pod Manifest

Create `03-k8s-foundations/01-pods/pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
  labels:
    app: demo
    tier: frontend
spec:
  containers:
    - name: nginx
      image: nginx:alpine
      ports:
        - containerPort: 80
      resources:
        requests:
          memory: "64Mi"
          cpu: "100m"        # 0.1 CPU core
        limits:
          memory: "128Mi"
          cpu: "200m"
      env:
        - name: NGINX_HOST
          value: "localhost"
      volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
  volumes:
    - name: html
      emptyDir: {}           # Shared ephemeral storage
```

Apply and inspect:
```bash
kubectl apply -f pod.yaml
kubectl get pods -o wide
kubectl describe pod my-pod
kubectl logs my-pod
kubectl exec -it my-pod -- sh
```

### 6.4 Deployments: The Workhorse

You almost never create Pods directly. You create **Deployments**.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-deployment
spec:
  replicas: 3                # Maintain 3 copies
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1            # Add 1 extra during update
      maxUnavailable: 0      # Never drop below 3 available
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: my-api:1.0
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef:
                name: api-config
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 5
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 3
```

**Deep Understanding:**
- **livenessProbe:** "Is this container alive?" If not, K8s kills and restarts it.
- **readinessProbe:** "Is this container ready to receive traffic?" If not, it's removed from Service endpoints.
- **RollingUpdate:** Zero-downtime deployments. K8s creates new Pods, waits for readiness, then deletes old ones.

### 6.5 Services: Networking & Discovery

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-service
spec:
  selector:
    app: api          # Matches Pod labels
  ports:
    - protocol: TCP
      port: 80        # Service port
      targetPort: 8080 # Container port
  type: ClusterIP     # Internal only. Default.
```

Service types:
- **ClusterIP:** Internal cluster access only. Most common.
- **NodePort:** Exposes on each node's IP at a static port (30000-32767).
- **LoadBalancer:** Requests cloud provider load balancer (AWS ELB, etc.).
- **ExternalName:** DNS alias to external service.

### 6.6 ConfigMaps and Secrets

**ConfigMap** for non-sensitive configuration:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-config
data:
  DATABASE_HOST: "postgres"
  LOG_LEVEL: "info"
  app.properties: |
    key1=value1
    key2=value2
```

**Secret** for sensitive data (base64 encoded, not encrypted by default!):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
stringData:          # Use stringData to avoid manual base64
  username: app
  password: secret123
```

**Usage in Pods:**
```yaml
envFrom:
  - configMapRef:
      name: api-config
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-credentials
        key: password
```

---

## Phase 7: Kubernetes Workloads Deep Dive (Days 5-6)

### 7.1 StatefulSets: For Stateful Applications

Deployments are for stateless apps (API servers, web frontends). StatefulSets are for databases, message queues, anything that needs:
- Stable network identity (predictable pod names)
- Stable storage (persistent per pod)
- Ordered deployment/scaling

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: "postgres-headless"
  replicas: 1              # Start with 1 for WSL resources
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:     # Creates a PVC per pod
    - metadata:
        name: pgdata
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
```

**Headless Service** (required for StatefulSets):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-headless
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
  clusterIP: None          # Headless! DNS returns pod IPs directly.
```

### 7.2 DaemonSets: One Per Node

Runs exactly one Pod per node. Perfect for:
- Log collectors (Fluent Bit)
- Monitoring agents (Node Exporter)
- Network proxies

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      hostNetwork: true     # Access host network metrics
      containers:
        - name: node-exporter
          image: prom/node-exporter:latest
          ports:
            - containerPort: 9100
```

### 7.3 Jobs and CronJobs

**Job:** Run to completion.
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: migrate
          image: my-app:latest
          command: ["python", "manage.py", "migrate"]
```

**CronJob:** Scheduled jobs.
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup
spec:
  schedule: "0 2 * * *"    # 2 AM daily
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: backup
              image: postgres:16-alpine
              command: ["pg_dump", "-h", "postgres", "-U", "app", "mydb"]
```

### 7.4 Horizontal Pod Autoscaler (HPA)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-deployment
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

**Note:** HPA requires Metrics Server. Install it on K3s:
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# For K3s/WSL, you may need to add --kubelet-insecure-tls flag
```

---

## Phase 8: Kubernetes Networking & Storage (Day 6)

### 8.1 Ingress: External Access

K3s comes with Traefik by default, but we disabled it to learn manually. Install NGINX Ingress:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/cloud/deploy.yaml
```

Wait for the controller:
```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

Now expose services via HTTP routes:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
    - host: api.localdev.me    # Points to 127.0.0.1 automatically!
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 80
```

On WSL, access via `http://api.localdev.me` from Windows browser (since `localdev.me` resolves to 127.0.0.1).

### 8.2 Persistent Volumes & Claims

In K3s on WSL, you have a `local-path-provisioner` by default. It creates hostPath volumes.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

Use it in a Deployment:
```yaml
volumeMounts:
  - name: data
    mountPath: /var/lib/postgresql/data
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: postgres-pvc
```

**Storage Concepts:**
- **PV (PersistentVolume):** The actual storage piece (NFS, iSCSI, cloud disk).
- **PVC (PersistentVolumeClaim):** A user's request for storage.
- **StorageClass:** Defines "classes" of storage (fast SSD, slow HDD, etc.).
- **Provisioner:** Automatically creates PVs when PVCs are requested.

---

## Phase 9: The Real World Stack (Days 6-7)

Now deploy everything together. This is your capstone project.

### 9.1 Directory Structure

```
06-real-world-stack/
├── namespaces/
│   └── production.yaml
├── postgres/
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── pvc.yaml
│   ├── statefulset.yaml
│   └── service.yaml
├── redis/
│   ├── configmap.yaml
│   ├── deployment.yaml
│   └── service.yaml
├── kafka/
│   ├── kraft-combined/           # KRaft combined mode (broker+controller, WSL ideal)
│   │   ├── configmap.yaml
│   │   ├── statefulset.yaml
│   │   └── service.yaml
│   └── kraft-separated/          # KRaft separated mode (prod pattern, 3 controllers)
│       ├── controllers/
│       └── brokers/
└── spring-boot-app/
    ├── configmap.yaml
    ├── secret.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml
```

### 9.2 PostgreSQL Deployment

```yaml
# postgres/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: production
type: Opaque
stringData:
  username: "appuser"
  password: "SecureP@ssw0rd123"
```

```yaml
# postgres/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-config
  namespace: production
data:
  POSTGRES_DB: "appdb"
  PGDATA: "/var/lib/postgresql/data/pgdata"
```

```yaml
# postgres/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: production
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          envFrom:
            - configMapRef:
                name: postgres-config
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 2Gi
```

```yaml
# postgres/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: production
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
  type: ClusterIP
```

### 9.3 Redis Deployment

```yaml
# redis/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-config
  namespace: production
data:
  redis.conf: |
    maxmemory 256mb
    maxmemory-policy allkeys-lru
    appendonly yes
```

```yaml
# redis/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: production
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
          ports:
            - containerPort: 6379
          volumeMounts:
            - name: config
              mountPath: /usr/local/etc/redis
            - name: data
              mountPath: /data
          resources:
            limits:
              memory: "300Mi"
              cpu: "200m"
      volumes:
        - name: config
          configMap:
            name: redis-config
        - name: data
          emptyDir: {}          # Ephemeral for this lab. Use PVC for persistence.
```

### 9.4 Kafka in KRaft Mode (Modern, No Zookeeper — Single-Node for WSL + Prod Pattern)

> **Why KRaft, not Zookeeper?** Since Kafka 2.8 (early access), 3.x (production-ready), and **Kafka 4.0 removed Zookeeper entirely**.
> Zookeeper was a separate Java ensemble (2181/tcp) that stored topic/partition/offset metadata. It meant two
> distributed systems to operate, tune, secure, and debug. **KRaft (Kafka Raft)** replaces it with an internal
> Raft quorum of Kafka controllers that store metadata in a replicated `__cluster_metadata` log. Benefits you must
> be able to explain in an interview:
> 1. **One system to operate:** single image, single monitoring, single security model.
> 2. **Faster failover:** controller failover in seconds, 10x partition scale (millions vs hundreds of thousands).
> 3. **Simpler security:** one TLS/SASL config, no ZK ACLs + Kafka ACLs mismatch.
> 4. **Declarative topics:** `IncreasePartitionCount`, `CreateTopic` via Admin API backed by Raft log, not ZK znodes.
> 5. **Future-proof:** all new features (KIP-500, KIP-833, tiered storage) assume KRaft. Learning ZK today is learning legacy.

**KRaft mental model — three new concepts:**

```
Zookeeper mode:  Producer -> Broker -> Zookeeper (metadata) -> Broker -> Consumer
KRaft mode:      Producer -> Broker -> Controller Quorum (Raft log) -> Broker -> Consumer
```

1. **process.roles:** each Kafka JVM can be `broker`, `controller`, or `broker,controller` (combined).
   - WSL/single-node: `broker,controller` — one Pod does everything. Minimal RAM (~700Mi).
   - Prod: 3x `controller` Pods (voters) + N x `broker` Pods. Controllers form quorum, brokers store data.
2. **node.id + cluster.id:** `node.id` (was `broker.id`) must be unique per Pod. `cluster.id` is a UUID generated once
   via `kafka-storage.sh random-uuid` and shared by all nodes. Data dir must be formatted once with that UUID.
3. **Quorum voters:** `KAFKA_CONTROLLER_QUORUM_VOTERS=1@kafka-0.kafka-headless:9093,2@kafka-1...` — Raft membership.
   Listeners split: `CLIENT` (9092 for apps), `CONTROLLER` (9093 for Raft), `EXTERNAL` if needed via advertised.listeners.

**Listener anatomy you must memorize:**

```properties
KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka.production.svc.cluster.local:9092
KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER
```

- `LISTENERS` = what interface to bind. `ADVERTISED_LISTENERS` = what to tell clients to connect back to. #1 Kafka bug on K8s.
- Inside cluster clients use `kafka:9092`. Outside via Ingress/NodePort you need a separate `EXTERNAL` listener.

**Lab A — KRaft combined single-node (your WSL default):**

```yaml
# kafka/kraft-combined/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-kraft-config
  namespace: production
data:
  server.properties: |
    node.id=1
    process.roles=broker,controller
    controller.quorum.voters=1@kafka:9093
    listeners=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
    advertised.listeners=PLAINTEXT://kafka:9092
    listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
    controller.listener.names=CONTROLLER
    log.dirs=/var/lib/kafka/data
    auto.create.topics.enable=false
    offsets.topic.replication.factor=1
    transaction.state.log.replication.factor=1
    transaction.state.log.min.isr=1
```

```yaml
# kafka/kraft-combined/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: production
spec:
  selector:
    app: kafka-kraft
  ports:
    - name: client
      port: 9092
      targetPort: 9092
    - name: controller
      port: 9093
      targetPort: 9093
  type: ClusterIP
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-headless
  namespace: production
spec:
  selector:
    app: kafka-kraft
  ports:
    - name: client
      port: 9092
  clusterIP: None  # Needed for stable Raft DNS even in single-node; prepares you for 3-node scale
```

```yaml
# kafka/kraft-combined/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: production
spec:
  serviceName: kafka-headless
  replicas: 1
  selector:
    matchLabels:
      app: kafka-kraft
  template:
    metadata:
      labels:
        app: kafka-kraft
    spec:
      containers:
        - name: kafka
          image: apache/kafka:3.7.0
          ports:
            - containerPort: 9092
            - containerPort: 9093
          env:
            - name: CLUSTER_ID
              value: "MkU3OEVBNTcwNTJENDM2Qk"  # generate via: docker run apache/kafka:3.7.0 kafka-storage.sh random-uuid
            - name: KAFKA_NODE_ID
              value: "1"
            - name: KAFKA_PROCESS_ROLES
              value: "broker,controller"
            - name: KAFKA_LISTENERS
              value: "PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093"
            - name: KAFKA_ADVERTISED_LISTENERS
              value: "PLAINTEXT://kafka:9092"
            - name: KAFKA_CONTROLLER_QUORUM_VOTERS
              value: "1@kafka:9093"
            - name: KAFKA_CONTROLLER_LISTENER_NAMES
              value: "CONTROLLER"
            - name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP
              value: "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
            - name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR
              value: "1"
            - name: KAFKA_AUTO_CREATE_TOPICS_ENABLE
              value: "false"
          volumeMounts:
            - name: data
              mountPath: /var/lib/kafka/data
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
          readinessProbe:
            tcpSocket:
              port: 9092
            initialDelaySeconds: 15
            periodSeconds: 5
          livenessProbe:
            tcpSocket:
              port: 9092
            initialDelaySeconds: 30
            periodSeconds: 10
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 2Gi
```

> Apache image `apache/kafka:3.7.0` auto-formats `log.dirs` with `CLUSTER_ID` on first boot. Bitnami/Confluent images use
> different env names (`KAFKA_KRAFT_CLUSTER_ID`, `KAFKA_CFG_NODE_ID`) — always read the image docs. Never reuse a formatted
> PVC with a different CLUSTER_ID; delete PVC or you get `InconsistentClusterIdException`.

Test it:

```bash
kubectl apply -f kafka/kraft-combined/
kubectl -n production exec -it statefulset/kafka -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --create --topic orders --partitions 3 --replication-factor 1
kubectl -n production exec -it statefulset/kafka -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --describe --topic orders
# Produce/consume smoke test
kubectl -n production exec -it statefulset/kafka -- bash -c \
  "echo hello-kraft | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic orders"
kubectl -n production exec -it statefulset/kafka -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic orders --from-beginning --max-messages 1
```

**Lab B — KRaft separated 3-controller prod pattern (theory + manifest sketch for learning):**

```yaml
# Concept only — don't run on weak WSL, but understand every line
# controllers StatefulSet replicas=3, roles=controller, voters=1@kafka-controller-0:9093,2@...:9093,3@...
# brokers StatefulSet replicas=2, roles=broker, bootstrap via controllers service
# Brokers need: KAFKA_CONTROLLER_QUORUM_VOTERS pointing at controllers headless SVC
# Controllers need PVC 1Gi each, brokers PVC 10Gi each, anti-affinity across nodes/zones
```

Key differences to articulate: controllers are lightweight (CPU/RAM low, disk small, quorum latency-sensitive),
brokers are heavy (disk throughput, page cache, large heap). Scale them independently. Rolling restart controllers
first, one at a time, watching `UnderReplicatedPartitions`.

**KRaft troubleshooting matrix (memorize):**

| Symptom | Root cause | Fix |
|---|---|---|
| `InconsistentClusterIdException` | PVC formatted with old CLUSTER_ID | `kubectl delete pvc data-kafka-0 -n production` then re-apply |
| `Timeout waiting for quorum` | Wrong `CONTROLLER_QUORUM_VOTERS` DNS | `nslookup kafka-headless`, check headless Service exists |
| `Advertised listener mismatch` | Client gets `kafka:9092` but resolves outside cluster | Add EXTERNAL listener + `advertised.listeners` per Pod via env templating |
| `LEADER_NOT_AVAILABLE` on fresh topic | Auto-create disabled + no leader election yet | Wait 10s, `kafka-topics.sh --describe`, check controller logs |
| Broker OOMKilled | Heap + page cache exceed limit | Set `KAFKA_HEAP_OPTS=-Xmx512M -Xms512M`, raise memory limit to 1.5Gi |

**Spring Boot KRaft client config (no ZK dependency!):**

```properties
spring.kafka.bootstrap-servers=kafka:9092
spring.kafka.producer.acks=all
spring.kafka.producer.properties.enable.idempotence=true
spring.kafka.consumer.group-id=order-service
spring.kafka.consumer.auto-offset-reset=earliest
# No zookeeper.connect property — delete it if you copy old tutorials
```

### 9.5 Spring Boot Application

Your Spring Boot `application.properties`:
```properties
spring.datasource.url=jdbc:postgresql://postgres:5432/appdb
spring.datasource.username=${DB_USER}
spring.datasource.password=${DB_PASSWORD}
spring.redis.host=redis
spring.redis.port=6379
spring.kafka.bootstrap-servers=kafka:9092
server.port=8080
```

Dockerfile for Spring Boot (multi-stage!):
```dockerfile
# Build stage
FROM eclipse-temurin:21-jdk-alpine AS builder
WORKDIR /app
COPY .mvn/ .mvn
COPY mvnw pom.xml ./
RUN ./mvnw dependency:go-offline
COPY src ./src
RUN ./mvnw clean package -DskipTests

# Runtime stage
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=builder /app/target/*.jar app.jar
RUN addgroup -S spring && adduser -S spring -G spring
USER spring
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

Build and load into K3s (since K3s uses containerd, not Docker):
```bash
# Build with Docker
docker build -t spring-api:1.0 ./spring-boot-app

# Save and import into K3s containerd
docker save spring-api:1.0 | sudo k3s ctr images import -

# Or use a local registry (better for iterative development)
```

Kubernetes manifests for Spring Boot:

```yaml
# spring-boot-app/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: spring-config
  namespace: production
data:
  application.properties: |
    spring.datasource.url=jdbc:postgresql://postgres:5432/appdb
    spring.redis.host=redis
    spring.redis.port=6379
    spring.kafka.bootstrap-servers=kafka:9092
```

```yaml
# spring-boot-app/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spring-api
  namespace: production
spec:
  replicas: 2
  selector:
    matchLabels:
      app: spring-api
  template:
    metadata:
      labels:
        app: spring-api
    spec:
      initContainers:
        - name: wait-for-postgres
          image: busybox:1.36
          command: ['sh', '-c', 'until nc -z postgres 5432; do echo waiting for db; sleep 2; done;']
      containers:
        - name: api
          image: spring-api:1.0
          imagePullPolicy: IfNotPresent   # Critical for local images!
          ports:
            - containerPort: 8080
          env:
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: username
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: password
          volumeMounts:
            - name: config
              mountPath: /app/config
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 5
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
      volumes:
        - name: config
          configMap:
            name: spring-config
```

Deploy everything:
```bash
kubectl apply -f namespaces/production.yaml
kubectl apply -f postgres/
kubectl apply -f redis/
kubectl apply -f kafka/
kubectl apply -f spring-boot-app/

# Watch it come up
kubectl get pods -n production -w
kubectl logs -n production deployment/spring-api -f
```

---

## Phase 10: Operations & AI Supercomputer Concepts (Day 7)

### 10.1 Resource Management: The Foundation of Scale

Kubernetes schedules based on **requests** and limits via **cgroups v2** (on modern systems).

```yaml
resources:
  requests:
    memory: "1Gi"      # Guaranteed minimum. Used for scheduling.
    cpu: "500m"        # 0.5 cores. CPU is compressible.
  limits:
    memory: "2Gi"      # Hard limit. OOMKill if exceeded.
    cpu: "1000m"       # Throttled if exceeded, not killed.
```

**Critical Concept:** If a node has 4GB RAM, and you request 1GB for 5 Pods, the 5th Pod won't schedule. But if they all limit 2GB, they might OOMKill each other under pressure.

### 10.2 ResourceQuotas and LimitRanges (Multi-tenancy)

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: production
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
```

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: production
spec:
  limits:
    - default:
        cpu: "500m"
        memory: "512Mi"
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
      type: Container
```

### 10.3 AI Supercomputer Concepts (Theoretical for Your Setup)

Since you want to manage AI supercomputers, understand these K8s patterns:

**Node Affinity / Taints & Tolerations:**
```yaml
# GPU nodes are tainted: nvidia.com/gpu=true:NoSchedule
# Your AI workload must tolerate this:
tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: accelerator
              operator: In
              values: ["nvidia-tesla-a100"]
```

**Device Plugins:** Kubernetes doesn't know about GPUs natively. The NVIDIA Device Plugin advertises GPU resources to the scheduler.

**MPI Operator / Kubeflow:** For distributed AI training across hundreds of nodes. These are Custom Resource Definitions (CRDs) that extend Kubernetes.

**Network Policies:** In AI clusters, data ingestion pods shouldn't talk to training pods directly.
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow-only-ingress
spec:
  podSelector:
    matchLabels:
      app: spring-api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
```

### 10.4 Monitoring Stack (Lightweight for WSL)

Install kube-prometheus-stack (trimmed for your resources):
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.retention=2d \
  --set grafana.enabled=true \
  --set prometheus.prometheusSpec.resources.requests.memory=256Mi
```

Port-forward Grafana:
```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# Login: admin / prom-operator
```

---

## Phase 11: Git Repository & Workflow Best Practices

### 11.1 Repository Structure (Revisited)

```
k8s-mastery-lab/
├── .github/
│   └── workflows/
│       └── docker-build.yml      # CI: Build and scan images
├── apps/
│   ├── spring-api/
│   │   ├── src/
│   │   ├── Dockerfile
│   │   └── pom.xml
│   └── worker/
│       ├── src/
│       └── Dockerfile
├── infra/
│   ├── base/                     # Kustomize base manifests
│   │   ├── postgres/
│   │   ├── redis/
│   │   └── kafka/
│   └── overlays/
│       ├── local/                # K3s/WSL specific patches
│       └── staging/
├── scripts/
│   ├── setup-k3s.sh
│   ├── build-and-load.sh
│   └── port-forward-all.sh
├── docker-compose.yml            # Local dev without K8s
├── Makefile                      # Common tasks
└── README.md
```

### 11.2 Kustomize for Environment Management

Instead of duplicating YAML, use Kustomize (built into kubectl):

```yaml
# infra/overlays/local/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: production

resources:
  - ../../base/postgres
  - ../../base/redis
  - ../../base/kafka
  - ../../base/spring-api

patches:
  - target:
      kind: Deployment
      name: spring-api
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 1
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/memory
        value: 512Mi
```

Apply:
```bash
kubectl apply -k infra/overlays/local/
```

### 11.3 Makefile for Productivity

```makefile
.PHONY: build push deploy-local clean

IMAGE_TAG ?= latest
REGISTRY ?= localhost:5000

build:
	docker build -t spring-api:$(IMAGE_TAG) ./apps/spring-api

load-to-k3s: build
	docker save spring-api:$(IMAGE_TAG) | sudo k3s ctr images import -

deploy-local:
	kubectl apply -k infra/overlays/local/

port-forward:
	kubectl port-forward -n production svc/spring-api 8080:80 &
	kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80 &

clean:
	kubectl delete -k infra/overlays/local/ || true
	docker system prune -f
```

---

## Appendices

### A. WSL + K3s Troubleshooting

| Problem | Solution |
|---|---|
| `kubectl` connection refused | `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` |
| K3s fails to start | Check `sudo journalctl -u k3s -n 100`. Often iptables-legacy issue. |
| ImagePullBackOff for local image | Must use `imagePullPolicy: IfNotPresent` or import via `k3s ctr` |
| Out of memory | Reduce WSL memory, lower resource limits, use `--disable=metrics-server` if desperate |
| Port already in use | WSL shares localhost with Windows. Check `netstat -ano` on Windows. |

### B. Essential Commands Cheat Sheet

```bash
# Docker
docker build -t name:tag .
docker run -d -p 80:80 --name web --rm nginx:alpine
docker exec -it web sh
docker logs -f web
docker system prune -a

# Kubectl
kubectl get all -n production
kubectl describe pod <name>
kubectl logs -f deployment/<name>
kubectl exec -it deployment/<name> -- sh
kubectl top pod -n production
kubectl apply -f file.yaml
kubectl delete -f file.yaml
kubectl port-forward svc/name 8080:80

# K3s specific
sudo k3s ctr images ls
sudo k3s ctr images import < image.tar
sudo systemctl restart k3s
```

### C. Daily Learning Schedule (The "One Week" Intensity)

| Day | Morning (3h) | Afternoon (3h) | Evening (2h) |
|---|---|---|---|
| 1 | Docker architecture, namespaces, cgroups | Dockerfile deep dive, build/run lifecycle | Volume lab, network lab |
| 2 | Multi-stage builds, optimization | Docker Compose fundamentals | Compose microservices stack |
| 3 | Compose → K8s mapping theory | K3s setup, kubectl basics | Pod manifests, resource specs |
| 4 | Deployments, Services, Probes | ConfigMaps, Secrets, initContainers | HPA, Jobs, CronJobs |
| 5 | StatefulSets (PostgreSQL lab) | Ingress controller setup | Redis + Kafka deployment |
| 6 | Spring Boot on K8s full stack | Kustomize, Git repo structure | Monitoring stack |
| 7 | Resource quotas, network policies | AI/GPU scheduling concepts review | End-to-end testing, documentation |

### D. What to Learn Next (Post-Week Path)

1. **Helm** — Package manager for K8s. Learn to write charts.
2. **Operators** — Automate complex stateful apps (PostgreSQL Operator, Strimzi for Kafka).
3. **Service Mesh** — Istio/Linkerd for mTLS, traffic management.
4. **GitOps** — ArgoCD or Flux for declarative continuous delivery.
5. **Certifications** — CKA (Certified Kubernetes Administrator).
6. **Advanced Networking** — Cilium (eBPF), Calico policies.
7. **Real AI/ML** — Kubeflow, Ray, NVIDIA GPU Operator on a cloud cluster.

---

## Phase 12: Docker Internals — Every Corner You Must Be Able to Whiteboard (Days 7-8)

### 12.1 Namespaces Lab — See Each Isolation Live

```bash
# PID namespace: container sees itself as PID 1
docker run --rm alpine ps aux
# Compare: ps aux on host shows hundreds; inside shows handful

# NET namespace: own eth0, lo, iptables
docker run --rm --name nettest alpine sleep 3600 &
sudo ls -l /proc/$(docker inspect -f '{{.State.Pid}}' nettest)/ns/net
sudo ip link | grep veth   # veth pair bridging container to docker0

# MNT namespace: own rootfs
docker run --rm alpine ls /
docker run --rm -v /tmp:/host-tmp alpine ls /host-tmp  # punch a hole through MNT ns

# UTS: own hostname
docker run --rm --hostname mycontainer alpine hostname

# USER namespace + rootless: map container root (0) to unprivileged host UID
docker run --rm --user 1000:1000 alpine id

# Hands-on: unshare to feel namespaces without Docker
unshare --fork --pid --mount-proc bash
echo $$  # you are PID 1 in new ns!
```

Learn `nsenter`, `lsns -t net,mnt,pid`, `/proc/<pid>/ns/*`. Interview question: "Why can't `kill -9` from container kill host processes?" — PID ns + capabilities.

### 12.2 cgroups v1 vs v2 — Where Requests/Limits Actually Enforce

```bash
# Check version
stat -fc %T /sys/fs/cgroup/  # cgroup2fs = v2, tmpfs = v1
cat /proc/cgroups

# Docker translates --memory/--cpus to cgroup files:
docker run -d --name cg --memory=256m --cpus=0.5 nginx:alpine
cat /sys/fs/cgroup/system.slice/docker-*/memory.max        # v2: 268435456
cat /sys/fs/cgroup/system.slice/docker-*/cpu.max           # v2: 50000 100000
docker stats cg --no-stream

# OOM lab (must experience once):
docker run --rm --memory=50m alpine sh -c 'apk add -q stress; stress --vm 1 --vm-bytes 100M'
docker inspect cg --format '{{.State.OOMKilled}}'
dmesg | grep -i oom
```

K8s mapping: `requests.memory` -> `memory.min` reservation hint for scheduler; `limits.memory` -> `memory.max` hard cgroup cap. CPU `100m` = 0.1 core = `cpu.weight` share, throttled not killed.

### 12.3 OverlayFS, Storage Drivers, Copy-on-Write

```
LowerDir (image layers, ro) + UpperDir (container layer, rw) + WorkDir -> MergedDir (what container sees)
```

```bash
docker info | grep -A5 Storage
ls /var/lib/docker/overlay2/ | head
docker inspect nginx-test --format '{{.GraphDriver.Data}}'

# CoW demo: write to existing file triggers copy-up
docker run --rm alpine sh -c 'echo hi > /tmp/new; ls -l /tmp/new; mount | grep overlay'
```

Other drivers: `overlay2` (default, learn this), `btrfs`, `zfs`, `vfs` (slow, for testing). Why `vfs` on some WSL kernels — check `docker info`.

### 12.4 Image Distribution — Registry, Manifests, Blobs

```bash
docker pull --platform linux/amd64 nginx:alpine
docker manifest inspect nginx:alpine  # needs experimental; or use crane
docker image inspect nginx:alpine --format '{{.RepoDigests}} {{.RootFS.Layers}}'
# Each layer = gzipped tar + sha256. Content-addressable. Deduplicated across images.
```

Run a local registry (critical for K3s iterative dev):

```bash
docker run -d -p 5000:5000 --restart always --name registry registry:2
docker tag spring-api:1.0 localhost:5000/spring-api:1.0
docker push localhost:5000/spring-api:1.0
curl localhost:5000/v2/_catalog
```

Then K3s `registries.yaml` mirror:

```yaml
# /etc/rancher/k3s/registries.yaml
mirrors:
  "localhost:5000":
    endpoint:
      - "http://192.168.x.x:5000"  # WSL host IP, not localhost from K3s netns!
```

### 12.5 Dockerfile Exhaustive Reference — Every Instruction

- `FROM [--platform] image[:tag][@digest] [AS name]` — pin digests in prod. `scratch`, `alpine`, `distroless`, `chainguard`.
- `ARG` vs `ENV`: ARG is build-time only, ENV persists to runtime. `ARG VERSION=dev` before FROM is global.
- `RUN` shell vs exec form. Shell runs `/bin/sh -c`. Exec `RUN ["apt-get",...]` avoids shell string munging.
- `COPY [--chown=user:group] [--chmod=755] [--from=stage]` vs `ADD` (ADD auto-extracts tar + fetches URLs — avoid, use COPY + curl).
- `ENTRYPOINT` vs `CMD`: ENTRYPOINT is the binary, CMD are default args. Override rules: `docker run img arg` replaces CMD, `--entrypoint` replaces ENTRYPOINT.
- `HEALTHCHECK --interval=30s --timeout=3s CMD curl -f http://localhost/ || exit 1` — maps to K8s probes.
- `ONBUILD`, `STOPSIGNAL` (must be SIGTERM for graceful K8s termination!), `SHELL`, `VOLUME`, `WORKDIR`, `USER`, `EXPOSE`, `LABEL`.
- BuildKit superpowers:

```dockerfile
# syntax=docker/dockerfile:1
FROM golang:1.22 AS build
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=secret,id=github_token \
    go build -o /app .
COPY --chmod=755 entrypoint.sh /entrypoint.sh
```

```bash
DOCKER_BUILDKIT=1 docker build --secret id=github_token,src=$HOME/.github_token --progress=plain .
docker build --target builder -t app:debug .
```

Lint with Hadolint, scan with `docker scout`, `trivy image`, `grype`. Sign with Cosign. Generate SBOM: `docker sbom`.

### 12.6 Docker Security Deep Dive

1. **Capabilities:** Docker drops most Linux caps by default. `--cap-add=NET_ADMIN` vs `--privileged` (gives all + devices — never in prod).
   `capsh --print`, `docker inspect --format '{{.HostConfig.CapAdd}}'`.
2. **Seccomp/AppArmor:** `docker run --security-opt seccomp=unconfined`, `--security-opt apparmor=...`. Default profiles block 300+ syscalls.
3. **Read-only + no-new-privs:**
   ```bash
   docker run --read-only --tmpfs /tmp --tmpfs /run -u 65532 nginx:alpine
   docker run --security-opt=no-new-privileges:true myapp
   ```
4. **User namespaces / rootless:** `/etc/subuid`, `dockerd --userns-remap=default`. Root in container != root on host.
5. **Secrets, not ENV:** `docker run --env-file .env`, BuildKit secrets, never `ENV PASSWORD` in image history. Check leak: `docker history --no-trunc`.
6. **Resource abuse:** always set `--memory --cpus --pids-limit` — maps directly to K8s LimitRange thinking.

---

## Phase 13: K3s Internals — The Single Binary Deconstructed (Days 8-9)

### 13.1 What Exactly Is Inside `k3s server`?

```
k3s (single Go binary ~100MB)
├── apiserver + controller-manager + scheduler (k8s control plane, stripped cloud providers)
├── kine (shim: translates etcd API to SQLite/Postgres/MySQL) — this is why K3s can run without etcd!
├── containerd (embedded, CRI plugin enabled) + runc + cni plugins
├── flannel (VXLAN by default) + kube-proxy (iptables) + CoreDNS + metrics-server + local-path-provisioner
├── klipper-lb (ServiceLB: DaemonSet that binds NodePort to host for LoadBalancer Services on bare metal/WSL)
└── helm-controller (applies HelmChart CRDs from /var/lib/rancher/k3s/server/manifests automatically)
```

Inspect:

```bash
sudo systemctl cat k3s
ps aux | grep -E 'k3s|containerd|kubelet'
sudo ls /var/lib/rancher/k3s/server/{manifests,db}  # db/state.db is SQLite! manifests are auto-applied YAML
sudo cat /etc/rancher/k3s/config.yaml  # create this to persist flags instead of CLI args
kubectl get pods -A  # coredns, local-path-provisioner, metrics-server, traefik (if not disabled)
```

### 13.2 Datastore Options — SQLite vs etcd vs Postgres

| Backend | Flag | When |
|---|---|---|
| SQLite (default) | (none) | Single node, WSL, edge. Single-writer, file `/var/lib/rancher/k3s/server/db/state.db`. Backup = copy file. |
| etcd (embedded HA) | `--cluster-init` | 3+ servers, HA. Real Raft. `etcdctl` via `k3s etcd-snapshot`. |
| External Postgres/MySQL | `--datastore-endpoint postgres://...` | Central DB team, existing backup story. Kine translates. |

```bash
# Backup/restore SQLite single-node:
sudo k3s etcd-snapshot save --help  # works even on SQLite via kine snapshot abstraction
sudo cp /var/lib/rancher/k3s/server/db/state.db /backup/
# HA etcd snapshot:
sudo k3s etcd-snapshot save /tmp/snap.db
sudo k3s etcd-snapshot restore /tmp/snap.db
```

### 13.3 Flannel CNI Packet Walk (Must Be Able to Draw)

```
PodA (10.42.0.5, node1) -> eth0 -> veth -> cni0 bridge -> flannel.1 (VXLAN encap, VNI 1, UDP 8472) -> eth0 node1 -> eth0 node2 -> flannel.1 (decap) -> cni0 -> veth -> PodB (10.42.1.7)
```

```bash
kubectl get nodes -o wide  # podCIDR per node: 10.42.0.0/24, 10.42.1.0/24
ip -d link show flannel.1
bridge fdb show | grep flannel
kubectl -n kube-system logs -l app=flannel
# Backends: vxlan (default, portable), host-gw (fast, needs L2 adjacency), wireguard-native (encrypted)
# Change: --flannel-backend=wireguard-native
```

Flannel limitations: no NetworkPolicy enforcement! For policy need Calico/Cilium as replacement (`--flannel-backend=none --disable-network-policy` + install Cilium). Know this tradeoff.

### 13.4 kube-proxy iptables Walk + Klipper-LB + Traefik

```bash
kubectl get svc -A
sudo iptables -t nat -L KUBE-SERVICES -n | head -20
sudo iptables -t nat -L KUBE-SVC-XXX -n
ipvsadm -Ln  # if --kube-proxy-arg proxy-mode=ipvs
kubectl -n kube-system logs -l app=klipper-lb  # one Pod per node binding 80/443 for LoadBalancer Services
```

K3s defaults: Traefik Ingress + ServiceLB. You disabled Traefik to learn NGINX — understand both. Traefik reads `Ingress` + `IngressRoute` CRDs; NGINX reads `Ingress` + annotations.

### 13.5 K3s Config Files You Must Master

```yaml
# /etc/rancher/k3s/config.yaml
write-kubeconfig-mode: "0644"
disable:
  - traefik
  - servicelb  # if you don't want Klipper
node-name: master-wsl
cluster-init: false
token-file: /etc/rancher/k3s/token
kubelet-arg:
  - "eviction-hard=memory.available<200Mi"
  - "max-pods=110"
```

```bash
sudo k3s check-config  # kernel modules/cgroups sanity
sudo k3s crictl --help
sudo k3s ctr images ls | head
sudo k3s kubectl get nodes  # embedded kubectl
```

Multi-node lab (when you have second machine/VM): `k3s server --cluster-init --token SECRET` on first, `k3s agent --server https://<ip>:6443 --token SECRET` on workers. Token in `/var/lib/rancher/k3s/server/node-token`.

---

## Phase 14: Kubernetes Objects Exhaustive — Beyond Deployments (Days 9-10)

### 14.1 Pod Lifecycle, QoS, Eviction, Disruption

- **Phases:** Pending -> ContainerCreating -> Running -> Succeeded/Failed. `kubectl get pod -w`, `kubectl describe`, `kubectl get events --sort-by=.lastTimestamp`.
- **QoS classes (inspect via `kubectl describe`):**
  - Guaranteed: requests==limits for all containers. Last to be evicted. Use for postgres/kafka.
  - Burstable: requests<limits. Middle.
  - BestEffort: no requests/limits. First to die under pressure. Never for prod.
- **OOMKilled (exit 137) vs Evicted vs CrashLoopBackOff:** OOM = exceeded memory limit. Evicted = node pressure (disk/memory). CrashLoop = app exits repeatedly (check `logs --previous`).
- **Graceful shutdown chain:** `SIGTERM` -> `preStop` hook -> `terminationGracePeriodSeconds` (30s default) -> `SIGKILL`. Spring Boot must handle SIGTERM (`server.shutdown=graceful`, `STOPSIGNAL SIGTERM`).
- **PDB (PodDisruptionBudget):** protects voluntary disruptions (drain/upgrade):

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-pdb
  namespace: production
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: spring-api
```

- **Native sidecars (K8s 1.29+):** `restartPolicy: Always` initContainers stay running (log shippers, proxies). Distinguish from ephemeral `kubectl debug`.

### 14.2 Scheduling: Affinity, Taints, Topology, Priority

```yaml
# Must-know snippet — combine all in one Deployment and explain each line
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector: {matchLabels: {app: postgres}}
      topologyKey: kubernetes.io/hostname  # co-locate with DB for latency
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector: {matchLabels: {app: spring-api}}
        topologyKey: kubernetes.io/hostname  # spread replicas across nodes
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: ScheduleAnyway
  labelSelector: {matchLabels: {app: spring-api}}
tolerations:
- key: workload
  operator: Equal
  value: ai-training
  effect: NoSchedule
priorityClassName: high-priority
```

Taint a node: `kubectl taint nodes node1 workload=ai-training:NoSchedule`, remove with `-` suffix. Cordon/drain: `kubectl cordon`, `kubectl drain --ignore-daemonsets --delete-emptydir-data`.

### 14.3 Workload Controllers Matrix

| Kind | Use | Pod identity | Update |
|---|---|---|---|
| Deployment+ReplicaSet | Stateless API/web | Random hash suffix | RollingUpdate maxSurge/maxUnavailable |
| StatefulSet | DB/Kafka/Redis-cluster | Ordinal `web-0,1,2`, stable DNS | Ordered, partition, OnDelete |
| DaemonSet | Log/monitor per node | One per node | RollingUpdate maxUnavailable |
| Job | Migration/backup once | `job-xxxxx` | backoffLimit, activeDeadlineSeconds, ttlSecondsAfterFinished |
| CronJob | Nightly dump | Timestamped | schedule (cron + timezone), concurrencyPolicy Forbid/Allow/Replace, startingDeadlineSeconds |
| HPA | Autoscale replicas | — | CPU/mem/custom/external metrics |
| VPA | Right-size requests | — | Off/Initial/Auto (don't combine HPA on same metric!) |

StatefulSet deep flags: `podManagementPolicy: OrderedReady vs Parallel`, `updateStrategy.rollingUpdate.partition`, `persistentVolumeClaimRetentionPolicy: Retain/Delete`.

CronJob example with timezone (K8s 1.27+):

```yaml
spec:
  schedule: "0 2 * * *"
  timeZone: "Asia/Ho_Chi_Minh"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      ttlSecondsAfterFinished: 3600
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: dump
            image: postgres:16-alpine
```

### 14.4 Configuration: ConfigMaps/Secrets/Downward/Projected

- Mount as env vs volume: env requires restart to pick up changes; volume updates kubelet-synced (~1min) without restart.
- `immutable: true` ConfigMaps for performance + safety.
- Secrets: base64 != encryption! Enable at-rest: `--secrets-encryption` on K3s server. Better: SealedSecrets (Bitnami), ExternalSecrets Operator (Vault/AWS SM), SOPS.
- Projected volume combines secret+configMap+downwardAPI+serviceAccountToken in one mount.
- Downward API: expose pod name/namespace/resources as env/files without hardcoding.

### 14.5 RBAC + ServiceAccounts + Pod Security

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: {name: api-sa, namespace: production}
automountServiceAccountToken: false  # harden if app doesn't need API
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: pod-reader, namespace: production}
rules: [{apiGroups: [""], resources: ["pods","configmaps"], verbs: ["get","list"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: api-binding, namespace: production}
subjects: [{kind: ServiceAccount, name: api-sa, namespace: production}]
roleRef: {kind: Role, name: pod-reader, apiGroup: rbac.authorization.k8s.io}
```

Debug: `kubectl auth can-i list pods --as=system:serviceaccount:production:api-sa -n production`.
Pod Security Standards: label namespaces `pod-security.kubernetes.io/enforce: restricted`. Restricted requires `runAsNonRoot, seccompProfile RuntimeDefault, no privileged, drop ALL caps`.

---

## Phase 15: Networking + Storage Exhaustive (Days 10-11)

### 15.1 Service Discovery Deep: DNS, Endpointslices, Headless

```bash
kubectl run dns -it --rm --image=busybox -- nslookup kubernetes.default
kubectl run dns -it --rm --image=busybox -- nslookup postgres.production.svc.cluster.local
kubectl get endpointslices -n production -o yaml  # modern Endpoints, one per 100 endpoints
kubectl get svc postgres -o yaml  # ClusterIP stable VIP, kube-proxy programs it
```

- ClusterIP: `svc:port` -> `podIP:targetPort` via iptables DNAT. SessionAffinity ClientIP for sticky.
- Headless (`clusterIP: None`): DNS returns Pod IPs directly (A records per Pod + SRV). Required for StatefulSet quorum (Kafka KRaft voters, Postgres Patroni).
- `publishNotReadyAddresses: true` for Raft bootstrap before readiness.

### 15.2 Ingress vs Gateway API + TLS + cert-manager

Ingress (stable, simple) vs Gateway API (new standard: GatewayClass/Gateway/HTTPRoute/GRPCRoute — role-separated, header matching, traffic splitting).

```yaml
# Gateway API example (install Cilium/Traefik/NGINX Gateway controller first)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: api-route, namespace: production}
spec:
  parentRefs: [{name: prod-gateway}]
  hostnames: ["api.localdev.me"]
  rules:
  - matches: [{path: {type: PathPrefix, value: /v1}}]
    backendRefs: [{name: spring-api, port: 80, weight: 90},{name: spring-api-canary, port: 80, weight: 10}]
```

TLS: create `tls` Secret, reference in Ingress `spec.tls`, automate with cert-manager ClusterIssuer (Let's Encrypt) + Certificate CRD. On WSL use self-signed + `mkcert`.

### 15.3 NetworkPolicy — Default Deny + Allow-List

```yaml
# Default deny all ingress in namespace (apply first!)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny, namespace: production}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-api-from-ingress, namespace: production}
spec:
  podSelector: {matchLabels: {app: spring-api}}
  policyTypes: [Ingress, Egress]
  ingress:
  - from: [{namespaceSelector: {matchLabels: {name: ingress-nginx}}, podSelector: {matchLabels: {app.kubernetes.io/name: ingress-nginx}}}]
    ports: [{port: 8080, protocol: TCP}]
  egress:
  - to: [{podSelector: {matchLabels: {app: postgres}}}]  # only DB
    ports: [{port: 5432}]
  - to: [{namespaceSelector: {}, podSelector: {matchLabels: {k8s-app: kube-dns}}}]  # allow DNS!
    ports: [{port: 53, protocol: UDP}]
```

Flannel ignores this — you must switch CNI to Cilium/Calico to enforce. Test with `kubectl run netshoot --rm -it --image=nicolaka/netshoot -- curl postgres:5432`.

### 15.4 Storage Deep: PV/PVC/StorageClass/CSI/Snapshots

Lifecycle: `Available -> Bound -> Released -> (Retain: manual reclaim / Delete: auto-delete)`. AccessModes: RWO (one node rw), ROX, RWX (many nodes, needs NFS/Ceph), RWOP (pod-per-node). VolumeModes: Filesystem vs Block.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: fast-ssd}
provisioner: rancher.io/local-path  # K3s default; prod: ebs.csi.aws.com, pd.csi.storage.gke.com
volumeBindingMode: WaitForFirstConsumer  # delay provisioning until scheduled (topology-aware)
allowVolumeExpansion: true
reclaimPolicy: Delete
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: {name: pg-snap, namespace: production}
spec:
  volumeSnapshotClassName: csi-snapclass
  source: {persistentVolumeClaimName: data-postgres-0}
```

K3s local-path-provisioner internals: watches PVC -> creates hostPath PV at `/var/lib/rancher/k3s/storage/<pvc>-<rand>`. No capacity enforcement, no multi-node migration. For learning RWX install `nfs-subdir-external-provisioner` or Longhorn (`helm install longhorn`). Backup PVC data: `kubectl cp`, `restic`, Velero.

EmptyDir nuances: `medium: Memory` = tmpfs (fast, counts against memory limit!), default = node disk. `sizeLimit` triggers eviction.

## Phase 16: Container Runtimes — Docker vs containerd vs CRI-O (Day 11)

### 16.1 CRI: Why K3s Doesn't Use Docker

```
Docker CLI -> dockerd -> containerd -> runc -> container
K3s: kubelet -> CRI (gRPC) -> containerd (CRI plugin) -> runc -> container
```

Docker has extra UX (build, compose, swarm) that kubelet doesn't need. Kubernetes defines CRI (Container Runtime Interface); any CRI-compatible runtime works. K3s embeds containerd. Debug with `crictl`, not `docker`:

```bash
sudo k3s crictl ps -a
sudo k3s crictl images | head
sudo k3s crictl logs --tail 50 <container-id>
sudo k3s crictl inspect <container-id>
crictl vs docker vs nerdctl (containerd-native CLI) vs podman (daemonless, fork-exec)
```

Image loading workflow for local dev:

```bash
# Option A: import tarball (simple, WSL-friendly)
docker build -t spring-api:1.0 ./apps/spring-api
docker save spring-api:1.0 -o /tmp/img.tar
sudo k3s ctr images import /tmp/img.tar
sudo k3s ctr images ls | grep spring

# Option B: local registry + registries.yaml (iterative, no re-import)
docker run -d -p 5000:5000 --name registry registry:2
# push to <windows-host-ip>:5000, reference in Deployment image: <ip>:5000/spring-api:1.0

# Option C: k3s private dir (airgap): place tarballs in /var/lib/rancher/k3s/agent/images/ (*.tar auto-imported on boot)
```

### 16.2 Build Tools Compared

- Docker BuildKit: `docker buildx build --platform linux/amd64,linux/arm64 -t ... --push .` (multi-arch for ARM edge + AMD cloud).
- Kaniko/Jib/Buildpacks: build without Docker daemon (useful in CI Pods). Spring Boot: `mvn spring-boot:build-image` uses Buildpacks -> OCI image, no Dockerfile!
- Dive into layers: `dive spring-api:1.0`, `crane ls`, `skopeo copy docker://...`.

---

## Phase 17: Observability Exhaustive — Logs, Metrics, Traces (Days 11-12)

### 17.1 Logging Architecture

```
App stdout/stderr -> containerd json-file log (/var/log/pods/<ns>_<pod>_<uid>/<container>/*.log) -> kubelet -> kubectl logs
                                                                                              -> FluentBit DaemonSet -> Loki/Elastic -> Grafana
```

```bash
kubectl logs -n production deployment/spring-api -c api --tail=100 -f
kubectl logs -n production deployment/spring-api --previous  # crashed container!
kubectl logs -n production -l app=spring-api --all-containers --prefix
sudo ls /var/log/pods/ | head
sudo k3s crictl logs --tail 20 <id>
# Log rotation: kubelet --container-log-max-size=10Mi --container-log-max-files=5 (set via kubelet-arg in K3s config)
```

Structured JSON logs + correlation IDs (`traceId` in MDC) are mandatory for microservices. Sidecar vs DaemonSet vs direct-push debate — DaemonSet wins for resource efficiency.

Install Loki stack (lightweight for WSL):

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack -n monitoring --set grafana.enabled=true,prometheus.enabled=false
kubectl port-forward -n monitoring svc/loki-grafana 3000:80
# LogQL: {namespace="production", app="spring-api"} |= "ERROR"
```

### 17.2 Metrics: Metrics-Server vs Prometheus vs Grafana

- Metrics Server: in-memory CPU/mem for `kubectl top`, HPA. `kubectl top pod -n production --containers --sort-by=cpu`.
- kube-state-metrics: object state (replicas desired vs available, PVC phase). Prometheus scrapes it.
- node-exporter DaemonSet: host CPU/disk/inode.
- Spring Boot: Micrometer + Prometheus registry (`management.endpoints.web.exposure.include=health,info,prometheus,metrics`), ServiceMonitor CRD:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: {name: spring-monitor, namespace: monitoring}
spec:
  selector: {matchLabels: {app: spring-api}}
  endpoints: [{port: http, path: /actuator/prometheus, interval: 15s}]
```

PromQL must-knows: `rate(http_server_requests_seconds_count[5m])`, `histogram_quantile(0.95, ...)`, `kube_pod_container_status_restarts_total`, `container_memory_working_set_bytes`.

### 17.3 Tracing + Profiling

OpenTelemetry sidecar/exporter -> Tempo/Jaeger. Spring Boot: `opentelemetry-instrumentation-java` agent. Continuous profiling: Pyroscope. eBPF profilers need privileged DaemonSet — understand why.

---

## Phase 18: Helm, Kustomize, GitOps — Real Team Workflows (Days 12-13)

### 18.1 Helm Deep (Charts Are Templates + Values)

```
mychart/
├── Chart.yaml (name, version, appVersion, dependencies)
├── values.yaml (defaults)
├── values-prod.yaml (overrides)
└── templates/
    ├── deployment.yaml ({{ .Values.replicaCount }}, {{ .Values.image.tag }})
    ├── service.yaml
    └── _helpers.tpl
```

```bash
helm template myrel ./mychart --values values-prod.yaml | kubectl apply -f -
helm install postgres bitnami/postgresql -n production --set auth.password=secret,primary.persistence.size=2Gi
helm upgrade --install spring ./charts/spring -n production --create-namespace --wait --atomic
helm rollback spring 1
helm list -A; helm history spring
# K3s bonus: drop chart YAML into /var/lib/rancher/k3s/server/manifests as HelmChart CR -> auto-deploys!
```

Write helpers, use `required`, `default`, `tpl`, checksum annotations to restart Pods on ConfigMap change. Helm vs Kustomize: Helm = templating + release management; Kustomize = patch overlays without templates (better for GitOps diffs).

### 18.2 Kustomize Components + Overlays Full Example

```yaml
# base/kustomization.yaml
resources: [postgres/, redis/, kafka-kraft/, spring-api/]
commonLabels: {managed-by: kustomize, env: base}
# overlays/local/kustomization.yaml
namespace: production
resources: [../../base]
replicas: [{name: spring-api, count: 1}]
patches:
- target: {kind: StatefulSet, name: kafka}
  patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/resources/limits/memory
      value: 768Mi
images: [{name: spring-api, newName: 192.168.1.10:5000/spring-api, newTag: dev}]
configMapGenerator: [{name: extra-env, literals: [LOG_LEVEL=debug]}]
secretGenerator: [{name: db-pass, literals: [password=devonly]}]
```

`kubectl diff -k`, `kubectl apply -k`, `kustomize build --enable-helm`.

### 18.3 GitOps with ArgoCD (The Prod Standard)

Install on K3s (lightweight HA off):

```bash
kubectl create ns argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl port-forward -n argocd svc/argocd-server 8081:443
# Application CR watches git -> syncs to cluster, self-heals, prunes
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: prod-stack, namespace: argocd}
spec:
  project: default
  source: {repoURL: https://github.com/you/k8s-mastery-lab, targetRevision: main, path: infra/overlays/local}
  destination: {server: https://kubernetes.default.svc, namespace: production}
  syncPolicy: {automated: {prune: true, selfHeal: true}}
```

Flux alternative: `GitRepository` + `Kustomization` CRDs. SealedSecrets/ExternalSecrets for git-safe secrets. Image Updater for auto-bumping tags.

### 18.4 CI Pipeline (GitHub Actions Sketch)

`.github/workflows/ci.yaml`: lint (hadolint, kube-linter, kubeconform) -> build (buildx) -> scan (trivy, fail on CRITICAL) -> push (GHCR) -> update overlay tag -> ArgoCD syncs. Never `kubectl apply` from CI with cluster-admin; use deploy keys + least-privilege SA.

---

## Phase 19: Production Hardening + Troubleshooting Playbook (Days 13-14)

### 19.1 Troubleshooting Flowchart (Tattoo This)

```
Pod not Ready?
├── kubectl describe pod -> Events (FailedScheduling? ImagePullBackOff? CrashLoop?)
├── kubectl logs / logs --previous
├── kubectl exec -it -- sh (env? DNS? curl service?)
├── kubectl get events --sort-by=.lastTimestamp -n <ns>
├── Node? kubectl describe node (Pressure? Allocatable? Taints?)
└── CNI/CSI? journalctl -u k3s, dmesg, crictl ps
```

Error catalog:

| Error | Meaning | Commands |
|---|---|---|
| ImagePullBackOff/ErrImagePull | Wrong tag, private registry, no imagePullSecret | `crictl images`, check `imagePullPolicy`, create `docker-registry` secret |
| CrashLoopBackOff | App exits (code!=0) | `logs --previous`, `describe` exit code, check probes killing healthy app |
| OOMKilled 137 | Over memory limit | `top pod --containers`, raise limit, fix leak, check JVM heap |
| Pending/Unschedulable | No node fits requests/taints/PVC topology | `describe` events, `kubectl describe node`, check ResourceQuota |
| Liveness killed | Probe too aggressive | Raise initialDelay, use `/actuator/health/liveness` not `/` |
| Readiness never true | App can't reach DB/Kafka | `exec` + `nc -zv postgres 5432`, check NetworkPolicy DNS |
| PVC Pending | No StorageClass/provisioner | `kubectl get sc,pvc,pv`, `describe pvc`, check local-path-provisioner logs |
| 502 via Ingress | Service selector wrong / Pod not ready | `kubectl get endpoints`, `describe svc`, `logs ingress-controller` |

Chaos drills to run on WSL: `kubectl delete pod` (self-heal?), `docker stop` containerd? (no — `systemctl kill k3s`), fill disk (`dd`), kill -9 Java (graceful?), scale to 0 and back, drain node.

### 19.2 Security + Resource Governance Checklist

- Namespaces per team/env + ResourceQuota + LimitRange + NetworkPolicy default-deny.
- Pod Security `restricted`, readOnlyRootFilesystem, runAsNonRoot 65532, drop ALL, seccomp RuntimeDefault.
- Secrets encrypted at rest + rotation (ExternalSecrets refreshInterval) + no secrets in logs (`kubectl describe` hides? No — base64 visible!).
- Image policy: pinned digests, scanned, signed (Cosign + Kyverno `require-signature`), pull from allow-list registries.
- API hardening: disable anonymous, audit logs (`--audit-log-path`), RBAC least privilege, no cluster-admin for CI.
- Backups: Velero + Restic for PVCs, `k3s etcd-snapshot s3` for control plane, Git as source of truth for manifests.

---

## Phase 20: AI Supercomputer on K8s — From WSL Theory to Real GPUs (Days 14-15)

### 20.1 GPU Scheduling Primitives

```yaml
# Request GPUs like CPU/mem — but extended resource, must be integer, limits==requests
resources:
  limits: {nvidia.com/gpu: 1}
  requests: {nvidia.com/gpu: 1}
tolerations: [{key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}]
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions: [{key: nvidia.com.gpu.product, operator: In, values: [NVIDIA-A100-80GB]}]
```

Stack: NVIDIA GPU Operator (driver + device-plugin + DCGM exporter DaemonSets) -> `nvidia-smi` in Pod -> NCCL tests. MIG slices one A100 into 7x `1g.5gb` (`nvidia.com/mig-1g.5gb: 1`). Time-slicing shares one GPU across Pods (not for training, ok for inference). MPS for multi-process sharing.

RDMA/InfiniBand: SR-IOV + Multus (multiple CNI: default Flannel + `ib0` via `ib-sriov-cni`), Topology Manager `single-numa-node` + CPUManager `static` for locality. NCCL env: `NCCL_IB_DISABLE=0`, `NCCL_SOCKET_IFNAME=ib0`.

### 20.2 Distributed Training Operators

- Kubeflow Training Operator: `PyTorchJob` (master+workers, `elasticPolicy`), `TFJob`, `MPIJob` (Horovod, `slotsPerWorker: 8`).
- Volcano/Kueue: gang scheduling (all-or-nothing — don't start 7/8 workers!), queues, preemption, fair-sharing across teams. `minMember: 8, minTaskMembers`.
- RayCluster/KubeRay: Ray Train/Tune/Serve for LLM workflows, autoscaling workerGroups.
- Data: checkpoint to fast parallel FS (Lustre/Weka/CephFS/JuiceFS CSI), not local-path! PVC `ReadWriteMany` + ` стане` snapshot before preemption. HuggingFace cache as PVC or S3 (s3-csi).
- Observability: DCGM `DCGM_FI_DEV_GPU_UTIL`, NCCL timeout logs, TensorBoard sidecar, W&B operator.

Try on CPU-only WSL to learn API shapes: install Training Operator, submit tiny `PyTorchJob` with 2 workers doing `torch.distributed` hello-world. Manifests transfer 1:1 to GPU cluster.

### 20.3 Inference + Finetuning Stack Sketch

vLLM/TGI Deployment + HPA on GPU util/custom queue length (KEDA `prometheus` scaler) + Service + HTTPRoute weight split canary + model PVC (initContainer downloads weights) + spot/preemptible tolerations + PDB `maxUnavailable: 0` for serving. Quantization (AWQ/GPTQ) trades VRAM for throughput — same K8s YAML, different image args.

---

## Phase 21: Capstone — Ship It Like Prod + What Next

### 21.1 Final Project Acceptance Criteria

1. `git clone` fresh -> `make deploy-local` -> all Pods Ready in `production`, Ingress answers `http://api.localdev.me/health`.
2. `kubectl -n production exec deploy/spring-api -- curl -s postgres:5432` fails gracefully, logs show connection handling (proves NetworkPolicy + error handling).
3. Kill `kafka-0`: topic `orders` survives (PVC retained), consumer resumes from committed offset (proves KRaft + persistence).
4. `kubectl top` shows no Pod at 95%+ limits; HPA scales `spring-api` 2->4 under `hey -z 60s -c 20` load.
5. `trivy image` shows 0 CRITICAL, `kube-linter` passes, image runs as non-root read-only.
6. ArgoCD Application green, `git push` new image tag auto-syncs (or `kubectl apply -k` diff clean).

### 21.2 Extended Schedule (Beyond One Week)

| Week | Focus |
|---|---|
| 2 | Helm charts for each service, SealedSecrets, NetworkPolicies enforced with Cilium (replace Flannel) |
| 3 | Prometheus alerts + Loki dashboards, chaos drills, Velero backups, upgrade K3s minor version |
| 4 | ArgoCD + Image Updater, staging/prod overlays, CKA mock exams (killer.sh) |

### 21.3 Certification + Career Path

CKA (admin: debug, upgrade, etcd), CKAD (workloads, probes, ConfigMaps), CKS (PSP/OPA, seccomp, network policy, image signing). From there: Cilium CNI + Hubble, Istio ambient mesh, Karpenter autoscaling, Kubeflow/MLOps, platform engineering (IDP with Backstage).

## Final Words

You now possess a mental model that connects the Linux kernel (namespaces, cgroups) to Docker (user-friendly isolation) to Docker Compose (multi-service declaration) to Kubernetes (distributed automation). Every concept in Kubernetes is a natural evolution of a Docker concept, scaled and formalized.

Your WSL + K3s environment, despite being resource-constrained, runs the **exact same** Kubernetes API as a 1000-node AI supercomputer cluster. The manifests you write today will work on AWS EKS, Google GKE, or an on-premise GPU cluster tomorrow. The only differences are scale, storage classes, and node types.

**Build the repo. Break things. Read `kubectl describe`. Check logs. That's how you learn.** The depth you've gained here isn't about memorizing commands—it's about understanding the architecture. From here, every new tool (Helm, Istio, ArgoCD, Kubeflow) is just another layer on this solid foundation.

Welcome to the world of cloud-native infrastructure. Your journey into managing AI supercomputers starts with this single node in WSL.