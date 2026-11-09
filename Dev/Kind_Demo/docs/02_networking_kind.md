# 02 — Networking in KIND: where every network adapter lives

This note explains a real `ip addr` output taken **inside a KIND control-plane
node**, and then goes deeper: what each adapter is, where it physically sits,
how pods talk to each other, and how traffic escapes to the internet.

> **Prerequisite:** read `01_cgroup_kind_inspection.md` first. The key fact
> you need: **a KIND "node" is just a Docker container** — not a VM.

---

## The raw output we are explaining

Run inside the node (`docker exec -it kind-control-plane ip addr`):

```
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host proto kernel_lo

2: eth0@if5: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default
    link/ether 1a:0d:35:af:72:50 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 172.18.0.2/16 brd 172.18.255.255 scope global eth0
    inet6 fc00:f853:ccd:e793::2/64 scope global nodad
    inet6 fe80::180d:35ff:feaf:7250/64 scope link proto kernel_ll

3: vethabf907e9@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP
    link/ether c2:5b:0c:83:fc:18 brd ff:ff:ff:ff:ff:ff link-netnsid 1
    inet 10.244.0.1/32 scope global vethabf907e9

4: vethe5a001b9@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP
    link/ether 22:b9:b7:6e:57:da brd ff:ff:ff:ff:ff:ff link-netnsid 2
    inet 10.244.0.1/32 scope global vethe5a001b9

5: veth4755f4b7@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP
    link/ether 02:aa:69:1a:03:5a brd ff:ff:ff:ff:ff:ff link-netnsid 3
    inet 10.244.0.1/32 scope global veth4755f4b7
    inet6 fe80::aa:69ff:fe1a:35a/64 scope link proto kernel_ll
```

**One-line summary:** `lo` is local, `eth0` is the node's connection to the
outside world (Docker's network), and the three `veth*` interfaces are the
node-side ends of the cables going into three pods.

---

## 0. Beginner primer: 6 concepts you need first

If you only know basic Linux, these six ideas explain everything above.

### 0.1 A network interface ("adapter")

An **interface** is a named endpoint that sends and receives network packets:
`eth0`, `lo`, `wlan0`... In containers you'll see names like `veth1234`.

`ip addr` lists every interface in the **current network namespace** (see 0.3).

```
2: eth0@if5: ... state UP
```

- `2:` — kernel index number of the interface.
- `eth0` — its name.
- `@if5` — "the other end of my cable is interface #5 somewhere else."
- `state UP` — the link is operational.

### 0.2 An IP address and a prefix (`10.244.0.1/32`)

- The IP (`10.244.0.1`) identifies *which* interface/node you mean.
- The part after `/` (**prefix length**) says how many leading bits are the
  *network* portion:
  - `/8`, `/16`, `/24` → a *range* of addresses on the same network
    (`10.0.0.0/8` = 10.0.0.0 – 10.255.255.255).
  - `/32` → exactly **one** single address, no range.
- **Why `/32` on the veths matters:** there is no shared broadcast network
  between them. The kernel keeps a *separate single-address route per
  interface* instead of one big shared LAN. More on this in section 4.

### 0.3 A network namespace (`netns`)

A **network namespace** is a Linux kernel feature: a *private copy of the
network stack* — its own interfaces, IPs, routes, sockets, and ports.

**This is the single most important concept in this document:**

| Where | Its netns contains |
|---|---|
| Your laptop / WSL host | `eth0`/`ens`, the docker bridge `docker0`, ... |
| The KIND node container | `lo`, `eth0`, `veth*` ← **the output above** |
| Each pod | `lo`, `eth0` (its own private IP!) |

Two namespaces are isolated by default: a process in one **cannot see** the
interfaces of the other. They only meet where something explicitly connects
them (a veth pair, a bridge, NAT...).

`link-netnsid N` in the output is the kernel telling you: *"the peer end of
this interface lives in namespace #N."*

### 0.4 A veth pair = a virtual cable

`veth` (virtual ethernet) always comes in **pairs**, like a patch cable with
a plug on both ends:

```
   [ namespace A ]                     [ namespace B ]
   interface eth0  ◄════════════════►  interface eth0
        (one end)        veth pair        (other end)
```

- Packets sent into one end **come out the other end**, and vice versa.
- You create them together: `ip link add vethA type veth peer name vethB`.
- Then you *move* one end into another namespace with `ip link set vethB netns <ns>`.
- **Nothing routes or translates** — it's a wire. If both ends are `UP`, the
  link is `UP`.

That's why every line says `...@if2` or `...@if5`: *"my partner is interface
#2/#5 in some other namespace."*

### 0.5 A bridge = a virtual switch

A **bridge** is a virtual Layer-2 switch: plug several interfaces into it and
they can talk to each other directly (like plugging laptops into a switch).

Famous example: `docker0` on your host. In **this particular KIND output there
is no bridge for pods** — pods are wired directly by routes (section 4). But
you *will* meet bridges elsewhere (e.g. `cni0` in kubeadm clusters, `docker0`
on your laptop).

### 0.6 NAT (network address translation)

**NAT** rewrites packet headers as they pass through, usually so that many
machines with private IPs can share **one public IP**.

```
pod (10.244.0.5) ──► node rewrites source to 172.18.0.2 ──► internet
                                                          (reply comes back
                                                           and is un-rewritten)
```

You'll see it implemented as `iptables`/`nftables` rules (`MASQUERADE`,
`SNAT`, `DNAT`). Kubernetes' `kube-proxy` and every CNI lean heavily on this.

