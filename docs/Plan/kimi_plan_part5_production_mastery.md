# Part 5 of 5 — Production Mastery: GitOps, Hardening, AI Supercomputers & Capstone
### Covers: Phase 18-21 + Final Words (Days 12-15) | Source: `docs/Plan/kimi_plan.md`
### Prerequisite: Part 4 Exit Exam passed. This part ends with the Final Boss checklist and the consolidated audit summary of all five parts.

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
        - matchExpressions: [{key: nvidia.com/gpu.product, operator: In, values: [NVIDIA-A100-80GB]}]   # slash, not dots — GFD label is nvidia.com/gpu.product
```

Stack: NVIDIA GPU Operator (driver + device-plugin + DCGM exporter DaemonSets) -> `nvidia-smi` in Pod -> NCCL tests. MIG slices one A100 into 7x `1g.5gb` (`nvidia.com/mig-1g.5gb: 1`). Time-slicing shares one GPU across Pods (not for training, ok for inference). MPS for multi-process sharing.

RDMA/InfiniBand: SR-IOV + Multus (multiple CNI: default Flannel + `ib0` via `ib-sriov-cni`), Topology Manager `single-numa-node` + CPUManager `static` for locality. NCCL env: `NCCL_IB_DISABLE=0`, `NCCL_SOCKET_IFNAME=ib0`.

### 20.2 Distributed Training Operators

- Kubeflow Training Operator: `PyTorchJob` (master+workers, `elasticPolicy`), `TFJob`, `MPIJob` (Horovod, `slotsPerWorker: 8`).
- Volcano/Kueue: gang scheduling (all-or-nothing — don't start 7/8 workers!), queues, preemption, fair-sharing across teams. `minMember: 8, minTaskMembers`.
- RayCluster/KubeRay: Ray Train/Tune/Serve for LLM workflows, autoscaling workerGroups.
- Data: checkpoint to fast parallel FS (Lustre/Weka/CephFS/JuiceFS CSI), not local-path! PVC `ReadWriteMany` + VolumeSnapshot before preemption. HuggingFace cache as PVC or S3 (s3-csi).
- Observability: DCGM `DCGM_FI_DEV_GPU_UTIL`, NCCL timeout logs, TensorBoard sidecar, W&B operator.

Try on CPU-only WSL to learn API shapes: install Training Operator, submit tiny `PyTorchJob` with 2 workers doing `torch.distributed` hello-world. Manifests transfer 1:1 to GPU cluster.

### 20.3 Inference + Finetuning Stack Sketch

vLLM/TGI Deployment + HPA on GPU util/custom queue length (KEDA `prometheus` scaler) + Service + HTTPRoute weight split canary + model PVC (initContainer downloads weights) + spot/preemptible tolerations + PDB `maxUnavailable: 0` for serving. Quantization (AWQ/GPTQ) trades VRAM for throughput — same K8s YAML, different image args.

---

## Phase 21: Capstone — Ship It Like Prod + What Next

### 21.1 Final Project Acceptance Criteria

1. `git clone` fresh -> `make deploy-local` -> all Pods Ready in `production`, Ingress answers `http://api.localdev.me/health`.
2. `kubectl run -it --rm netshoot -n production --image=nicolaka/netshoot -- curl -s -m 5 postgres:5432` gets a TCP connect (proves the NetworkPolicy allow-list) followed by a protocol-level failure (proves the app must handle non-HTTP backends gracefully). NOTE: exec'ing `curl` inside `spring-api` itself does NOT work — the Temurin JRE-alpine image ships no curl (alpine base + JRE only, per upstream docs). Debug from a toolbox pod, never from the app image.
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
---

## Part 5 Audit — What Was Missing

### Factual fixes applied to the master text during this audit

| Location | Issue | Fix |
|---|---|---|
| Phase 20.2 | Garbled artifact text ("`стане`") inside the data/checkpoint bullet — residue from a previous generation pass | Rewritten: "PVC `ReadWriteMany` + VolumeSnapshot before preemption" — a reminder to *read your own generated docs critically*; models leave artifacts and operators catch them |

### [A] Architect findings — concept chains that had holes

**A1. Policy as code — concrete Kyverno, not just the name.**
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: {name: disallow-latest-tag}
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-image-tag
      match: {resources: {kinds: [Deployment, StatefulSet]}}
      validate:
        message: "Stable tags only. ':latest' is forbidden."
        pattern:
          spec:
            template:
              spec:
                containers:
                  - image: "!*:latest"
