# Part 2 of 5 — The Compose Bridge & Kubernetes Core on K3s
### Covers: Phase 4-8 (Days 3-6) | Source: `docs/Plan/kimi_plan.md`
### Prerequisite: Part 1 Exit Exam passed. Protocol (lab notebook, break-it-first, ERRORS.md) still in force.

---
## Phase 4: Docker Compose — The Bridge to Kubernetes (Days 3-4)

Docker Compose teaches you **service-oriented thinking**. This is exactly how Kubernetes thinks.

### 4.1 The Compose Mental Model

Instead of managing individual containers, you declare a **stack** of services:

```yaml
# 01-two-tier-app/docker-compose.yml
# NOTE: no `version:` key — Compose v2 ignores it (and warns). Old tutorials still show `version: "3.9"`.

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

> ⚠ `deploy` semantics under plain `docker compose up` (verified, Compose v2): `deploy.resources.limits` (memory/cpus) **are** applied — confirm with `docker stats` showing the LIMIT column; `deploy.resources.reservations` may be silently ignored; `deploy.replicas` is **always** ignored outside Swarm (see 4.3 note). Old `docker-compose` v1 ignored the whole `deploy` block with a warning. When a limit "doesn't work", first check which Compose binary you ran (`docker compose version` vs `docker-compose --version`).

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
      hostNetwork: true
      hostPID: true            # see the HOST's processes, not the container's
      tolerations:
        - operator: Exists     # run even on tainted nodes (e.g. control-plane)
      containers:
        - name: node-exporter
          image: prom/node-exporter:v1.8.2   # pin it — :latest breaks reproducibility (see Part 5 A1)
          args:
            - --path.procfs=/host/proc   # WITHOUT these three flags + mounts below,
            - --path.sysfs=/host/sys     # node-exporter reports the CONTAINER's
            - --path.rootfs=/host/root   # /proc and /sys — a useless "node" monitor
          ports:
            - containerPort: 9100
              hostPort: 9100
              name: metrics
          volumeMounts:
            - name: proc
              mountPath: /host/proc
              readOnly: true
            - name: sys
              mountPath: /host/sys
              readOnly: true
            - name: root
              mountPath: /host/root
              mountPropagation: HostToContainer
              readOnly: true
      volumes:
        - name: proc
          hostPath:
            path: /proc
        - name: sys
          hostPath:
            path: /sys
        - name: root
          hostPath:
            path: /
```
Verify it reports the node, not the pod: `curl <node-ip>:9100/metrics | grep node_uname_info` should show the host kernel, and `node_filesystem_*` should list host mounts.

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

**Note:** HPA requires Metrics Server — but **check before you install: K3s already bundles it.**
```bash
kubectl get deploy -n kube-system metrics-server   # present on default K3s → kubectl top already works
# Only if you installed K3s with --disable=metrics-server, reinstall upstream and
# patch the deployment args with --kubelet-insecure-tls (kubelet serving certs are k3s-CA-signed):
# kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

---

## Phase 8: Kubernetes Networking & Storage (Day 6)

### 8.1 Ingress: External Access

K3s comes with Traefik by default, but we disabled it to learn manually. Install NGINX Ingress:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller/v1.10.0/deploy/static/provider/baremetal/deploy.yaml
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

On WSL, `api.localdev.me` resolves to 127.0.0.1 — but nothing listens on port 80 yet: the `baremetal` manifest exposes the controller as a **NodePort** Service (30000+ range), so a plain `http://api.localdev.me` gets connection refused. Two ways in:

```bash
# Option A — lab path: forward host port 80 straight at the controller Service
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80 &
curl -H 'Host: api.localdev.me' localhost:8080   # then http://api.localdev.me:8080 from Windows
```

```bash
# Option B — prod-feel path: let K3s's Klipper-lb (still enabled — only Traefik was disabled)
# bind real host ports 80/443 by flipping the controller Service to LoadBalancer
kubectl -n ingress-nginx patch svc ingress-nginx-controller -p '{"spec":{"type":"LoadBalancer"}}'
kubectl -n ingress-nginx get svc ingress-nginx-controller -w  # wait for EXTERNAL-IP (your node IP)
# now http://api.localdev.me works on port 80 from the Windows browser
```

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

## Part 2 Audit — What Was Missing

