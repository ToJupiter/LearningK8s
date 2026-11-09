# Kubeconfig with Kind

``` bash
export KUBECONFIG="$HOME/.kube/kind-multinode.yaml"
```

# Experiment

1. WSL2 host:
$ readlink /proc/1/ns/net
net:[4026531833]

2. multinode-control-plane:
$ docker exec multinode-control-plane ip -br addr
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if22        UP             172.18.0.5/16 fc00:f853:ccd:e793::5/64 fe80::5438:71ff:fe06:e02d/64
veth7819a59f@if2 UP             10.244.0.1/32 fe80::b8c9:bbff:feaa:a241/64
veth080b544e@if2 UP             10.244.0.1/32 fe80::184e:83ff:fe5a:f652/64
veth079d200f@if2 UP             10.244.0.1/32 fe80::e0ca:6eff:fe3e:50a5/64

3. multinode-worker:
root@kind-host:~/K8sLearning/Dev/Kind_Demo/depl# docker exec multinode-worker readlink /proc/1/ns/net
net:[4026532885]
root@kind-host:~/K8sLearning/Dev/Kind_Demo/depl# docker exec multinode-worker2 readlink /proc/1/ns/net
net:[4026533013]
root@kind-host:~/K8sLearning/Dev/Kind_Demo/depl# docker exec multinode-worker ip -br addr
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if21        UP             172.18.0.4/16 fc00:f853:ccd:e793::4/64 fe80::9c54:9eff:fedd:dd75/64
root@kind-host:~/K8sLearning/Dev/Kind_Demo/depl# docker exec multinode-worker2 ip -br addr
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if20        UP             172.18.0.3/16 fc00:f853:ccd:e793::3/64 fe80::24e4:21ff:fefc:4e7e/64

# Multinode network connection:
========== multinode-control-plane ==========
lo               UNKNOWN        127.0.0.1/8
eth0@if22        UP             172.18.0.5/16
veth7819a59f@if2 UP             10.244.0.1/32
veth080b544e@if2 UP             10.244.0.1/32
veth079d200f@if2 UP             10.244.0.1/32
default via 172.18.0.1 dev eth0
10.244.0.2 dev veth079d200f scope host
10.244.0.3 dev veth080b544e scope host
10.244.0.4 dev veth7819a59f scope host
10.244.1.0/24 via 172.18.0.3 dev eth0
10.244.2.0/24 via 172.18.0.4 dev eth0
172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.5
========== multinode-worker ==========
lo               UNKNOWN        127.0.0.1/8
eth0@if21        UP             172.18.0.4/16
default via 172.18.0.1 dev eth0
10.244.0.0/24 via 172.18.0.5 dev eth0
10.244.1.0/24 via 172.18.0.3 dev eth0
172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.4
========== multinode-worker2 ==========
lo               UNKNOWN        127.0.0.1/8
eth0@if20        UP             172.18.0.3/16
default via 172.18.0.1 dev eth0
10.244.0.0/24 via 172.18.0.5 dev eth0
10.244.2.0/24 via 172.18.0.4 dev eth0
172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.3