```
Write three more yourself: require `requests`+`limits`, restrict registries to an allow-list, and a *mutate* rule (auto-inject labels). Kyverno (YAML-native) vs OPA Gatekeeper (Rego) — pick one, go deep. This is how team rules stop being wiki pages and start being physics.

**A2. Argo Rollouts — real canary and blue-green.**
```yaml
apiVersion: argoproj.io/v1alpha1   # Rollouts is a CRD — without apiVersion kubectl rejects the file
kind: Rollout
metadata: {name: spring-api, namespace: production}
spec:
  strategy:
    canary:
      steps:
        - {setWeight: 10}
        - {pause: {duration: 60s}}
        - {setWeight: 50}
        - {pause: {}}          # manual gate
        - {setWeight: 100}
```
With `AnalysisTemplate` (Prometheus error-rate query, success condition) promotion and rollback become *automatic*. Completes the strategy triad: rolling (default), blue-green (instant switch, double cost), canary (progressive + measured). The Ingress weight-split trick from Phase 15 was the concept — Rollouts is the product.

**A3. ArgoCD deep cuts.** App-of-apps (an Application whose source contains other Applications — one repo root bootstraps a whole cluster); sync waves (`argocd.argoproj.io/sync-wave: "-1"` annotation → namespaces before CRDs before workloads); hooks (PreSync Job = the migration gate from Part 3); drift detection (a manual `kubectl edit` shows as OutOfSync in the UI — GitOps auditing your discipline from Part 2, automatically).

**A4. K3s upgrades + Kubernetes version skew policy.**
```bash
# In-place upgrade: re-run the installer pinned to a channel/version
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.29.4+k3s1 sh -
# data dir preserved; single-node = brief control-plane outage, tolerable in lab
```
Skew rules (official): kubelet may lag apiserver by up to 3 minors; kubectl within ±1. Multi-node order: control plane first, then agents, ONE AT A TIME — `kubectl drain`, upgrade, verify pods, `kubectl uncordon`. Pre-upgrade ritual: `k3s etcd-snapshot` / copy `state.db`, read release notes for API removals (the place your manifests' `apiVersion`s go to die). Post-upgrade: `kubectl get nodes` shows new version and every node Ready.

**A5. The full DR drill — the actual final exam of a system manager.** Scripted and timed. Velero needs object storage — on WSL that means MinIO first (there is no cloud bucket here):
0. Deploy MinIO from Velero's own examples (`kubectl apply -f https://raw.githubusercontent.com/vmware-tanzu/velero/main/examples/minio/00-minio-deployment.yaml`), create bucket `velero`, write `credentials-velero` (`[default]` + minio keys);
1. `velero install --provider aws --plugins velero/velero-plugin-for-aws:<version-matching-your-velero> --bucket velero --secret-file ./credentials-velero --use-volume-snapshots=false --use-node-agent --default-volumes-to-fs-backup --backup-location-config region=minio,s3ForcePathStyle="true",s3Url=http://minio.velero.svc:9000` (node-agent = the current File System Backup path; `--use-restic` is deprecated. Match the plugin version to your Velero version!);
2. `velero backup create prod-stack --include-namespaces production --default-volumes-to-fs-backup --wait` (PVC contents of local-path volumes ride along ONLY via fs-backup — without it you restore perfectly empty PVCs);
3. Simulate disaster: `kubectl delete ns production` and delete local-path PV dirs;
4. `velero restore create --from-backup prod-stack --wait`;
5. Verify: app serves, Postgres data intact, Kafka topic replayable.
Un-rehearsed restore time is your real MTTR. "Three copies, two media, one offsite, and one *verified restore*." Git manifests + Velero data + SealedSecrets = a cluster you can lose and rebuild inside an hour. That — not never failing — is what godlike means.

### [B] Operator findings — habits of the 2-AM person

**B1. Continuous compliance tooling.** `kube-bench` (CIS scan — read the failures: anonymous-auth, audit log flags, `AlwaysAllow` admission); Trivy Operator (scans running images continuously, emits `VulnerabilityReport` CRs — catches the CVE that landed *after* you deployed); `kubectl who-can delete ns` (RBAC audit: who can destroy the cluster?). Monthly review ritual; fix the cheap ones first.

**B2. On-call habits that compound.** Runbook per alert (what/why/steps/escalation); blameless postmortem template (timeline → root cause → action items — write ONE for a self-inflicted lab incident; it is the best writing practice in this field); error budgets: 99.9% SLO = 43 min/month of allowed downtime — burn it on deploys *deliberately*, never on accidents.

