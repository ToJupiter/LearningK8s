# 01 — cgroups in KIND: container → pod → node → host

This note explains this exact session, run on a WSL host with a KIND cluster.
The important idea: **`kind-control-plane` is not a VM. It is a Docker
container that contains the whole Kubernetes node**, and the pod container is
nested inside it.

```bash
root@kind-host:~# docker exec -it kind-control-plane crictl inspect a7589ee429a36 | grep -i pid
            "pid": 1,
    "pid": 1608,
            "type": "pid"

root@kind-host:~# docker exec -it kind-control-plane crictl inspect a7589ee429a36 | grep -i cgroup
    "systemd_cgroup": true
        "cgroupsPath": "kubelet-kubepods-burstable-pod7e639f12_a58f_41fe_92f4_1dd853a9e0b7.slice:cri-containerd:a7589ee429a36d22dd655f5fc43c1f5c991679ebf4bbd44b015b183dffb8422f",
            "type": "cgroup"
        "destination": "/sys/fs/cgroup",
        "source": "cgroup",
        "type": "cgroup"

root@kind-host:~# find /sys/fs/cgroup/ -type d -name '*a7589ee429a36*' 2>/dev/null
/sys/fs/cgroup/system.slice/docker-3ea19abd45c6c9eeb987f97a49cc1de8c20f2595d7ac8186cc6660c59e594a80.scope/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/kubelet-kubepods-burstable-pod7e639f12_a58f_41fe_92f4_1dd853a9e0b7.slice/cri-containerd-a7589ee429a36d22dd655f5fc43c1f5c991679ebf4bbd44b015b183dffb8422f.scope
```

---

## The short answer

1. **cgroups are how Linux limits and measures processes.** They are a tree of
   directories in `/sys/fs/cgroup`; each directory has files like
   `memory.max`, `cpu.max`, and `pids.max`.
2. **KIND nests containers.** WSL runs Docker → Docker runs the
   `kind-control-plane` node container → the node runs containerd → containerd
   runs the pod containers. The cgroup tree has exactly the same shape.
3. **One kernel enforces everything.** There is no kernel inside the kind node
   or inside the pod. Every process is still a process on the WSL kernel.
4. **The two paths look different because of the cgroup namespace.** Inside the
   node, the node's own cgroup is `/`. On the host, the same cgroup is deeper:
   under `system.slice/docker-<node-id>.scope/`.

> **First time?** Read sections 3, 4, 7, and 8 first. The rest is reference
> material you can come back to.

---

## 1. What a cgroup is (beginner level)

A **cgroup** (control group) is a group of Linux processes with three things:

| Thing | Example |
|---|---|
| Membership | "These processes belong to this group." |
| Limits | "This group may use at most 170 MiB of memory." |
| Accounting | "How much CPU/memory did this group use?" |

It is **not** a container and **not** a virtual machine. It is a kernel feature.
A container uses cgroups **plus** namespaces, a root filesystem, and
capabilities.

### The cgroup filesystem

```bash
ls /sys/fs/cgroup/
```

You will see directories and files such as:

```text
/sys/fs/cgroup
├── cgroup.procs          # which processes are in this group
├── cgroup.controllers    # which controllers this group can use
├── cgroup.subtree_control # which controllers child groups may use
├── cpu.max               # CPU quota
├── cpu.weight            # relative CPU share
├── memory.max            # hard memory limit
├── memory.current        # memory usage now
├── pids.max              # process/thread limit
└── ...
```

Think of it as a tree of folders. Each folder is a group. Each folder has
knobs (limits) and meters (usage). The kernel reads the knobs and enforces
them.

A cgroup is **not** stored inside the container image or the container
filesystem. It is a kernel object on the host. When a container sees
`/sys/fs/cgroup`, it is looking at a namespaced view of that host-side object.

### A useful analogy

Imagine a building's electricity:

```
building main breaker          <- WSL host
└── apartment main breaker     <- kind node container
    └── floor breaker          <- kubepods slice
        └── room breaker       <- pod cgroup
            └── appliance      <- container cgroup
```

An appliance cannot draw more than its own breaker **or any breaker above it**.
The most restrictive breaker wins. That is exactly how nested cgroup memory
limits work.

---

## 2. cgroups vs namespaces (do not confuse them)

These are two different kernel features:

| Feature | Question it answers | Example |
|---|---|---|
| **Namespace** | *What can the process see?* | PID 1 inside its container; its own network stack; its own hostname. |
| **cgroup** | *How much can the process use?* | 170 MiB memory, 0.5 CPU, 100 processes. |

A container is roughly:

```
container = namespaces (isolation) + cgroup (limits) + rootfs + capabilities
```

- Namespaces make the process **believe** it is alone.
- cgroups make sure it **cannot take all the resources**.
- Neither one alone is a container.

---

## 3. The KIND nesting (the key picture)

On a normal Kubernetes node:

```
Linux host
└── kubelet
    └── pod
        └── container
```

In KIND there is one extra level:

```
WSL2 VM (one Linux kernel)
└── systemd (the WSL init)
    └── docker.service (Docker daemon)
        └── docker-3ea19...scope          <- kind-control-plane container = the node
            ├── init.scope                <- systemd inside the kind node
            ├── system.slice
            │   └── containerd.service    <- container runtime
            └── kubelet.slice
                └── kubelet-kubepods.slice
                    └── ...-burstable.slice
                        └── ...pod7e63...slice
                            ├── pause container scope
                            └── coredns container scope   <- a758..., the one we inspected
```

The same thing, as real command output from this lab (`systemd-cgls` on the
host, shortened):

```text
CGroup /system.slice/docker-3ea19...scope:
├─init.scope
│ └─19176 /sbin/init
├─system.slice
│ └─containerd.service
│   ├─19379 /usr/local/bin/containerd
│   └── ... containerd-shim processes
└─kubelet.slice
  ├─kubelet.service
  │ └─20222 /usr/bin/kubelet ...
  └─kubelet-kubepods.slice
    └─kubelet-kubepods-burstable.slice
      └─kubelet-kubepods-burstable-pod7e639f12_a58f_41fe_92f4_1dd853a9e0b7.slice
        ├─cri-containerd-578bcf...scope
        │ └─21222 /pause
        └─cri-containerd-a7589...scope
          └─21425 /coredns -conf /etc/coredns/Corefile
```

Notice:

- The **node** is the `docker-3ea19...scope`. Docker created it because
  `kind-control-plane` is a normal Docker container.
- `kubelet.slice`, `containerd.service`, and the pod containers live **inside**
  that scope, because from the node's point of view, it is a normal Linux node.
- The pod (`pod7e639f12...slice`) is a **folder**, not a process. Its processes
  are in the two child container scopes: `pause` and `coredns`.

### Path anatomy

Reading the full host path from left to right:

```text
/sys/fs/cgroup
└── system.slice
    └── docker-3ea19...scope                    # kind node (a Docker container)
        └── kubelet.slice                       # kubelet
            └── kubelet-kubepods.slice          # all pods on the node
                └── kubelet-kubepods-burstable.slice   # pods with QoS = Burstable
                    └── ...pod7e639f12...slice        # one Pod
                        └── cri-containerd-a758...scope # one container
```

| Component | What it is |
|---|---|
| `system.slice` | The systemd slice for system services on the WSL host. |
| `docker-3ea19...scope` | The **kind node**, which is a Docker container. On a normal node this level does not exist. |
| `kubelet.slice` | Kubelet's cgroup. |
| `kubelet-kubepods.slice` | All Kubernetes pods on this node. |
| `kubelet-kubepods-burstable.slice` | The **QoS class** slice. `BestEffort` and `Burstable` get their own slices; `Guaranteed` pods sit directly under `kubelet-kubepods.slice`. |
| `...-pod7e639f12_a58f_...slice` | One Pod. The pod UID is `7e639f12-a58f-41fe-92f4-1dd853a9e0b7`; dashes become underscores because systemd uses `-` to build the slice hierarchy. |
| `cri-containerd-a7589ee429a36...scope` | One container, named after the CRI container ID. |

The general pattern is:

```text
/sys/fs/cgroup/system.slice/docker-<kind-node-id>.scope/
    kubelet.slice/
    kubelet-kubepods.slice/
    kubelet-kubepods-<qos>.slice/                    # omitted for Guaranteed
    kubelet-kubepods-<qos>-pod<pod-uid-with-underscores>.slice/
    cri-containerd-<container-id>.scope
```

### What is a "node" in KIND?

Both statements are true at the same time:

- **From Kubernetes' view:** `kind-control-plane` is a node with a kubelet, a
  container runtime, and pods.