---

## 1. The big picture: where these adapters are physically

Here is the **full nesting**, from your real hardware down to a pod. Read it
top to bottom — each box is a network namespace.

```
┌─────────────────────────────────────────────────────────────────────────┐
│ ① YOUR MACHINE (WSL / laptop) — netns #0                               │
│                                                                         │
│    [docker0 / br-xxxx bridge ]  172.18.0.1/16        (a virtual switch) │
└───────────────────────────────────┬─────────────────────────────────────┘
                                    │  virtual cable (veth pair,
                                    │  one end in your netns,
                                    │  one end inside the node)
┌───────────────────────────────────▼─────────────────────────────────────┐
│ ② KIND NODE = a Docker container — netns (the one "ip addr" ran in)     │
│                                                                         │
│    lo          127.0.0.1                                                │
│    eth0        172.18.0.2  ◄── node's "outside world" address           │
│    vethabf907e9 10.244.0.1 ─┐                                          │
│    vethe5a001b9 10.244.0.1 ─┤ all three are the node's end of a cable  │
│    veth4755f4b7 10.244.0.1 ─┘                                          │
│                                                                         │
│    kube-proxy, kubelet, containerd, kindnetd (CNI agent) run here      │
└───────┬──────────────────┬──────────────────┬───────────────────────────┘
        │ veth pair        │ veth pair        │ veth pair
        │ (peer = if2)     │ (peer = if2)     │ (peer = if2)
┌───────▼──────┐  ┌────────▼───────┐  ┌───────▼──────┐
│ ③ POD #1     │  │ ③ POD #2       │  │ ③ POD #3     │   ← each pod is
│  netns       │  │  netns         │  │  netns       │     its OWN netns
│              │  │                │  │              │
│  eth0        │  │  eth0          │  │  eth0        │
│  10.244.0.5  │  │  10.244.0.6    │  │  10.244.0.7  │   ← pod's private IP
└──────────────┘  └────────────────┘  └──────────────┘
```

**Answers to "where is it placed?":**

| Adapter | Lives in... | Its peer lives in... |
|---|---|---|
| `docker0` / `br-xxxx` | **Your machine** (WSL host netns) | the node's `eth0` end |
| node's `eth0` | **Inside the KIND node container** | the bridge on your machine |
| node's `veth*` (3 of them) | **Inside the KIND node container** | each pod's `eth0` |
| pod's `eth0` | **Inside the pod container** | the matching node `veth*` |