**B3. Terminal arsenal loadout.** k9s, stern, krew (`kubectl krew install neat whoami`), lazydocker, dive, helm-docs; completions for kubectl/helm/k9s in `.bashrc`; `alias k=kubectl kgp='kubectl get pods -o wide'`. Ten seconds saved a hundred times a day is a career.

**B4. AI-ops specifics the plan missed.**
- `NCCL_DEBUG=INFO` — catches silent InfiniBand fallback (training "works" at 10x slower; detect via bus-bandwidth in NCCL logs).
- The gang-scheduling war story: without Volcano/Kueue, the scheduler happily starts 7 of 8 workers; they block waiting for the 8th rank; the cluster starves on half-started jobs. That incident is *why* queue controllers exist — memorize the story, not just the tool name.
- Checkpoint/resume: save `state_dict` to PVC every N steps; initContainer resumes — this is what makes spot/preemptible GPUs economical.
- Model staging: initContainer (or s3-csi/HF hub PVC) downloads weights; `HF_TOKEN` from a Secret — NEVER baked into an image (10GB layers + a leaked token in one mistake).

**B5. Career compounding.** Publish write-ups of your labs (the NOTES.md files ARE drafts); CKA is passable with Parts 1-4 + killer.sh mocks; the AI-infra market wants exactly this stack: K8s + operators + GPU scheduling + Kueue. Your ERRORS.md is more valuable in an interview than any certificate.

---

## Final Boss Checklist — the true capstone

Part 3's acceptance criteria (Phase 21.1) + every Exit Exam + the DR drill, under one clock:

1. From `git clone` on a wiped cluster: full stack Ready and serving through Ingress in **under 30 minutes**, from your own runbook — not from memory.
2. Rolling deploy under load: zero 5xx (preStop + graceful shutdown proven).
3. `kubectl delete pod kafka-0`: topic survives, consumers resume, lag drains.
4. JVM OOMKilled reproduced, diagnosed, and fixed with headroom arithmetic.
5. Velero backup → simulated disaster → restore → data verified, **timed**.
6. Kyverno Enforce blocking a `:latest` deploy in CI; Trivy zero CRITICAL; kube-bench reviewed.
7. NetworkPolicy default-deny with working allow-list — proven with a netshoot pod.
8. ArgoCD green; a manual `kubectl edit` detected as drift and reconciled.
9. One blameless postmortem written for a self-inflicted incident.
10. ERRORS.md has 20+ entries and you can retell any of them as a story with a causal chain.

---

## Consolidated Audit Summary — all five parts