### Factual fixes applied to the master text during this audit

| Location | Issue | Fix |
|---|---|---|
| Phase 8.1 install URL | `.../ingress-nginx/controller-v1.10.0/...` — path is wrong; the tag lives under `controller/v1.10.0` | Corrected URL in this file. Also: on K3s/WSL prefer the `provider/baremetal` variant (NodePort + hostPort) — the `provider/cloud` manifest assumes a cloud LoadBalancer controller |
| Phase 7.4 | Plan manually installs metrics-server — **K3s already bundles metrics-server** | Do NOT double-install. First run `kubectl get deploy -n kube-system metrics-server`. If present, `kubectl top` already works. Only if you disabled it, install with `--kubelet-insecure-tls` |
| Phase 8.1 | `kubectl wait` selector uses `app.kubernetes.io/component=controller` | Also verify with `kubectl get pods -n ingress-nginx -w` — read the actual labels rather than trusting any doc (including this one) |

### [A] Architect findings — concept chains that had holes

**A1. The third probe: `startupProbe`.** The plan teaches liveness + readiness, but a slow-starting JVM gets *killed by liveness before Spring finishes booting* — day-one CrashLoopBackOff. The production trio:

```yaml
startupProbe:
  httpGet: {path: /actuator/health/liveness, port: 8080}
  failureThreshold: 30        # 30 x 10s = 5 min startup budget
  periodSeconds: 10
livenessProbe:
  httpGet: {path: /actuator/health/liveness, port: 8080}
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet: {path: /actuator/health/readiness, port: 8080}
  periodSeconds: 5
  failureThreshold: 3
```

Probe math discipline: **startup budget = failureThreshold x periodSeconds**. Once startupProbe passes once, liveness takes over — so liveness no longer needs a timid `initialDelaySeconds`. The three concerns (boot time, health, traffic-readiness) become orthogonal. This exact trio is the Spring-on-K8s production pattern.

**A2. Imperative-to-declarative workflow — the trick that doubles as a schema teacher.**

```bash
kubectl create deployment api --image=spring-api:1.0 --dry-run=client -o yaml > deployment.yaml
kubectl expose deployment api --port=80 --target-port=8080 --dry-run=client -o yaml > service.yaml
```
Generate, then *read every emitted field*, then edit into shape. You learn the API schema by diffing what you wanted vs what kubectl generates. This is also a CKA exam staple.

**A3. kubectl power moves — drill to muscle memory:**

```bash
kubectl explain deployment.spec.strategy.rollingUpdate   # offline API docs
kubectl api-resources -o wide | grep -i batch            # what kinds exist + shortnames
kubectl get pods -A --field-selector=status.phase=Failed
kubectl get pods --sort-by=.metadata.creationTimestamp
kubectl get pod -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}'
kubectl get events -A --sort-by=.lastTimestamp | tail -20   # the cluster's confession log
kubectl wait --for=condition=ready pod -l app=api --timeout=60s
kubectl diff -f manifest.yaml                            # preview BEFORE every apply
kubectl get all,cm,secret,pvc,ingress -n production      # inventory snapshot in one line
```

**A4. Rollout archaeology.**

```bash
kubectl rollout status deployment/api
kubectl rollout history deployment/api
kubectl rollout undo deployment/api                 # instant rollback
kubectl rollout undo deployment/api --to-revision=2
kubectl get rs -l app=api                           # old ReplicaSets ARE your history
```
Understand the mechanism: a Deployment revision **is** a ReplicaSet; rollback = re-pointing the selector; `revisionHistoryLimit: 3` caps the pile. Read `ownerReferences` in `kubectl get rs -o yaml` — your first taste of Kubernetes garbage collection (Deployments own ReplicaSets own Pods).

**A5. The empty-Endpoints disease.** 502 from Ingress → `kubectl get endpoints api-service` shows `<none>` → selector/label mismatch (typo, wrong namespace). Crucial insight the plan never states: **a Service name still resolves and its VIP still exists even with zero backends** — kube-proxy programs a REJECT for the empty endpoint set, so the failure surfaces as a fast refusal / 502 / timeout, not "unknown host". That signature is what points you at Endpoints instead of DNS. Memorize this diagnostic chain; you will use it weekly.

