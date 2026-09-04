# Part 3 of 5 — The Real-World Stack: Postgres, Redis, Kafka (KRaft), Spring Boot
### Covers: Phase 9-11 + Appendices A-D (Days 6-7) | Source: `docs/Plan/kimi_plan.md`
### Prerequisite: Part 2 Exit Exam passed. Your ERRORS.md now feeds directly into this part — most of what follows fails in interesting ways first.

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
          emptyDir: {}          # Ephemeral for this lab — with emptyDir, 'appendonly yes' in redis.conf is pointless (see audit). Use PVC for real persistence.
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
spring.data.redis.host=redis
spring.data.redis.port=6379
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
    spring.data.redis.host=redis
    spring.data.redis.port=6379
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
              kubernetes.io/metadata.name: ingress-nginx
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


---

## Part 3 Audit — What Was Missing

### Factual fixes applied to the master text during this audit

| Location | Issue | Fix |
|---|---|---|
| Phase 9.5 properties + Phase 9 spring-config ConfigMap | `spring.redis.*` is Spring Boot 2 syntax; the stack uses Java 21 / Boot 3, where it moved to `spring.data.redis.*` | Corrected in this file — Boot 3 silently ignores `spring.redis.*`, so Redis host falls back to localhost and the error appears far from the cause |
| Phase 10.3 NetworkPolicy | `namespaceSelector.matchLabels.name: ingress-nginx` — Kubernetes does NOT auto-label namespaces with `name` | Auto-label is `kubernetes.io/metadata.name`. Fixed; otherwise the policy silently matches nothing and you conclude (wrongly) NetworkPolicy "doesn't work" |
| Phase 9.3 Redis | Contradiction: `appendonly yes` (persistence) + `emptyDir` volume (erased on every pod restart) = persistence theater | Either add a PVC or drop `appendonly`. For the lab keep emptyDir and *say out loud why the AOF is pointless here* — that sentence is the learning |
| Phase 9.2 Postgres | `PGDATA` subdirectory is correctly set — but the *reason* was never explained | See A-note below: ext4 `lost+found` makes initdb refuse a mountpoint root. Understand it or it will bite you with a different provisioner |
| Phase 9.4 | KRaft section already added in a previous audit pass — validated correct (listeners, voters, CLUSTER_ID formatting, headless service for DNS) | Two additions below: consumer-lag ops + durability semantics |

### [A] Architect findings — concept chains that had holes

**A1. The JVM inside a memory limit — the OOMKilled masterclass.**
- History: JVMs before 8u191/10 were cgroup-blind — they sized the heap from *host* RAM, so a 6GB host + 512Mi limit = instant OOMKill. Modern JVMs are container-aware and default to `MaxRAMPercentage=25%` of the limit.
- Production formula: `java -XX:MaxRAMPercentage=75.0 -jar app.jar`, then set the K8s limit ≈ heap + ~25% headroom (metaspace, ~1MB/thread stacks, direct buffers, JIT code cache, GC overhead). Example: 512Mi heap → 768Mi limit.
- The trap: the kernel kills the JVM (exit 137) *without any Java log line* — the app never knows it died. Diagnosis: `kubectl describe pod` → OOMKilled, `kubectl top pod` near limit, `dmesg | grep -i oom`. "It works on my machine" dies exactly here.

**A2. Connection-pool arithmetic — the failure that appears only at scale.** Postgres `max_connections` defaults to 100. HikariCP default pool = 10 *per pod*. Two replicas = 20 connections — fine. Scale to 10 replicas + workers + pgAdmin + a migration Job = `FATAL: remaining connection slots are reserved`. Rules:
- `pool = (max_connections - admin_reserve) / expected_pods` — set explicitly: `spring.datasource.hikari.maximum-pool-size=8`
- Rolling deploys cause a reconnect thundering herd — set `initialization-fail-timeout` and let pods start staggered (maxSurge: 1 helps here too!)
- High fan-out? PgBouncer (transaction pooling) between app and DB.

**A3. Backup + restore drill — a backup is a rumor until restored.**
```yaml
# CronJob sketch: pg_dump to PVC (lab-grade; prod: WAL-G/Barman/velero — Part 5)
command: ["sh","-c","pg_dump -h postgres -U app appdb | gzip > /backup/appdb-$(date +%F).sql.gz"]
```
Then the drill that matters: exec a scratch `psql` pod, `gunzip < dump.sql.gz | psql` into `appdb_verify`, count rows against live, drop. Schedule it monthly. Time it. Record in ERRORS.md: "restore of X MB took Y minutes" — that number is your real MTTR.

**A4. Zero-downtime schema changes — expand/contract.** Old and new ReplicaSets run *simultaneously* during a rollout, so a breaking migration instantly kills one generation. The discipline: expand (add nullable column/default) → deploy code writing BOTH → backfill in batches → deploy code reading new → contract (drop old) on a later release. Never rename in place. Migrations must be idempotent (Flyway/Liquibase) and gated: either an initContainer on the first pod (serializes) or a pre-deploy Job (argocd sync-wave in Part 5).