| # | Missing piece (now added) | Severity | Fixed in |
|---|---|---|---|
| 1 | Lab notebook / error-signature / experience protocol | HIGH | Part 1 |
| 2 | Exit codes, PID 1 duties, signal forwarding (`exec "$@"`), `--init` | HIGH | Part 1 |
| 3 | exec vs attach; image taxonomy (dangling); build context size; musl traps | MED | Part 1 |
| 4 | `docker events`, restart policies, weak-machine housekeeping | MED | Part 1 |
| 5 | `startupProbe` + probe budget math | HIGH | Part 2 |
| 6 | Imperative→declarative generation; kubectl power moves; rollout archaeology | HIGH | Part 2 |
| 7 | Empty-Endpoints/502 chain; DNS ndots ladder; stuck finalizers | HIGH | Part 2 |
| 8 | Ephemeral `kubectl debug` (pods + nodes); distroless debugging | MED | Part 2 |
| 9 | initContainers theory + anti-pattern; 12-factor mapping; edit-vs-apply drift | MED | Part 2 |
| 10 | ingress-nginx URL fix; K3s bundles metrics-server | FIX | Part 2 |
| 11 | JVM container memory (MaxRAMPercentage, headroom formula, 137 diagnosis) | HIGH | Part 3 |
| 12 | Connection-pool arithmetic; thundering herd; PgBouncer | MED | Part 3 |
| 13 | Backup + *restore drill* (timed, verified) | HIGH | Part 3/5 |
| 14 | Expand/contract migrations; idempotent migration gating | MED | Part 3 |
| 15 | Full graceful-shutdown chain (Endpoints lag → preStop → SIGTERM → grace period) | HIGH | Part 3 |
| 16 | Kafka consumer lag, retention/compaction, acks/min.insync semantics, DLT | MED | Part 3 |
| 17 | Spring Boot 3 property namespaces; Redis persistence contradiction; NetworkPolicy namespace-label fix | FIX | Part 3 |
| 18 | Operator-vs-handmade judgment (CloudNativePG/Strimzi); 6GB capacity budget | MED | Part 3 |
| 19 | `/proc` + nsenter detective kit; `kubectl debug node/` | HIGH | Part 4 |
| 20 | MTU/VXLAN WSL mystery; conntrack exhaustion; `k3s check-config` signatures | HIGH | Part 4 |
| 21 | CoreDNS Corefile internals; CPU throttling detection; CPU/Topology Manager | MED | Part 4 |
| 22 | K3s cert rotation + WSL IP-change curse + kubeconfig server | HIGH | Part 4 |
| 23 | Golden Signals / USE / RED / alert philosophy / recording rules | HIGH | Part 4 |
| 24 | Loki label cardinality; kubelet/journalctl on K3s | MED | Part 4 |
| 25 | Kyverno concrete policies; Argo Rollouts canary+analysis; app-of-apps/sync waves | MED | Part 5 |
| 26 | K3s upgrade procedure + version skew policy | HIGH | Part 5 |
| 27 | Full DR drill (Velero) + verified-restore doctrine | HIGH | Part 5 |
| 28 | kube-bench / Trivy Operator / who-can; postmortems + error budgets; runbooks | MED | Part 5 |
| 29 | AI-ops: NCCL_DEBUG, gang deadlock story, checkpoint/resume, HF token hygiene | MED | Part 5 |
| 30 | Garbled-text artifact in Phase 20.2 removed | FIX | Part 5 |
| 31 | Exit-143 demo exited 0 as written — replaced with real stop/kill + inspect sequence | FIX | Part 1 |
| 32 | "K3s replaces kube-proxy" claim corrected (standard upstream kube-proxy); KUBECONFIG note scoped to WSL-side | FIX | Part 1 |
| 33 | Removed obsolete `version: "3.9"`; documented Compose-v2 `deploy` semantics (limits apply, replicas ignored) | FIX | Part 2 |
| 34 | node-exporter DaemonSet lacked host mounts (monitored the container, not the node) — full working manifest | HIGH | Part 2 |
| 35 | Ingress port-80 path impossible on baremetal NodePort — added port-forward + Klipper-LB options | HIGH | Part 2 |
| 36 | Postgres StatefulSet pointed at ClusterIP service — added headless service | MED | Part 3 |
| 37 | Kafka: added `KAFKA_LOG_DIRS` (PVC was decorative, Exit Q2 would fail) + txn-log RF/ISR=1; CM marked reference-only | HIGH | Part 3 |
| 38 | Spring deployment lacked the preStop/graceful-shutdown YAML its own exam demands | HIGH | Part 3 |
| 39 | `etcd-snapshot` on SQLite (unsupported), `--flannel-mtu` (nonexistent), `cm coredis` typo, klipper selector — corrected | HIGH | Part 4 |
| 40 | Default K3s DOES enforce NetworkPolicy (embedded kube-router) — CNI-switch claim corrected; egress rules completed | HIGH | Part 4 |
| 41 | requests→memory.min gated on MemoryQoS (version-nuanced); seccomp ~44/300+ (was inverted) | MED | Part 4 |
| 42 | GPU label slash, Rollout `apiVersion`, Velero MinIO+node-agent drill, netshoot criterion | HIGH | Part 5 |

The master file `docs/Plan/kimi_plan.md` remains the unsplit reference; these five parts carry the audited, corrected, exam-gated version of the journey.

## Final Words (unchanged from the master, because they were already right)

You now possess a mental model that connects the Linux kernel (namespaces, cgroups) to Docker (user-friendly isolation) to Docker Compose (multi-service declaration) to Kubernetes (distributed automation). Every concept in Kubernetes is a natural evolution of a Docker concept, scaled and formalized.

Your WSL + K3s environment, despite being resource-constrained, runs the **exact same** Kubernetes API as a 1000-node AI supercomputer cluster. The manifests you write today will work on AWS EKS, Google GKE, or an on-premise GPU cluster tomorrow. The only differences are scale, storage classes, and node types.

**Build the repo. Break things. Read `kubectl describe`. Check logs. That's how you learn.** The depth you've gained here isn't about memorizing commands—it's about understanding the architecture. From here, every new tool (Helm, Istio, ArgoCD, Kubeflow) is just another layer on this solid foundation.

Welcome to the world of cloud-native infrastructure. Your journey into managing AI supercomputers starts with this single node in WSL.
