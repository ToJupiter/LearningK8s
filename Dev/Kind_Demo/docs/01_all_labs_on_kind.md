# The kind Deep Lab: From Linux syscalls to a running Kubernetes cluster

This lab assumes you have Docker, `kind`, and `kubectl` installed. We will build a multi-node cluster, then dissect it layer by layer — from the host kernel up through namespaces, cgroups, mounts, veth pairs, systemd units, and finally the Kubernetes API server. Every command is chosen to **expose a Linux primitive that Kubernetes depends on**. By the end you will not see kind as "Docker containers pretending to be nodes"; you will see it as **nested namespaces and cgroups composed into a control plane**.

---

## Lab 0 — Create a cluster you can dissect

Create a three-node cluster (one control plane, two workers) with a fixed name so every later command can reference it:

```bash
cat <<'EOF' > kind-lab.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

kind create cluster --name deep --config kind-lab.yaml
```

Verify the **Docker-level** view before looking at Kubernetes:

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

You will see three containers named `deep-control-plane`, `deep-worker`, and `deep-worker2`. Their image is `kindest/node`. That image is not a minimal base — it contains **systemd, containerd, kubelet, kubeadm, and the Kubernetes control-plane binaries**. Each "node" is a **full Linux userspace running inside a Docker container**, with its own systemd as PID 1.

```bash
kubectl get nodes -o wide
```

The `CONTAINER-RUNTIME` column will say `containerd://...`. Docker (on the host) is **not** the runtime Kubernetes uses inside the node. Docker is only the outer container runtime that launched the node containers. Inside each node, **containerd** is the CRI runtime that kubelet talks to.

---

## Lab 1 — The node container as a Linux process tree

A kind node is a Docker container. Docker containers are **processes with namespaces and cgroups**, not VMs. Inspect the namespaces of the control-plane node's PID 1:

```bash
NODE=deep-control-plane
PID=$(docker inspect -f '{{.State.Pid}}' $NODE)
echo "Host PID of node PID 1: $PID"

sudo lsns -p $PID
```

`lsns` lists the namespace IDs of that process. You will see `mnt`, `pid`, `net`, `uts`, `ipc`, and `cgroup`. Each is a **different kernel namespace instance** from the host's. Now compare with the host's own PID 1:

```bash
sudo lsns -p 1 | head
```