- **From the WSL host's view:** `kind-control-plane` is just a Docker container
  running those processes.

A Docker container is not a tiny VM. It is a group of processes on the host
kernel with namespaces and cgroups. KIND simply runs the whole node inside one.

---

## 4. Who creates each layer?

| Layer | Created by | Example in this lab |
|---|---|---|
| Host cgroup root | systemd on WSL | `/sys/fs/cgroup` |
| Node container scope | Docker (systemd cgroup driver) | `docker-3ea19...scope` |
| `kubelet.slice` | systemd, because kubelet runs in that slice | `kubelet.slice` |
| `kubelet-kubepods.slice` | kubelet, via containerd/CRI | all pods |
| QoS slice | kubelet | `kubelet-kubepods-burstable.slice` |
| Pod slice | kubelet | `...pod7e639f12...slice` |
| Container scope | containerd + runc, via systemd | `cri-containerd-a758...scope` |

The flow when you create a pod is:

```text
kubectl apply
    │
    ▼
kube-apiserver  (stores the Pod object)
    │
    ▼
kube-scheduler   (chooses kind-control-plane)
    │
    ▼
kubelet inside the kind node
    │  CRI gRPC: "run this container with these resources"
    ▼
containerd  ->  runc
    │
    ▼
systemd creates slice/scope directories in /sys/fs/cgroup
    │
    ▼
the WSL kernel enforces the limits
```

The kubelet does **not** create the container itself. It asks the CRI runtime
(containerd) to do it. containerd calls runc, and runc creates the namespaces
and cgroup for the container.

### How the layers interact: limits go down, usage goes up

```text
LIMITS / CONFIGURATION  (down)

  kubectl / Pod spec
        │
        ▼
  kubelet  ──►  containerd  ──►  systemd  ──►  cgroup files  ──►  kernel
        │
        └── creates the slices/scopes with the limits from the Pod spec


USAGE / METRICS  (up)

  application process
        │  is charged to its container cgroup
        ▼
  container cgroup  ──►  pod cgroup  ──►  QoS slice  ──►  kubepods
        │
        ▼
  kind node cgroup  ──►  WSL host
        │
        └── kubelet/cAdvisor reads these counters
            metrics-server asks kubelet
            kubectl top shows the result
```

Practical consequences:

- If you limit the **kind node** container from the host, every pod inside it
  is also limited by that ceiling. The host is the outermost breaker.
- If you set a **pod/container limit**, kubelet passes it to containerd, which
  creates the child cgroup with that limit. The host does not need to know
  about it; the kernel enforces it because the cgroup is in the host's tree.
- The host can see **all** processes and cgroups. The node sees only its own
  subtree because of namespaces. The pod sees even less.
- Metrics bubble up the same tree: container → pod → node → host. That is why
  `docker stats kind-control-plane` and `kubectl top pod` can show different
  levels of the same reality.

---

## 5. `systemd_cgroup: true` and the `cgroupsPath`

Kubelet can manage cgroups in two ways:

- **cgroupfs** driver — the container runtime writes directly into
  `/sys/fs/cgroup`.
- **systemd** driver — the runtime asks systemd to create `.slice` and `.scope`
  units.

This cluster uses systemd (`"systemd_cgroup": true`). That is why the path is
made of systemd unit names.

The `cgroupsPath` is in systemd's triple form:

```text
<slice>:<prefix>:<name>
   |        |       |
   |        |       └── container ID: a7589ee429a36...
   |        └────────── runtime prefix: cri-containerd
   └─────────────────── slice: kubelet-kubepods-burstable-pod7e63...slice
```

systemd expands that to:

```text
kubelet-kubepods-burstable-pod7e63...slice
└── cri-containerd-a7589ee429a36....scope
```

Systemd slice names are hierarchical: `a-b-c.slice` is a child of
`a-b.slice`, which is a child of `a.slice`. So the full chain is:

```text
kubelet.slice
└── kubelet-kubepods.slice
    └── kubelet-kubepods-burstable.slice
        └── kubelet-kubepods-burstable-pod7e639f12_a58f_41fe_92f4_1dd853a9e0b7.slice
            └── cri-containerd-a7589ee429a36....scope
```

Why does the pod slice name use `_` instead of `-`? Because `-` is the
separator systemd uses to build the slice hierarchy. A pod UID contains
dashes, so kubelet replaces them with underscores:

```text
pod UID: 7e639f12-a58f-41fe-92f4-1dd853a9e0b7
slice:   7e639f12_a58f_41fe_92f4_1dd853a9e0b7
```

You can inspect these units with systemd:

```bash
systemctl status cri-containerd-a7589ee429a36d22dd655f5fc43c1f5c991679ebf4bbd44b015b183dffb8422f.scope
systemd-cgls /kubelet.slice/kubelet-kubepods.slice
```

---

## 6. Why the host path is longer — the cgroup namespace

The `"type": "cgroup"` entry in the `crictl inspect` output is the **cgroup
namespace**. (The output contains two `type: cgroup` lines: the first is the
namespace entry; the second, with `destination`/`source`, describes the cgroup2
filesystem mount.)

A cgroup namespace changes **what a process sees as the cgroup root**. It does
not move the process to a different cgroup; it only changes the view.

- **Inside the kind node**, `/sys/fs/cgroup` is rooted at the node container's
  own cgroup. Kubelet creates `kubelet.slice` there, so paths begin at
  `kubelet-kubepods-...`.
- **On the WSL host**, that same subtree is one branch below the node's Docker
  cgroup, so paths begin at `system.slice/docker-3ea19...scope/...`.

Same cgroup, two views:

```text
INSIDE kind-control-plane                    ON the WSL host
-------------------------                    -----------------
/sys/fs/cgroup                               /sys/fs/cgroup
└── kubelet.slice                            └── system.slice
    └── kubelet-kubepods.slice                   └── docker-3ea19...scope   <- kind node
        └── kubelet-kubepods-...                     └── kubelet.slice
            └── pod7e63...slice                          └── kubelet-kubepods.slice
                └── cri-containerd-a758...scope              └── ...pod7e63...slice
                                                                 └── cri-containerd-a758...scope
```

Docker gives the kind node container a **private cgroup namespace** by default
on cgroup v2. That is why the node sees itself at `/`, while the host sees the
full depth.

The pod container usually has its own private cgroup namespace too. So there
are actually **three views of the same cgroup**:

```text
HOST sees:
  /sys/fs/cgroup/system.slice/docker-3ea19...scope/
      kubelet.slice/kubelet-kubepods.slice/.../cri-containerd-a758...scope

KIND NODE sees:
  /sys/fs/cgroup/
      kubelet.slice/kubelet-kubepods.slice/.../cri-containerd-a758...scope

COREDNS CONTAINER sees:
  /sys/fs/cgroup/                 <- its own container cgroup is the root here
      memory.max = 170 MiB
      cpu.max    = max 100000
```

That is why `crictl inspect` shows a `"type": "cgroup"` namespace entry: the
container was given a cgroup namespace, so it cannot see the host's whole
cgroup tree.

You can prove the container's view from the host with:

```bash
grep cgroup2 /proc/21425/mountinfo
# ... /system.slice/docker-3ea19...scope/kubelet.slice/.../cri-containerd-a758...scope
#     /sys/fs/cgroup ro,nosuid,nodev,noexec,relatime - cgroup2 cgroup rw,nsdelegate
```

The first path is the **root of the cgroup namespace**; the second is where it
is mounted inside the container. It is mounted **read-only**, so the container
cannot raise its own limits.

This is also why:

```bash
docker exec -it kind-control-plane crictl inspect ...
```