**A6. DNS rules you will use daily.** Resolution ladder: `postgres` (same namespace) → `postgres.production` → `postgres.production.svc` → FQDN `postgres.production.svc.cluster.local`. Why FQDN matters: pods get `ndots:5` in resolv.conf, so single-label names walk every search domain first — extra queries, slower failures, subtle perf cost. Cross-namespace always uses the namespace-qualified form. Verify from inside: `kubectl run -it --rm --image=busybox -- nslookup postgres.production.svc.cluster.local`.

**A7. Deletion semantics and the stuck finalizer.** `kubectl delete` is graceful: object gets a deletion timestamp; dependent resources cascade via garbage collection. `--cascade=orphan` keeps children alive (advanced migrations). THE trap: a namespace stuck in `Terminating` for hours = some resource holds a finalizer whose controller is gone. Diagnosis: `kubectl api-resources --verbs=list -o name | xargs -n1 kubectl get -A --no-headers 2>/dev/null | grep -v Running` style sweeps, then strip: `kubectl patch <res> <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`. Forbidden knowledge that saves whole clusters — use with respect, understand *why* first.

**A8. Distroless has no shell — debug differently.**

```bash
kubectl debug -it pod/spring-api-7f9c --image=busybox --target=api   # ephemeral sidecar-ish container
kubectl debug node/master-wsl -it --image=busybox -- chroot /host    # full node shell (no SSH needed!)
kubectl cp production/spring-api-7f9c:/tmp/out.txt ./out.txt         # needs tar in target — distroless fails
```
`kubectl debug` is the modern answer to "my production image has no shell and it's 2 AM".

### [B] Operator findings — Day-2 reality

**B1. initContainers — the full treatment (the plan sneaks one into Phase 9 without theory).** Legit uses: dependency TCP gate, schema-migration gate, config bootstrap (download + render templates), volume permission fix (`chown` so main container stays non-root). **Anti-pattern warning:** wait-for as your *only* readiness strategy — a TCP port opening 200ms before the data is actually ready still races. Applications must retry connections themselves and their readiness probe must reflect real dependency health. 12-factor: fail fast, crash loud, let Kubernetes restart. Pattern catalog to name aloud: *init* (run-to-completion), *sidecar* (lifetime of pod: adapters, ambassadors, log shippers), *native sidecar* K8s 1.29+ (init container with `restartPolicy: Always`).

**B2. The 12-factor mapping (why K8s feels "native" to some apps).** Config in env → ConfigMap/Secret; backing services as attached resources → Service + DNS; disposability → probes + graceful shutdown; logs to stdout ONLY (never files — the platform collects them); dev/prod parity → same image promoted through overlays. Kubernetes did not invent these rules — it enforces them.

**B3. `kubectl edit` vs `apply` state divergence.** `kubectl edit` mutates the live object with zero git trail; the next `kubectl apply` fights your edit via the `last-applied-configuration` annotation (silent partial revert — maddening). Lab rule: NEVER `kubectl edit` anything owned by git. `kubectl edit` is for ephemeral incident triage only (emergency scale-up) — and goes straight into ERRORS.md as drift to reconcile.

**B4. Tooling upgrade — do this before Part 3, it pays for itself in a day:** k9s (terminal UI: `:` command mode, `d` describe, `l` logs — learn it now), stern for multi-pod log tailing (`stern -n production spring-api`), bash completion (`source <(kubectl completion bash)`). This is the standard SRE loadout, not cheating.

---

## Part 2 Exit Exam — pass in front of a blank terminal

1. Generate Deployment + Service + Ingress YAML using ONLY `--dry-run=client -o yaml` imperative commands, apply, and curl successfully through the Ingress.
2. Kill a pod mid-rollout; narrate in order what the controller does next (watch with `kubectl get pods -w` + events).
3. Break a Service on purpose (selector typo). Diagnose using `kubectl get endpoints` only — no describe.
4. Explain liveness vs readiness vs startup to a junior; write probe YAML with correct budget math for an app that takes 90 seconds to boot.
5. Get a shell into a running **distroless** pod without changing its image.
6. From namespace `other`, show exactly why `nc -zv postgres 5432` fails and `postgres.production.svc.cluster.local` works — include the DNS queries attempted (ndots behavior).

Next: **Part 3 — The Real-World Stack.**