**A5. Spring graceful shutdown on K8s — the full chain, in order.**
1. Pod marked Terminating; **removed from Service Endpoints** — but in-flight connections and kube-proxy/iptables updates lag a few seconds;
2. `preStop: exec: ["sleep","10"]` bridges exactly that propagation gap;
3. SIGTERM arrives → Spring: `server.shutdown=graceful` + `spring.lifecycle.timeout-per-shutdown-phase=30s` (finish in-flight requests, close pools cleanly);
4. `terminationGracePeriodSeconds: 45` (must exceed preStop sleep + shutdown budget);
5. SIGKILL.
Trace one full termination live: `kubectl delete pod --wait=false` + `kubectl get pod -w` + events + app logs. This chain is both an interview favorite *and* the #1 cause of random 502s during deploys.

**A6. Kafka operations beyond boot — the four knobs you will actually tune.**
- **Consumer lag** (your streaming SLA): `kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe` — the LAG column; alert when growing monotonically.
- **Retention vs compaction:** `log.retention.hours` (time-delete) for event streams; `cleanup.policy=compact` for keyed latest-state (Kafka Streams changelogs, `__consumer_offsets` itself).
- **Durability semantics:** prod = `acks=all` + RF=3 + `min.insync.replicas=2` — survives one broker loss with zero acknowledged-write loss. The lab's RF=1/ISR=1 is *deliberately not portable* — keep those values in the local overlay only (Kustomize, Phase 11.2 exists for exactly this).
- **Poison pills:** one deserialization-failing message stops a partition's consumer forever without a handler. Spring: `DefaultErrorHandler` + backoff + `DeadLetterPublishingRecoverer` → DLT topic. Wire it now, thank yourself later.

**A7. Spring Boot 3 actuator on K8s.** Probes auto-register when Boot detects Kubernetes (`/actuator/health/liveness|readiness` exist without extra config on Boot 3); expose metrics: `management.endpoints.web.exposure.include=health,prometheus`. Keep actuator on the SAME port in the lab; in prod put it on a separate management port bound to a Service only the monitoring stack can reach (NetworkPolicy + Part 4).

### [B] Operator findings — judgment calls of a senior operator

**B1. "Should this even be a hand-written manifest?"** The hand-rolled Postgres StatefulSet is *perfect for learning* and wrong for most production: no failover, no WAL archiving, no replica bootstrapping. Operators (CloudNativePG, Zalando, Crunchy for Postgres; Strimzi for Kafka KRaft) automate exactly the 3 AM tasks: failover, backup/restore, version upgrades, certificate rotation. The godlike skill is knowing WHEN the abstraction pays (stateful + high day-2 operations volume) and being able to enumerate what the operator does that you would otherwise do by hand.

**B2. The 6GB WSL capacity budget — write it down, live within it.**
```
Windows + WSL kernel overhead  ~1.2 GiB
k3s control plane + system     ~0.8 GiB
postgres  req 256Mi / lim 512Mi
kafka     req 512Mi / lim 1Gi
spring    req 512Mi x2 (limit 1Gi x2)
redis     lim 300Mi
monitoring (when running)     ~700Mi
```
Requests are the scheduling truth — their SUM must fit node allocatable (~4.5GiB here). Limits firing simultaneously trigger the eviction order you'll learn in Part 4 (QoS). Practical rules: one heavy lab at a time, `kubectl delete -f` between chapters, monitoring stack up only during observability labs. When something is Pending: `kubectl describe node` → "Allocated resources" table — the arithmetic will be right there.

**B3. The race the init container doesn't close.** wait-for-postgres passes → Spring starts → Postgres restarts one second later → app crashes → CrashLoopBackOff backoff grows 10s→20s→40s→…→5m cap → a 1-second blip became a 10-minute outage. Fixes, in order of importance: app-level retry/backoff on connection acquisition (Hikari `connection-timeout` + retry), liveness that means "process alive" (NOT "DB reachable" — that's readiness), and fail-fast startup so backoff starts early rather than hanging.

**B4. Exposure tiers on a laptop — know which tool for which job.** `kubectl port-forward` (personal debugging), NodePort/ServiceLB (LAN demo), Ingress + wildcard DNS `*.localdev.me` (multi-app, prod-feel). TLS locally: `mkcert` + tls Secret in Ingress — leave cert-manager for Part 5 week.

---

## Part 3 Exit Exam — pass in front of a blank terminal

1. From an empty namespace, deploy the full stack; every pod Ready within 5 minutes; document the observed boot order and any races you saw.
2. `kubectl delete pod kafka-0` → the `orders` topic survives, consumers resume from committed offsets. Explain exactly which component preserved what (PVC, Raft metadata, __consumer_offsets).
3. Force exit 137 on the JVM pod via a memory limit; diagnose from `describe` + `top` alone; fix with `MaxRAMPercentage` and prove headroom arithmetic.
4. Deploy a new spring-api version under sustained `hey` load and demonstrate **zero 5xx** — preStop + graceful shutdown working.
5. Restore last night's pg_dump into a scratch database; verify row counts; time the operation.
6. With the worker scaled to 0, show consumer lag growing; scale back to 1 and watch it drain to zero.

Next: **Part 4 — Internals: Docker, K3s, Runtimes, Observability.**