shows the short path (it runs inside the node's namespaces), while:

```bash
find /sys/fs/cgroup -type d -name '*a7589ee429a36*'
```

on the host shows the long path.

> Both paths are correct. They refer to the same cgroup. Only the namespace
> root is different.

---

## 7. Walking the actual values

These are the real values observed in this lab at the time of writing.

| Layer | `memory.max` | `memory.current` | `cpu.max` | `cpu.weight` | `pids.max` | `cgroup.procs` |
|---|---:|---:|---|---:|---:|---|
| WSL host root | `max` | 7.0 GiB | `max 100000` | 100 | `max` | many |
| `docker-3ea19...scope` (kind node) | `max` | 1.1 GiB | `max 100000` | 100 | 9436 | empty |
| `kubelet.slice` | `max` | 459 MiB | `max 100000` | 100 | `max` | empty |
| `kubelet-kubepods.slice` | 7.69 GiB | 413 MiB | `max 100000` | 313 | 62913 | empty |
| `kubelet-kubepods-burstable.slice` | `max` | 390 MiB | `max 100000` | 37 | `max` | empty |
| `...pod7e639f12...slice` | 170 MiB | 14.3 MiB | `max 100000` | 4 | `max` | empty |
| `cri-containerd-a758...scope` (coredns) | 170 MiB | 14.0 MiB | `max 100000` | 17 | 1415 | 21425 |

Read this table from top to bottom and notice:

1. **`memory.current` includes descendants.** The node uses 1.1 GiB total;
   the pods inside it use 413 MiB; the CoreDNS pod uses 14.3 MiB; the CoreDNS
   container uses 14.0 MiB.
2. **`cgroup.procs` is empty at parent levels.** The processes live in the leaf
   container scopes. The pod folder itself is only an organizational/limit
   boundary.
3. **The effective memory limit is the smallest ceiling on the path.** The node
   has `max`, the kubepods slice has 7.69 GiB, the pod and container have
   170 MiB. So CoreDNS can use at most **170 MiB**, even though the node has no
   direct memory limit.
4. **There is no CPU hard limit here.** Every `cpu.max` is `max 100000`, which
   means "no quota". CPU is controlled only by weights (relative shares).
5. **`pids.current` includes descendants**, which is why the pod can show 13
   processes while its `cgroup.procs` is empty.

### Why parent `cgroup.procs` files are empty

This is the cgroup v2 **no-internal-process rule**:

> A cgroup cannot both contain processes and enable controllers for its child
> cgroups.

Kubernetes keeps the parent cgroups (`docker-...scope`, `kubelet.slice`,
`kubepods`, QoS slices, pod slice) as **organizational folders**. The actual
processes are placed in the leaf container scopes. That is why
`cgroup.procs` is empty at those levels, but `pids.current` is not.

The pod folder still matters because its `memory.max` and `pids.max` are
ceilings for all containers in the pod, and its `cpu.weight` decides how the
pod competes with other pods.

### Why there are two container scopes in the pod

The pod slice contains:

```text
...pod7e639f12...slice
├── cri-containerd-578bcf...scope   -> /pause
└── cri-containerd-a758...scope     -> /coredns
```

The `pause` container is the sandbox container. It holds the pod's namespaces
(network, IPC, etc.) so the application containers can share them. It has its
own cgroup because it is a real process, even though it does almost nothing.

The `coredns` container is the one you inspected. Its cgroup is the
`a758...scope`.

---

## 8. How a memory limit is actually enforced

Suppose the CoreDNS container tries to allocate memory beyond its 170 MiB
limit:

```text
1. CoreDNS calls malloc() / touches a new page.
2. The kernel charges that page to the coredns cgroup.
3. The kernel also charges it to every ancestor cgroup:
       coredns -> pod -> burstable -> kubepods -> kubelet -> node -> host
4. At each level the kernel checks memory.max.
   The smallest limit on the path is the real ceiling.
5. If the charge would exceed a limit, the kernel first tries to reclaim
   memory (drop page cache, swap if available).
6. If it still cannot fit, the OOM killer kills a process in that cgroup.
7. The container exits with code 137 (128 + SIGKILL), and Kubernetes marks it
   OOMKilled.
```

> On cgroup v2, Kubernetes also sets `memory.oom.group=1` (from v1.28), so the
> OOM killer kills the whole container cgroup together instead of one random
> process inside it.

Useful evidence files:

```bash
cat "$CG/memory.max"       # the ceiling
cat "$CG/memory.current"   # current usage
cat "$CG/memory.peak"      # highest usage seen
cat "$CG/memory.events"    # oom / oom_kill counters
cat "$CG/memory.stat"      # anon, file, slab, page faults, ...
```

`memory.events` looks like this:

```text
low 0
high 0
max 0
oom 0
oom_kill 0
```

After an OOM kill, `oom` / `oom_kill` become non-zero.

### Why a parent limit can still kill you

Imagine this change:

```text
kind node scope:  memory.max = 512 MiB
pod A:            memory.max = 400 MiB
pod B:            memory.max = 400 MiB
```

Neither pod is over its own 400 MiB limit, but together they can exceed the
node's 512 MiB. When that happens, the **node's** cgroup is over its limit, so
the kernel kills a process somewhere inside the node's subtree. The child
limits do not protect you from an ancestor limit.

That is the "most restrictive breaker wins" rule from the analogy.

---

## 9. How CPU limits work

CPU is different from memory because CPU is **compressible**. You can throttle
a process; you cannot "throttle" a memory allocation.

There are two files:

### `cpu.weight` — relative share

`cpu.weight` only matters when the CPU is busy and siblings compete.

```text
parent
├── container A  cpu.weight = 100
└── container B  cpu.weight = 200
```

When both want CPU, B gets roughly twice as much as A. When only A wants CPU,
A can use the whole CPU (subject to `cpu.max`).

Kubernetes derives `cpu.weight` from the CPU **request**, not the limit. The
weights are hierarchical: the pod's weight decides how the pod competes with
other pods, and the container's weight decides how containers inside that pod
compete with each other. Do not add the numbers together.

### `cpu.max` — hard quota

```text
cpu.max = "50000 100000"
           quota  period
```

This means: 50 ms of CPU per 100 ms period = **0.5 CPU**.

- `max 100000` means no quota: the group can use as much CPU as available.
- When a group uses its whole quota, it is **throttled** until the next period.
- It is not killed. The app just runs slower.

Check throttling:

```bash
cat "$CG/cpu.stat"
# nr_periods   ...
# nr_throttled ...
# throttled_usec ...
```

If `nr_throttled` keeps increasing, the container is hitting its CPU quota.

A parent `cpu.max` also caps all children. If the kind node had a 1-CPU
quota, all pods together could not exceed 1 CPU, regardless of their individual
limits.

---

## 10. How PID limits work

```bash
cat "$CG/pids.max"
cat "$CG/pids.current"
```

- `pids.max` caps the number of tasks (processes **and threads**) in the
  cgroup and its descendants.
- `pids.current` is the current count, including descendants.
- This is fork-bomb protection.
- The effective limit is again the smallest `pids.max` on the path.

In this lab most containers have `pids.max = 1415`, set by the node's
kubelet/runtime configuration. On many clusters it is `max` (unlimited).

---

## 11. Why there are two PIDs (`1` and `1608`)

| Output | Meaning |
|---|---|
| `"pid": 1` | PID **inside the container's own PID namespace**. Every container's main process is PID 1 in its namespace. |
| `"pid": 1608` | The same process's PID **as seen by the kind node**, because `crictl` runs inside `kind-control-plane`. |
| `"type": "pid"` | Not a PID value. This is the `pid` entry in the container's list of namespaces. |

KIND adds one more PID namespace level, so the same process has three
identities:

```text
coredns process
├── PID 1      inside its own container namespace   (what CoreDNS sees)
├── PID 1608   inside the kind node namespace       (what crictl reports)
└── PID 21425  inside the WSL host namespace        (what the host sees)
```

> In this lab the container turned out to be CoreDNS. Reading the same cgroup
> from the host and running `cat .../cgroup.procs` returned host PID `21425`;
> `cat /proc/21425/comm` confirmed `coredns`. Your numbers change on restart.

Rule of thumb:

- `crictl inspect` shows the PID from **the node's point of view**.
- `/proc/<pid>` on the **host** needs the host PID.
- The bridge between the two is the cgroup's **`cgroup.procs`** file, read from
  the namespace you are in.

Remember: a cgroup does not change a process's PID. **PID namespaces** do that.
The cgroup is just a membership/limit mechanism.

---

## 12. Kubernetes resources → cgroup values

For a hypothetical pod spec such as:

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "70Mi"
  limits:
    cpu: "500m"
    memory: "170Mi"
```

roughly:

| Kubernetes field | cgroup file | Effect |
|---|---|---|
| `requests.cpu` | `cpu.weight` | Relative share when the CPU is busy; also used by the scheduler. |
| `limits.cpu` | `cpu.max` | Hard quota. The container is **throttled**, never OOM-killed. |
| `requests.memory` | — (scheduler/QoS only) | Not a hard cap by default on cgroup v2. |
| `limits.memory` | `memory.max` | Hard cap. Exceeding it **OOM-kills** the container. |
| pod PID limit | `pids.max` | Fork-bomb protection. |

QoS class decides the slice:

| QoS | Rule | Slice |
|---|---|---|
| `Guaranteed` | Every container has CPU and memory requests == limits. | `kubelet-kubepods.slice` |
| `Burstable` | At least one request/limit set, but not Guaranteed. | `kubelet-kubepods-burstable.slice` |
| `BestEffort` | No requests and no limits. | `kubelet-kubepods-besteffort.slice` |

This is why the path above contains `kubelet-kubepods-burstable` — the pod has
resource requests and at least one limit, but they are not all equal.

### Pod-level vs container-level limits

A pod cgroup is the parent of its container cgroups. With one container, the
pod's memory ceiling will be the same as that container's limit (as seen here:
170 MiB in both places). With multiple containers, kubelet normally sets the
pod-level memory ceiling to the sum of the container limits, so the pod as a
whole cannot exceed the total.

The container's own cgroup is still where the application process lives and
where its individual limit is enforced.

> In this CoreDNS pod the memory limit is 170 MiB, and there is **no CPU
> limit** (`cpu.max = max 100000`). That is why the CPU values in the table are
> all `max`.

---

## 13. Looking from each layer

| Where you run the command | What you see |
|---|---|
| **WSL host** | `docker stats kind-control-plane` — whole node usage. `systemd-cgls` — the full tree including the Docker scope. `cat /sys/fs/cgroup/...` — the long paths. |
| **Inside the kind node** | `crictl inspect` — node-relative PIDs and short cgroup paths. `crictl stats` — per-container stats. `systemctl status <scope>` — systemd's view. `cat /sys/fs/cgroup/...` — short paths. |
| **Kubernetes API** | `kubectl top pod` — metrics collected from the kubelet/cgroups (needs metrics-server; not installed by default in kind). `kubectl describe pod` — requests, limits, QoS class. |

Examples:

```bash
# Host: how much is the whole kind node using?
docker stats kind-control-plane --no-stream

# Host: the full cgroup tree of the node
systemd-cgls /system.slice/docker-3ea19abd45c6c9eeb987f97a49cc1de8c20f2595d7ac8186cc6660c59e594a80.scope

# Node: containers and their PIDs
docker exec kind-control-plane crictl ps
docker exec kind-control-plane crictl stats

# Node: what does the runtime think the cgroup is?
docker exec kind-control-plane crictl inspect a7589ee429a36

# Cluster: what did Kubernetes promise the pod?
kubectl -n kube-system get pod <coredns-pod> -o jsonpath='{.spec.containers[0].resources}'

# Cluster: live usage (only if metrics-server is installed; kind does not
# install it by default)
kubectl top pod -n kube-system
```

`docker stats kind-control-plane` is just reading the node's cgroup
(`docker-3ea19...scope`). It is an aggregate of every pod inside the node.

---

## 14. A safe hands-on experiment (OOM in a cgroup)

Create a pod with a memory limit, then force it over the limit:

```bash
kubectl run memhog \
  --image=polinux/stress \
  --restart=Never \
  --limits=memory=64Mi \
  -- stress --vm 1 --vm-bytes 120M --vm-hang 0

kubectl get pod memhog -w
```

Find its cgroup from the pod UID:

```bash
UID=$(kubectl get pod memhog -o jsonpath='{.metadata.uid}')
CG=$(sudo find /sys/fs/cgroup -type d -name "*pod${UID//-/_}*")
echo "$CG"

# Watch the memory usage and the OOM counters
watch -n 1 "cat $CG/memory.current $CG/memory.events"
```

Expected result:

```bash
kubectl get pod memhog
# STATUS: OOMKilled

# Robust way to read the termination reason and exit code:
kubectl get pod memhog -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}{"\n"}'
# OOMKilled

