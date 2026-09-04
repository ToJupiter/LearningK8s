# Part 4 of 5 — Internals: Docker, K3s, Runtimes & Observability at Whiteboard Level
### Covers: Phase 12-17 (Days 7-12) | Source: `docs/Plan/kimi_plan.md`
### Prerequisite: Part 3 Exit Exam passed. This is the part where you stop using Kubernetes and start being able to *explain* it — the difference between an operator and an engineer.

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

# OOM lab (must experience once — note: NO --rm, or the evidence deletes itself):
docker run --name oomvic --memory=50m alpine sh -c 'apk add -q stress; stress --vm 1 --vm-bytes 100M'; echo "exit=$?"
docker inspect oomvic --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}}'  # expect true / 137
docker rm oomvic
dmesg | grep -i oom
```

K8s mapping (defaults — check `kubectl version` before assuming; this area changed recently): `requests.memory` is scheduler + QoS/eviction input ONLY — the kernel never sees it. `limits.memory` -> `memory.max` hard cgroup cap. (`requests` -> `memory.min`/`memory.low` protection exists ONLY with the MemoryQoS feature gate: opt-in `TieredReservation` on ≤1.36, beta default-on from 1.37.) CPU `100m` = 0.1 core = `cpu.weight` share, throttled not killed.

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
2. **Seccomp/AppArmor:** `docker run --security-opt seccomp=unconfined`, `--security-opt apparmor=...`. The default profile blocks ~44 of 300+ syscalls (Docker docs, verbatim) — an allowlist for least privilege, not a sandbox.
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
# Backup SQLite single-node (k3s etcd-snapshot does NOT work here — etcd-only):
# hot, consistent copy WITHOUT stopping k3s:
sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup '/backup/k3s-state.db'"
# or cold copy (stop first): sudo systemctl stop k3s && sudo cp /var/lib/rancher/k3s/server/db/state.db /backup/ && sudo systemctl start k3s
# Restore SQLite: stop k3s, copy the backup back over state.db (fix ownership), start k3s.
# HA embedded-etcd snapshot (only with --cluster-init):
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

Flannel itself enforces no policy — but default K3s ALSO runs an embedded kube-router NetworkPolicy controller, so standard NetworkPolicies ARE enforced out of the box (prove it: apply the default-deny in 15.3 and watch netshoot get refused). Only switch CNI (`--flannel-backend=none --disable-network-policy` + Cilium/Calico) for advanced policy (L7, FQDN), observability (Hubble), or encryption. Know this tradeoff.

### 13.4 kube-proxy iptables Walk + Klipper-LB + Traefik

```bash
kubectl get svc -A
sudo iptables -t nat -L KUBE-SERVICES -n | head -20
sudo iptables -t nat -L KUBE-SVC-XXX -n
ipvsadm -Ln  # if --kube-proxy-arg proxy-mode=ipvs
kubectl -n kube-system get ds | grep svclb  # one DaemonSet per LoadBalancer Service, pods named svclb-<svc>-<hash>
kubectl -n kube-system logs -l svccontroller.k3s.cattle.io/svcname=<svc>  # svclb pods carry NO app=klipper-lb label — this selector is the one that works
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
  - from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: ingress-nginx}}, podSelector: {matchLabels: {app.kubernetes.io/name: ingress-nginx}}}]
    ports: [{port: 8080, protocol: TCP}]
  egress:
  - to: [{podSelector: {matchLabels: {app: postgres}}}]  # one rule per dependency — a policy
    ports: [{port: 5432}]                               # that omits one backend fails CLOSED.
  - to: [{podSelector: {matchLabels: {app: redis}}}]     # extend this list for every backend
    ports: [{port: 6379}]                               # your pods actually call (Part 3 stack
  - to: [{podSelector: {matchLabels: {app: kafka-kraft}}}]  # needs redis:6379 + kafka:9092/9093 too)
    ports: [{port: 9092}, {port: 9093}]
  - to: [{namespaceSelector: {}, podSelector: {matchLabels: {k8s-app: kube-dns}}}]  # allow DNS!
    ports: [{port: 53, protocol: UDP}]