The IDs differ. This is the first hard proof: **the node is not the host**. It has its own PID namespace (so its PID 1 is systemd, not the host's systemd), its own network namespace (so it has its own `eth0`, routes, and iptables), and its own cgroup namespace (so `/sys/fs/cgroup` inside the node is a **subtree**, not the host root).

### Enter the node's namespaces without `docker exec`

`docker exec` gives you a shell *inside* the container, but it does not let you see the namespace structure from the host. Use `nsenter` to enter individual namespaces of the node's PID 1:

```bash
# Enter the node's PID namespace:
sudo nsenter -t $PID -p -- ps aux | head

# Enter the node's network namespace:
sudo nsenter -t $PID -n -- ip addr show

# Enter the node's mount namespace:
sudo nsenter -t $PID -m -- findmnt / | head
```

Compare the node's network namespace with the host's:

```bash
# Host:
ip addr show

# Node:
sudo nsenter -t $PID -n -- ip addr show
```

The node has an `eth0` with a Docker-assigned IP on the `kind` bridge. The host has a `vethXXXX` peer for that node. **This veth pair is the physical link between the host network namespace and the node network namespace.** Every packet between the host and the node crosses this veth pair.

---

## Lab 2 — PID namespace nesting: three layers of processes

There are **three PID namespaces** in play:

```
Host PID namespace
  └── Docker container (node) PID namespace
        └── Pod sandbox PID namespace
              └── Container PID namespace
```

The node's PID namespace is where systemd, kubelet, containerd, and the control-plane binaries run. The Pod's PID namespace is where your application process runs. When you `kubectl exec` into a Pod, you are entering the **innermost** PID namespace.

### Map a Pod's host PID

Inside the node, list containers with `crictl`:

```bash
docker exec -it deep-control-plane crictl ps
```

Pick a container ID, then inspect it:

```bash
docker exec -it deep-control-plane crictl inspect <CONTAINER_ID> | grep -i pid
```

`crictl inspect` reports the **node-local PID** of the container's init process. To find the **host PID**, you must walk the cgroup hierarchy. On a cgroup v2 host:

```bash
# Inside the node, find the cgroup path of a Pod:
docker exec -it deep-control-plane \
  crictl inspect <CONTAINER_ID> | grep cgroupPath
```

Then map it to the host cgroup tree:

```bash
# On the host, find the corresponding cgroup directory:
find /sys/fs/cgroup -type d -name '*<POD_UID>*' 2>/dev/null
```

Inside that cgroup directory, `cgroup.procs` lists the **host PIDs**. This is exactly how tools like `kindps` work: they navigate `/sys/fs/cgroup/` and `/proc/` to map a Pod process to its host PID.

### Why this matters

Kubernetes resource limits (CPU, memory) are enforced by **cgroups on the host kernel**, not by the node's kernel (there is only one kernel). The node's cgroup namespace makes `/sys/fs/cgroup` inside the node look like a private subtree, but the **actual controllers are the host's cgroup v2 controllers**. When you set `resources.limits.memory: 128Mi` on a Pod, kubelet writes to a cgroup file that the host kernel enforces.

Verify the cgroup namespace difference:

```bash
# Host:
cat /proc/self/ns/cgroup

# Node:
docker exec deep-control-plane cat /proc/self/ns/cgroup
```

The inode numbers differ. The node has its **own cgroup namespace** so it does not see the host's full cgroup tree — it sees a virtualized subtree rooted at its own cgroup. This is what allows systemd inside the node to manage its own slices (kubelet, containerd, system pods) without colliding with the host's systemd.

---

## Lab 3 — Mount namespace: where kubelet lives and how volumes are injected

Inside the node, kubelet runs as a systemd service. Its root directory is `/var/lib/kubelet`. Inspect the mount namespace of the node:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' deep-control-plane)
sudo nsenter -t $PID -m -- findmnt /var/lib/kubelet
```

You will see that `/var/lib/kubelet` is a **mount point**, often a bind mount from the host or a Docker volume. kind arranges this so that the **same path resolves to the same directory** whether you are on the host or inside the node. That is why the kubelet subpath code you read earlier can say: "`/var/lib/kubelet` is mounted from the host into the container with kubelet as `/var/lib/kubelet` too."

### The two-stage subPath bind mount

When a Pod uses `subPath`, kubelet performs **two bind mounts**:

```
Stage 1 (node mount namespace):
  bind <volume>/<subpath> → /var/lib/kubelet/pods/<uid>/volume-subpaths/...

Stage 2 (container mount namespace):
  bind /var/lib/kubelet/.../volume-subpaths/... → /inside/container
```

You can see the intermediate targets on the node:

```bash
docker exec deep-control-plane \
  find /var/lib/kubelet/pods -path '*volume-subpaths*' -maxdepth 6 | head
```

Each target is a directory or an empty file created by `prepareSubpathTarget`. Then the container runtime (containerd) performs the second bind mount into the container's mount namespace. **This is the Linux primitive behind every Kubernetes volume mount.**

### Mount propagation

By default, Docker does **not** propagate mounts created inside a container to the host, or vice versa. kind uses `mountPropagation` carefully for CSI volumes and hostPath mounts. You can observe the propagation flags on the node's mounts:

```bash
sudo nsenter -t $PID -m -- findmnt -o TARGET,PROPAGATION | grep -E 'kubelet|containerd'
```

`shared` propagation means a mount created in one namespace is visible in another. `private` means it is not. Kubernetes volume plugins must respect these flags; otherwise, a CSI driver's mount will not reach the Pod.

---

## Lab 4 — cgroups v2 and systemd slices inside the node

Inside the node, systemd is PID 1. Kubelet and containerd are systemd services. Their cgroups are managed by systemd's **cgroup driver** (usually `systemd` on kind images). List the slices:

```bash
docker exec deep-control-plane systemd-cgls --no-pager | head -40
```

You will see slices like `kubelet.slice`, `system.slice`, and Pod-level scopes. On cgroup v2, kubelet creates its own cgroup before systemd starts it. The kind image entrypoint explicitly creates `/kubelet` cgroup on cgroup v2.

Inspect the cgroup of a running Pod from the **host** side:

```bash
# Find a Pod's cgroup directory:
find /sys/fs/cgroup -type d -name '*kubepods*' | head
```

Inside that directory, `memory.max`, `cpu.max`, and `pids.max` hold the **enforced limits** set by Kubernetes. These are the same files systemd and kubelet write to. **There is no "Kubernetes cgroup" — Kubernetes uses the kernel's cgroup v2 interface directly through kubelet and systemd.**

---

## Lab 5 — Network namespaces and the veth graph

Each kind node has its own network namespace. Inside that namespace, kubelet creates Pod network namespaces and connects them to the node using **veth pairs**.

### The node's network namespace

```bash
PID=$(docker inspect -f '{{.State.Pid}}' deep-worker)
sudo nsenter -t $PID -n -- ip addr show
```

You will see `eth0` (the Docker veth peer) and `cni0` or `vethXXXX` interfaces for Pods. kind's default CNI is **kindnet**, which uses the **ptp** plugin by default: it creates a **veth pair** for each Pod, placing one end in the Pod's network namespace and the other end on the node.

### The Pod's network namespace

From inside the node, list Pod sandboxes:

```bash
docker exec deep-worker crictl pods
```

Pick a Pod ID, then get its network namespace PID:

```bash
docker exec deep-worker crictl inspectp <POD_ID> | grep -i pid
```

Enter the Pod's network namespace from the node:

```bash
sudo nsenter -t <POD_PID> -n -- ip addr show
```

You will see the Pod's `eth0` with its own IP from the Pod CIDR. The peer `vethXXXX` is on the node. **The Pod has no idea it is in a container — it sees a normal Linux network stack.**

### Cross-node networking

Pods on different nodes communicate through the **Docker bridge** on the host. Each node's `eth0` is connected to the `kind` bridge. When a Pod on `deep-worker` talks to a Pod on `deep-worker2`, the packet path is:

```
Pod A netns → veth → node A netns → eth0 → Docker bridge → eth0 → node B netns → veth → Pod B netns
```

Check the host's bridge:

```bash
ip link show kind
bridge link show
```

You will see the veth interfaces of all three nodes attached to the same bridge. **This is the physical underlay for Kubernetes overlay networking in kind.** There is no VXLAN here by default — kindnet's ptp plugin uses **pure veth pairs and routing**, not encapsulation, because all nodes share the same Docker bridge subnet.

---

## Lab 6 — The control plane inside the node

The control-plane node runs the Kubernetes API server, etcd, scheduler, and controller-manager as **static Pods** managed by kubelet. You can see them from inside the node:

```bash
docker exec deep-control-plane crictl pods
docker exec deep-control-plane crictl ps | grep -E 'kube-apiserver|etcd|kube-scheduler'
```

These are not Docker containers on the host. They are **containerd containers inside the node container**, launched by kubelet from static manifests in `/etc/kubernetes/manifests`. This is the **nested container** architecture: Docker → node container → containerd → control-plane containers.

Inspect the kubelet systemd unit inside the node:

```bash
docker exec deep-control-plane systemctl status kubelet --no-pager
```

You will see the full command line, including `--container-runtime-endpoint=unix:///run/containerd/containerd.sock`. That socket is the **CRI endpoint**. Kubelet does not talk to Docker; it talks to containerd over a Unix socket. `crictl` uses the same socket.

---

## Lab 7 — Image loading and containerd namespaces

When you run `kind load docker-image`, kind does **not** push to a registry. It exports the image from the host Docker daemon and **imports it into containerd inside each node** using the CRI image service. The image lands in containerd's content store and snapshotter.

Verify from inside the node:

```bash
docker exec deep-worker crictl images
```

Compare with the host:

```bash
docker images
```

The node's containerd has its own image store. Docker's image store is separate. This is why you must `kind load` images — containerd inside the node cannot see the host's Docker images unless they are explicitly imported.

---

## Lab 8 — The full stack, bottom-up

Here is the complete composition, from kernel to API:

```
┌─────────────────────────────────────────────────────────────────────┐
│ HOST KERNEL                                                         │
│  ├─ namespaces: host mnt, pid, net, cgroup                           │
│  ├─ cgroup v2: /sys/fs/cgroup (real controllers)                    │
│  └─ Docker bridge "kind" + veth pairs to each node                  │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ NODE CONTAINER (deep-control-plane)                         │    │
│  │  ├─ own pid ns: systemd = PID 1                             │    │
│  │  ├─ own net ns: eth0 (veth to host bridge)                  │    │
│  │  ├─ own mnt ns: /var/lib/kubelet bind-mounted from host     │    │
│  │  ├─ own cgroup ns: sees subtree, not host root              │    │
│  │  ├─ systemd slices: kubelet.slice, system.slice             │    │
│  │  ├─ containerd (CRI runtime, unix socket)                   │    │
│  │  └─ kubelet (systemd service)                               │    │
│  │        ├─ static Pods: apiserver, etcd, scheduler, cm      │    │
│  │        └─ Pod sandboxes: each with own pid/net/mnt ns      │    │
│  │              └─ veth pair → node net ns → host bridge       │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

**Every layer is just Linux primitives composed:**

| Kubernetes concept | Linux primitive |
|---|---|
| Node | Docker container with systemd (namespaces + cgroups) |
| Pod | Network namespace + PID namespace + cgroup + veth pair |
| Pod CPU/memory limits | cgroup v2 files (`cpu.max`, `memory.max`) |
| Volume mount | bind mount (two-stage for `subPath`) |
| Service ClusterIP | iptables/IPVS rules on the node |
| Pod-to-Pod same node | veth pair + node routing |
| Pod-to-Pod cross-node | veth → Docker bridge → veth |
| Container runtime | containerd over CRI Unix socket |
| Control plane | static Pods launched by kubelet |

---

## The three questions that unlock everything

1. **"Where am I?"** — Run `lsns -p $$` and `cat /proc/self/ns/*`. You are always in some set of namespaces. `nsenter` moves you between them. There is no magic boundary — only namespace IDs.
2. **"What is enforcing this?"** — Resource limits are cgroup files on the host kernel. Network rules are iptables/nftables on the node. Mounts are mount table entries. Find the file, and you find the mechanism.
3. **"Who created this?"** — From the API server down: you → kubectl → API server → controller → kubelet → CRI (containerd) → OCI runtime (runc) → Linux syscalls. Every layer is a process or a file. Nothing is hidden.

Run the labs in order, enter every namespace, read every cgroup file, and trace every veth pair. When you can explain a Pod's packet path from its network namespace to another node's Pod without looking at a diagram, you understand kind — and Kubernetes — at the kernel level.