kubectl get pod memhog -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
# 137

cat "$CG/memory.events"
# oom 1
# oom_kill 1        (or more, depending on how many tasks were killed)
```

Clean up:

```bash
kubectl delete pod memhog
```

What to notice:

- `memory.current` rises toward `memory.max` (64 MiB).
- The kernel kills the process, not the node.
- Only this cgroup is affected; other pods keep running.
- The parent limits were not the cause here; the 64 MiB container limit was.

> Do not write to `memory.max` or `cgroup.procs` on Kubernetes-managed
> cgroups. Kubelet and containerd own those files and will reconcile them.
> Use a Pod spec instead.

---

## 15. Tracing a process across the namespaces

```bash
# 1. Inside the kind node: get the container's PID as the node sees it
docker exec -it kind-control-plane crictl inspect a7589ee429a36 | grep -i '"pid"'

# 2. On the host: find the container's cgroup
CG=$(sudo find /sys/fs/cgroup -type d -name '*a7589ee429a36*')

# 3. Read the processes in that cgroup — these are HOST PIDs
cat "$CG/cgroup.procs"

# 4. Inspect the real process on the host
PID=$(cat "$CG/cgroup.procs" | head -1)
cat /proc/$PID/comm
grep -E 'Name|PPid|VmRSS|Threads' /proc/$PID/status