> **Not inside a VM anywhere.** There is exactly **one Linux kernel** — yours.
> Namespaces + cgroups are what make these boxes *look* like separate machines.

---

## 2. Line-by-line decoding of the output

### 2.1 `lo` — the loopback

```
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 ... state UNKNOWN
   inet 127.0.0.1/8 scope host lo
```

- Every namespace has a `lo`. It's how processes **talk to themselves**
  (`127.0.0.1`). The node's kubelet, API server, kube-proxy all use it to
  reach services listening locally.
- `state UNKNOWN` is *normal* for loopback — there is no physical peer to
  report carrier status for.
- `mtu 65536` — huge because no physical wire constrains it (MTU = maximum
  size of one packet in bytes; default Ethernet = 1500).
- `scope host` — this address is only meaningful **inside this namespace**.

### 2.2 `eth0@if5` — the node's door to the outside

```
2: eth0@if5: ... mtu 1500 ... state UP
   link/ether 1a:0d:35:af:72:50 ... link-netnsid 0
   inet 172.18.0.2/16 brd 172.18.255.255 scope global eth0
   inet6 fc00:f853:ccd:e793::2/64 scope global nodad
   inet6 fe80::180d:35ff:feaf:7250/64 scope link proto kernel_ll
```

- **`@if5` + `link-netnsid 0`** — the cable goes out to namespace #0, which
  is *your machine*. On your machine that peer is plugged into the Docker
  bridge (`docker0` or `br-xxxx`).
- **`172.18.0.2/16`** — KIND assigned the node this address on Docker's
  private network. This is the address **your laptop uses to reach the node**
  (e.g. when `kubectl` talks to the API server on a published port), and the
  address the node uses to reach the internet.
- `scope global` — usable beyond this namespace (vs. `scope host` on `lo`).
- **IPv6 trio:**
  - `fc00:...::2/64 scope global nodad` — a ULA (private) global address;
    `nodad` = skip duplicate-address detection (speeds startup).
  - `fe80::.../64 scope link proto kernel_ll` — **link-local** address: auto-
    generated, only valid *on this one link*, never routed. `proto kernel_ll`
    = "the kernel created this, not a user."

### 2.3 `veth*` — the cables into the pods

```
3: vethabf907e9@if2: ... state UP ... link-netnsid 1
   inet 10.244.0.1/32 scope global vethabf907e9
4: vethe5a001b9@if2: ... link-netnsid 2
   inet 10.244.0.1/32 scope global vethe5a001b9
5: veth4755f4b7@if2: ... link-netnsid 3
   inet 10.244.0.1/32 scope global veth4755f4b7
```

- **Three interfaces → three pods are attached to this node right now.**
- `@if2` — inside *each* pod, the peer end is named `eth0` and has kernel
  index 2 (because `lo` took index 1). Every pod looks identical from inside.
- `link-netnsid 1 / 2 / 3` — the three different pod namespaces.
- **All three carry `10.244.0.1/32`.** This surprises people, but it's fine:
  they are three *separate* L2 links (three separate cables), so the same IP
  can exist on each without conflict. From any pod's point of view, the node
  is `10.244.0.1`.
- **`/32`** = no shared subnet, no broadcast between pods. Instead the node
  holds a *route per pod* (section 4).
- The MAC starts with `02:` → **locally administered** address (randomly
  generated by the kernel for virtual devices, not burned into hardware).

### 2.4 The flag soup, decoded

| You see | Means |
|---|---|
| `UP` | link is usable (`LOWER_UP` = the "cable" is plugged) |
| `state UNKNOWN` | only normal on `lo` |
| `mtu 1500` | standard Ethernet packet size |
| `qdisc noqueue` | no traffic-shaping queue on this interface |
| `scope host` / `link` / `global` | address valid in this ns / on this link / everywhere |
| `valid_lft forever` | the address never expires (not DHCP) |
| `brd ff:ff:ff:ff:ff:ff` | broadcast MAC (normal) |

---

## 3. How a pod gets wired up (the lifecycle)