```

Default K3s enforces all of this via its embedded kube-router NetworkPolicy controller — no CNI switch needed for standard policies (only for L7/FQDN/observability, see 13.3). Test with `kubectl run netshoot --rm -it --image=nicolaka/netshoot -- curl -m 5 postgres:5432`.

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

> ⚠ Snapshots need a CSI driver with a snapshotter + VolumeSnapshotClass. K3s's default `local-path-provisioner` has NONE — this manifest fails there. Install Longhorn (or any snapshot-capable CSI) first, then point `volumeSnapshotClassName` at its class.

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

---

## Part 4 Audit — What Was Missing

### [A] Architect findings — concept chains that had holes

**A1. The `/proc` detective kit — god-level debugging from the host.**
```bash
sudo ls /proc/<pid>/                 # cwd, exe, fd/ (open files!), net/, ns/
cat /proc/<pid>/limits               # actual rlimits vs cgroup caps — they stack!
sudo nsenter -t <pid> -n ip addr     # see INSIDE the container's net ns, from host
sudo nsenter -t <pid> -m ls /        # enter its mount namespace
sudo lsof -p <pid> | wc -l           # fd count — leak detection over time
grep -E 'VmRSS|VmSwap' /proc/<pid>/status   # memory truth
```
Why: `docker stats` is a convenience view (usage vs limit, cache nuances); `/proc` is the source of truth. Same for `kubectl top` (uses `working_set_bytes` ≈ RSS minus inactive file cache — know which number the OOM killer actually uses: working set).

**A2. Node forensics without SSH — `kubectl debug node/`.** `kubectl debug node/master-wsl -it --image=busybox -- chroot /host` drops you into the node's filesystem. Read `/var/log/pods/`, host dmesg, crictl state. This is THE trick on managed clusters (EKS/GKE) where you cannot SSH — and on WSL it teaches you that a "node" is just a Linux box wearing a kubelet badge.

**A3. MTU and VXLAN on WSL — the most mysterious failure you will meet.** Flannel VXLAN adds 50 bytes of header → pod interface MTU 1450. Symptom signature: `ping` between pods works (small packets), but large transfers HANG — `docker pull` through a cluster proxy, TLS handshakes with big certificate chains, Kafka messages >1400 bytes. Diagnosis:
```bash
kubectl get nodes -o wide                 # pod CIDRs
ping -c3 -s 1400 -M do <remote-pod-ip>    # fails => MTU problem proven
ip link show flannel.1                    # read the MTU
```
Fix: there is NO `--flannel-mtu` flag — flannel derives MTU automatically (verify: `grep FLANNEL_MTU /run/flannel/subnet.env`). To lower it: shrink the host interface MTU (flannel follows it), or override via `--flannel-conf` with a `net-conf.json` containing `Backend: {Type: vxlan, MTU: <n>}`. Write this one in ERRORS.md *before* you need it.

**A4. conntrack exhaustion — services die silently at scale.** Every Service connection is a conntrack entry. Table full → new connections drop with no error anywhere. Check: `dmesg | grep -i conntrack`, `/proc/sys/net/netfilter/nf_conntrack_count` vs `nf_conntrack_max`. Raise via sysctl (kubelet `--allowed-unsafe-sysctls` or node tuning). The signature — *some* connections work, others time out, nothing in app logs — should make you think "conntrack" within 30 seconds.

**A5. Read `k3s check-config` like an operator.** It verifies: `br_netfilter` + `bridge-nf-call-iptables=1` (without it, bridge traffic bypasses iptables — the signature: **pods reach pod IPs but not Service VIPs**), `overlay` module, `ip_forward=1`, swap warning. Each failing line maps to a specific failure signature — draw that mapping in NOTES.md; it is a private superpower.

**A6. CoreDNS internals — read the Corefile.** `kubectl -n kube-system get cm coredns -o yaml`: the `kubernetes` plugin (service DNS + records), `forward . /etc/resolv.conf` (upstream), `hosts` (node-style overrides), `reload` (live config reload — edit ConfigMap, no restart, watch it apply). Debug loop: CoreDNS logs (`-l k8s-app=kube-dns`) + busybox nslookup from a pod + `dig +trace` if desperate. Know that NodeLocal DNSCache exists and *why* big clusters add it (UDP conntrack pressure + tail latency).

**A7. CPU throttling — the invisible performance killer.** CPU limits translate to CFS quota (`cpu.max = 10000 100000` for 100m). Throttled periods stall the app *even when the node is idle*. Detect: `rate(container_cpu_cfs_throttled_periods_total[5m]) / rate(container_cpu_cfs_periods_total[5m]) > 0.05` → raise limit or drop it. JVM + throttling = GC pauses aligned to quota periods = mystery latency spikes. Prod wisdom: many shops set CPU **requests but no limits** for latency-sensitive apps (limits protect noisy neighbors, requests win scheduling) — know both schools and their tradeoffs.

**A8. Kernel-native locality — CPU Manager & Topology Manager.** `kubelet-arg: cpu-manager-policy=static` + `topology-manager-policy=single-numa-node` pin whole cores to Guaranteed-QoS pods. This is the bridge to Part 5's GPU/RDMA story: same principle (locality = bandwidth), bigger hardware.

### [B] Operator findings — the K3s-on-WSL curse and the observability mindset

**B1. Certificates and the WSL IP-change curse.** K3s server certs embed SANs (node IP, names). WSL2's NAT network changes the IP on reboot → stale Flannel routes, apiserver cert mismatch, Windows-side kubectl suddenly refused. Mitigations: `--tls-san` for every name/IP you'll ever use to reach it; Win11 `networkingMode=mirrored` in `.wslconfig` for a stable network identity; rotate STOPPED (`sudo systemctl stop k3s && sudo k3s certificate rotate && sudo systemctl start k3s` — rotating live can leave missing cert files) then restart. Kubeconfig server field: `127.0.0.1` works only *inside* WSL — for Windows kubectl point it at the WSL IP or a tls-san'd hostname. Write the exact recovery sequence in ERRORS.md; you WILL need it.

**B2. Observability mental models — what to graph and why (this was entirely missing).**
- **Golden Signals** (Google SRE, per service): latency, traffic, errors, saturation. One dashboard per service from exactly these four.
- **USE** (resources — nodes, disks, NICs): Utilization, Saturation, Errors.
- **RED** (request-driven services): Rate, Errors, Duration.
- **Alert philosophy:** page only on symptoms users feel, urgent AND actionable; causes belong on dashboards and tickets. Every page must link a runbook (annotation) — an unrunbooked page is a debt instrument.
- **Recording rules:** precompute the `rate()` expressions — dashboards get cheap, alerts get consistent.

**B3. Loki label cardinality — the Day-2 Loki death.** Labels index log streams. Label by `namespace` and `app`; NEVER by `pod`, `container_id`, or `request_id` — cardinality explodes, Loki OOMs, and it dies quietly. If you must slice by pod, do it in the query (`|=` filters), not in labels.

**B4. metrics-server is bundled in K3s.** (Flagged in Part 2; the operational consequence lives here: `kubectl top` works out of the box; only if `--disable=metrics-server` was set do you reinstall — with `--kubelet-insecure-tls` because kubelet serving certs are k3s-CA-signed.) Validation habit: `kubectl get deploy,svc -n kube-system | grep metrics` BEFORE installing anything the internet tells you to install.

**B5. Where kubelet logs actually are on K3s.** The kubelet runs *inside* the k3s process — `journalctl -u k3s -f` carries apiserver+kubelet+embedded-containerd messages together; containerd socket is `/run/k3s/containerd/containerd.sock` (standalone `crictl`: `export CRI_CONFIG=/run/k3s/containerd/crictl.yaml`). Runtime sockets are step zero of CRI debugging (`crictl info`, `crictl pods`).

---

## Part 4 Exit Exam — half whiteboard, half terminal

1. Whiteboard the flannel VXLAN path pod→pod across nodes, with MTU numbers and where the 50-byte overhead enters.
2. Given the symptom "pod-to-pod ping works, curl hangs" — name MTU, and prove it with the do-not-fragment ping.
3. From the host using ONLY `/proc` and `nsenter`: find a container's IP, its open file count, and its memory footprint.
4. Demonstrate CFS throttling on a limit-100m pod running a busy loop; show the throttled-periods metric rising; explain what the app experiences.
5. Read a Corefile aloud, explain each plugin, add a `hosts` entry and prove it live via the `reload` plugin.
6. Rotate K3s certificates and recover kubectl access from Windows — from your own ERRORS.md entry, not memory.

Next: **Part 5 — Production Mastery, GitOps, AI Supercomputers & the Final Audit Summary.**