# 5. Enter its namespaces from the host
sudo nsenter -t "$PID" -n ip addr
sudo nsenter -t "$PID" -m ls /
```

What you just built:

```text
container PID namespace        PID 1
        ↓  (nested inside)
kind node PID namespace        PID 1608    ← crictl reports this
        ↓  (nested inside)
WSL host PID namespace         PID 21425   ← /proc and cgroup.procs report this
```

The cgroup files are the same object at every level; only **the path prefix
and the PID numbers change** with the namespace you are looking from.

---

## 16. Common misconceptions

- **"The kind node is a VM."** No. It is a Docker container running on the WSL
  kernel. There is no second kernel.
- **"The pod has its own kernel."** No. It has its own namespaces and cgroup,
  but it uses the host kernel.
- **"A cgroup is a container."** No. A cgroup is only resource grouping. The
  container also needs namespaces, a rootfs, etc.
- **"The limit on the node and the limit on the pod are independent."** They
  are nested. The effective limit is the smallest one on the path.
- **"`requests.memory` is a hard limit."** No. It is used for scheduling and
  QoS. `limits.memory` becomes `memory.max`.
- **"CPU limits kill the process."** No. CPU limits throttle. Memory limits
  can kill.
- **"The cgroup path is stable."** No. Container IDs and pod UIDs change. Use
  `find` or `crictl` to locate it.
- **"Empty `cgroup.procs` means the cgroup is unused."** No. It may contain
  child cgroups and thus processes, even if it has no direct members.
- **"`docker stats kind-control-plane` shows one container's usage."** It shows
  the whole node's cgroup, which includes every pod.

---

## 17. Quick reference

```bash
# What is this container?
docker exec kind-control-plane crictl ps --no-trunc | grep a7589ee429a36