When you `kubectl apply` a Deployment, here is the networking part, in order:

1. **kubelet** on the node asks the CNI plugin (in KIND: **kindnetd**) to set
   up networking for the new pod.
2. The CNI creates a **netns** for the pod (this is the `netnsid 1/2/3` you
   saw).
3. It creates a **veth pair**:
   - one end is moved into the pod's netns and renamed **`eth0`**;
   - the other end stays in the node's netns with a random name
     (`vethabf907e9`...).
4. It assigns the pod an IP from the **pod CIDR** (`10.244.0.0/24` here) —
   e.g. `10.244.0.5` → `kubectl get pod -o wide` shows this IP.
5. It adds routes:
   - **in the pod:** default route `0.0.0.0/0 → 10.244.0.1` (via `eth0`);
   - **in the node:** `10.244.0.5/32 → dev vethabf907e9` (the specific cable
     for that pod).
6. It programs `iptables`/`nftables` so traffic can leave (NAT) and so
   `kube-proxy` rules exist for Services.

**Verify it yourself:**

```bash
# inside the node
ip addr                 # what you saw above
ip route                # the per-pod routes from step 5
# inside a pod
ip route                # default via 10.244.0.1
```

---

## 4. How pods talk to EACH OTHER (same node)

Two pods on the **same node** — pure L3 routing, no bridge involved:

```
Pod #1 (10.244.0.5)                node root netns                Pod #2 (10.244.0.6)
┌────────────────┐   ┌──────────────────────────────────┐   ┌────────────────┐
│ app → 10.244.0.6│   │ route: 10.244.0.6/32             │   │                │
│                 │   │        dev vethe5a001b9          │   │                │
│ default gw      │   │                                  │   │                │
│  = 10.244.0.1   │   │                                  │   │                │
└───────┬─────────┘   └───────────────┬──────────────────┘   └───────┬────────┘
        │  out eth0                   │  out vethe5a001b9             │ in eth0
        ▼                             ▼                               ▲
     vethabf907e9 ══════════ node routes it ═══════════════════ vethe5a001b9
```

Step by step:

1. Pod #1 looks up `10.244.0.6`. Not on its local link → send to its **default
   gateway `10.244.0.1`** (that's the node, seen from inside the pod).
2. The packet arrives at the node via `vethabf907e9`.
3. The node consults its routing table, which has an exact `/32` route:
   *"`10.244.0.6` → send out `vethabf907e9`'s partner, `vethe5a001b9`."*
4. The packet exits `vethe5a001b9` and **emerges inside Pod #2's `eth0`**.
   Done — no NAT needed, both ends already have real (cluster-internal) IPs.

> **Key insight:** the node acts as a **router** between pods. The veth pairs
> are just the cables plugged into that router.

---

## 5. How a pod talks to a pod on ANOTHER node

(You only have one node right now, but you need this for the exam/interviews.)

```
Pod A (node 1) ──veth──► node 1 ── eth0: 172.18.0.2 ── docker bridge ── eth0: 172.18.0.3 ── node 2 ──veth──► Pod B
```

1. Same as above until the packet hits node 1.
2. Node 1 has no `/32` route for Pod B (it's not local) → forwards it to the
   **next node** across `eth0` (the Docker network).
3. Node 2 receives it, finds Pod B's `/32` route, pushes it down Pod B's veth.

This is **plain IP routing between nodes**. Overlays (VXLAN, WireGuard — as
used by Flannel/Cilium) are just an *optional* way to carry these packets when
the underlying network doesn't already know the pod CIDRs. KIND's default CNI
(kindnetd) does the simple version: the Docker bridge already connects all
nodes, so it just routes.

---

## 6. How a pod reaches the INTERNET (and outside → pod)

### 6.1 Pod → internet (egress)

```
Pod (10.244.0.5:54321)
   │  dst = 93.184.216.34 (example.com),  src = 10.244.0.5
   ▼
node: iptables MASQUERADE/SNAT rule
   │  rewrites src → 172.18.0.2   (the node's eth0 IP)
   ▼
node eth0 (172.18.0.2)  ──► docker bridge (172.18.0.1)
   ▼
your WSL/laptop netns  ── NAT again (docker's own MASQUERADE) ──► real NIC ──► internet
```

Why two rewrites? Because `10.244.0.5` and `172.18.0.2` are both **private
RFC1918 addresses** that the internet will not route. Somewhere on the path
the source must become a **public** IP — that's your router/ISP NAT at the
very end.

**Rules of thumb:**
- Pod → internet: needs **MASQUERADE/SNAT** on the node (CNI/kube-proxy sets
  this up). If internet fails from a pod but works on the node, check these
  `iptables` rules first.
- Return packets are un-rewritten by the **conntrack** table (the kernel
  remembers the mapping).

### 6.2 Internet / outside → pod (ingress)

Raw internet traffic **cannot** find a pod directly (private IP). It comes in
via one of:

1. **NodePort / LoadBalancer Service** → `kube-proxy` on the node DNAT's
   `nodeIP:30080` → pod IP. This is why KIND publishes ports to your laptop
   (`kind-config` `extraPortMappings`).
2. **Ingress controller** (nginx) → terminates HTTP, then forwards to
   Services.
3. For `kubectl` itself: your laptop → `localhost:<published-port>` →
   node `eth0` → API server on `127.0.0.1:6443` inside the node.

---

## 7. Quick "which adapter do I use?" cheat sheet

| I want to... | Traffic goes out... |
|---|---|
| A process on the node reaching itself | `lo` (127.0.0.1) |
| Node → internet / node → your laptop | `eth0` (172.18.0.2) |
| Node → a specific pod | the matching `veth*` |
| Pod → another pod (same node) | pod `eth0` → node routes → other `veth*` |
| Pod → internet | pod `eth0` → node SNAT → `eth0` |
| Your laptop → a Service/NodePort | `eth0` of the node, then DNAT |

---

## 8. Common beginner "huh?" moments

1. **Three interfaces with the same IP `10.244.0.1`** — not a bug; three
   separate links, each can reuse the address. (Section 2.3.)
2. **`/32` instead of `/24`** — no shared LAN between pods; the node keeps
   one route per pod. (Section 2.3 / 4.)
3. **`@if2` on every pod-facing veth** — because inside every pod the peer is
   `eth0` at index 2. Pods are clones of each other from the network's view.
4. **`state UNKNOWN` on `lo`** — normal, not an error.
5. **"Is the pod a separate machine?"** — no. Same kernel, only a netns +
   cgroup separate it. See doc 01.
6. **Why does `ip addr` inside the node not show pod `eth0`s?** — because
   they're in *other namespaces*. The node only sees its own end of each
   cable. Use `nsenter -t <pid> -n ip addr` from the node to peek inside a
   pod.

---

## 9. Suggested experiments (read-only, safe)

```bash
# --- on your laptop ---
docker exec -it kind-control-plane ip addr          # the output above
docker exec -it kind-control-plane ip route          # per-pod /32 routes
docker exec -it kind-control-plane ip netns          # (may be empty; use crictl)

# --- inside the node ---
docker exec -it kind-control-plane sh -c 'ip route'
docker exec -it kind-control-plane crictl pods      # list pods → find one
docker exec -it kind-control-plane crictl inspect <pod-id> | grep -i pid

# --- inside a pod (replace POD and CONTAINER) ---
kubectl get pod -o wide                             # shows node, pod IP
kubectl exec -it POD -- ip addr
kubectl exec -it POD -- ip route                    # default via 10.244.0.1
kubectl exec -it POD -- ping -c3 10.244.0.1         # reach the node
kubectl exec -it POD -- ping -c3 8.8.8.8            # reach the internet
```

**Mapping exercise:** pick a pod IP from `kubectl get pod -o wide`, then find
its `/32` route in `ip route` inside the node, and confirm which `veth*` it
points at. That single connection is the whole document in miniature.