# Inspect its config (PID, cgroupsPath, namespaces)
docker exec kind-control-plane crictl inspect a7589ee429a36

# Full host cgroup path
sudo find /sys/fs/cgroup -type d -name '*a7589ee429a36*'

# Key limits and usage
CG=$(sudo find /sys/fs/cgroup -type d -name '*a7589ee429a36*')
for f in cpu.max cpu.weight memory.max memory.current pids.max cgroup.procs; do
  printf '%-16s %s\n' "$f" "$(cat "$CG/$f")"
done

# Was it CPU-throttled?
grep -E 'nr_periods|nr_throttled|throttled_usec' "$CG/cpu.stat"

# Was it OOM-killed?
cat "$CG/memory.events"

# Show the node's cgroup tree
systemd-cgls /system.slice/docker-3ea19abd45c6c9eeb987f97a49cc1de8c20f2595d7ac8186cc6660c59e594a80.scope

# Show the node's aggregate usage
docker stats kind-control-plane --no-stream
```

### Key takeaways

1. `"pid": 1` is the container's view; `"pid": 1608` is the kind node's view.
   The host sees yet another PID.
2. `systemd_cgroup: true` means the cgroup is a systemd `.scope`, described by
   `slice:prefix:name`.
3. The cgroup namespace explains the path difference: inside the node the root
   is `kubelet.slice`; on the host it is nested under the kind node's Docker
   scope.
4. In KIND, every cgroup path has an extra `docker-<id>.scope` level because
   the Kubernetes node is itself a container.
5. The **same host kernel** enforces every level. There is no kernel inside the
   kind node or the pod.
6. Limits are **nested**: the effective memory limit, PID limit, and CPU quota
   are the smallest/most restrictive values on the path from the container up
   to the host.
7. `memory.current` and `pids.current` include descendants; `cgroup.procs`
   lists only direct members.
8. `cgroup.procs` is the bridge between container PIDs and host PIDs.
9. On cgroup v2, `limits` become `cpu.max`/`memory.max`, and CPU `requests`
   mostly become `cpu.weight`.
