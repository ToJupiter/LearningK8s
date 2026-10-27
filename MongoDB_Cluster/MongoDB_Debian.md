Kế hoạch LAB MongoDB High Availability trên Debian WSL
======================================================

Mục tiêu: Mô phỏng hệ thống 3 MongoDB (1 Primary \+ 2 Secondary), 1 VIP, HAProxy và Keepalived trên một máy tính cá nhân, hoàn toàn độc lập với môi trường nội bộ.

Tôi chọn giải pháp Docker Compose \+ Docker Network mô phỏng các máy chủ riêng biệt. Đây là phương án phù hợp nhất với một máy Debian WSL2: vẫn kiểm thử được Replica Set election, HAProxy nhận biết Primary, Keepalived chuyển VIP và khôi phục kết nối sau sự cố.

Tôi cũng đã tạo một bộ cấu hình lab gồm Docker Compose, HAProxy, Keepalived, MongoDB health checker và script thử nghiệm.

Bộ LAB MongoDB HA

Docker Compose · 3 MongoDB · 2 HAProxy · 2 Keepalived · Client

Tải bộ cấu hình MongoDB HA Lab (.tar.gz)

Đã tạo các file cấu hình và script. Chưa thực thi kiểm thử Docker thực tế vì môi trường tạo file không có Docker Engine.

1\. Kiến trúc LAB
-----------------

Logical topology – Single WSL2 Host

Tất cả đều chạy trong Docker namespaces trên cùng một WSL2. Vai trò Primary có thể di chuyển giữa ba MongoDB, độc lập với VM proxy đang giữ VIP.

### Bảng địa chỉ IP giả lập

Toàn bộ địa chỉ dưới đây là IP của mạng Docker riêng, không liên quan đến các địa chỉ hạ tầng thực tế.

|   Thành phần   |   IP lab   |   Vai trò   |
| --- | --- | --- |
|   MongoDB 1   |   `172.30.77.11`   |   Replica Set member   |
|   MongoDB 2   |   `172.30.77.12`   |   Replica Set member   |
|   MongoDB 3   |   `172.30.77.13`   |   Replica Set member   |
|   Health checker 1–3   |   `.21–.23`   |   Xác định Primary   |
|   Proxy A   |   `172.30.77.31`   |   HAProxy \+ Keepalived   |
|   Proxy B   |   `172.30.77.32`   |   HAProxy \+ Keepalived   |
|   VIP   |   `172.30.77.100`   |   Endpoint của ứng dụng   |
|   Client   |   `172.30.77.41`   |   Mô phỏng ứng dụng   |

Mỗi MongoDB vẫn nghe cổng `27017`. Hai HAProxy cũng nghe `27017`, nhưng trong các network namespace riêng, vì vậy không xảy ra xung đột cổng.

Lưu ý về systemd: Trên production, HAProxy và Keepalived chạy bằng `systemctl`. Trong lab này, chúng chạy dưới dạng tiến trình bên trong container. Ta mô phỏng được hoạt động HA, VRRP và failover, nhưng không kiểm thử chính xác việc quản lý service bằng systemd trên ba VM độc lập.

2\. Những nội dung LAB sẽ kiểm chứng
------------------------------------

|   Kịch bản   |   Mục tiêu   |   Kết quả kỳ vọng   |
| --- | --- | --- |
|   LAB01   |   Khởi tạo 3 MongoDB   |   Có 1 Primary, 2 Secondary   |
|   LAB02   |   Ghi dữ liệu qua VIP   |   Ghi thành công trên Primary   |
|   LAB03   |   Dừng MongoDB Primary   |   Secondary được bầu Primary mới   |
|   LAB04   |   MongoDB thay Primary   |   HAProxy tự chọn Primary mới   |
|   LAB05   |   Dừng HAProxy/VIP owner   |   Keepalived chuyển VIP sang proxy còn lại   |
|   LAB06   |   Khởi động lại proxy lỗi   |   Hệ thống phục hồi   |
|   LAB07   |   Mất quorum MongoDB   |   Không chuyển ghi sang Secondary   |
|   LAB08   |   Khôi phục các node MongoDB   |   Replica Set trở lại trạng thái ổn định   |

Mục tiêu quan trọng nhất là phân biệt hai quá trình:

MongoDB failover: Primary thay đổi nhưng VIP có thể không thay đổi vị trí.

Proxy failover: VIP thay đổi vị trí nhưng MongoDB Primary có thể vẫn giữ nguyên.

Đây cũng chính là lý do sử dụng HAProxy kết hợp Keepalived thay vì yêu cầu VIP luôn nằm trên MongoDB Primary.

3\. Chuẩn bị Debian WSL2
------------------------

Khuyến nghị tối thiểu:

|   Tài nguyên   |   Cấu hình   |
| --- | --- |
|   OS   |   Debian trên WSL2   |
|   CPU   |   4 vCPU   |
|   RAM   |   6–8 GB khả dụng   |
|   Storage   |   5–10 GB trống   |
|   Docker   |   Docker Engine \+ Compose v2   |
|   Internet   |   Để tải Docker images và build health checker   |
|   Quyền   |   Có quyền chạy Docker   |

Trước tiên kiểm tra:

    cat /etc/os-release
    docker --version
    docker compose version
    docker info

Nếu dùng Docker Desktop trên Windows, cần bật WSL Integration cho Debian. Nếu chạy Docker Engine trực tiếp trong Debian WSL, bảo đảm Docker daemon đang hoạt động.

Không cần tạo thêm VM, cài MongoDB trực tiếp lên WSL hay chỉnh sửa địa chỉ IP trên máy Windows.

4\. Triển khai LAB
------------------

### Bước 1 – Giải nén bộ cấu hình

Tải file `.tar.gz` ở trên, chuyển vào thư mục home của Debian WSL, rồi chạy:

    mkdir -p ~/mongodb-ha-lab
    cd ~/mongodb-ha-lab
    
    tar -xzf /path/to/mongodb-wsl-ha-lab.tar.gz

Thay `/path/to/...` bằng vị trí file sau khi tải.

Cấu trúc thư mục:

    mongodb-ha-lab/
    ├── compose.yaml
    ├── README.md
    ├── health/
    │   ├── Dockerfile
    │   └── health.py
    ├── proxy/
    │   ├── Dockerfile
    │   ├── haproxy.cfg
    │   ├── keepalived-a.conf
    │   ├── keepalived-b.conf
    │   ├── check-haproxy.sh
    │   └── start.sh
    └── scripts/
        ├── init-replica.sh
        └── status.sh

### Bước 2 – Khởi động toàn bộ hệ thống

    docker compose up -d --build

Kiểm tra:

    docker compose ps

Dự kiến có 9 container: 3 MongoDB, 3 health checker, 2 proxy và 1 client.

### Bước 3 – Khởi tạo MongoDB Replica Set

Chạy một lần:

    bash scripts/init-replica.sh

Script sẽ khởi tạo Replica Set tên `labrs` và đăng ký ba MongoDB member.

Kiểm tra:

    bash scripts/status.sh

Nếu MongoDB vừa khởi động, có thể cần một khoảng ngắn để hoàn tất election và các health check bắt đầu trả kết quả ổn định.

### Bước 4 – Kiểm tra truy cập VIP

Từ container client:

    docker compose exec client mongosh \
      'mongodb://172.30.77.100:27017/?directConnection=true' \
      --eval 'db.hello()'

Kết quả mong đợi:

    {
      isWritablePrimary: true,
      setName: "labrs"
    }

Điều đó chứng minh một kết nối mới qua VIP đã đến Primary tại thời điểm kiểm tra.

### Bước 5 – Thử nghiệm ghi dữ liệu

    docker compose exec client mongosh \
      'mongodb://172.30.77.100:27017/labtest?directConnection=true' \
      --eval '
        db.checks.insertOne({
          event: "before_failover",
          at: new Date()
        });
        printjson(db.checks.find().toArray());
      '

Kiểm tra dữ liệu trên cả ba MongoDB thông qua Replica Set sau khi replication hoàn tất.

5\. Thực hiện hai bài test quan trọng nhất
------------------------------------------

### Test A – MongoDB Primary failover

Đầu tiên xác định Primary:

    bash scripts/status.sh

Giả sử `mongo1` đang là Primary, dừng container đó:

    docker compose stop mongo1

Kiểm tra:

    bash scripts/status.sh

Kỳ vọng `mongo2` hoặc `mongo3` trở thành Primary mới. HAProxy sẽ thay đổi backend thông qua HTTP health check, trong khi VIP vẫn có thể nằm trên Proxy A.

Kiểm tra kết nối mới qua VIP và thực hiện thêm một thao tác ghi thử nghiệm.

Khôi phục:

    docker compose start mongo1

MongoDB 1 sẽ tham gia lại Replica Set. Không nên mặc định rằng node này sẽ lập tức trở thành Primary.

### Test B – Keepalived VIP failover

Kiểm tra VIP owner:

    docker compose exec proxy1 ip -4 addr show eth0
    docker compose exec proxy2 ip -4 addr show eth0

Giả sử `proxy1` đang giữ `172.30.77.100`, chạy:

    docker compose stop proxy1

Kiểm tra:

    docker compose exec proxy2 ip -4 addr show eth0

Kỳ vọng VIP chuyển sang `proxy2`.

Tiếp tục thử kết nối MongoDB qua VIP để xác nhận khả năng truy cập Primary.

Khôi phục:

    docker compose start proxy1

Lưu ý rằng các kết nối TCP đang tồn tại khi proxy bị dừng sẽ bị ngắt. HAProxy và Keepalived không tự động di chuyển phiên TCP sang proxy khác; ứng dụng phải có cơ chế reconnect.

6\. Những điểm khác biệt so với môi trường 3 VM thực
----------------------------------------------------

|   Thành phần   |   Production 3 VM   |   Lab một WSL2   |
| --- | --- | --- |
|   MongoDB   |   Docker trên 3 VM   |   3 container trên 1 host   |
|   HAProxy   |   systemd trên VM   |   Tiến trình trong proxy container   |
|   Keepalived   |   systemd trên VM   |   Tiến trình trong proxy container   |
|   Network   |   Hệ thống mạng thật   |   Docker bridge   |
|   VIP   |   IP thuộc subnet thực   |   IP ảo thuộc Docker subnet   |
|   Quorum   |   Trải trên các VM   |   Trải trên các container   |
|   MongoDB election   |   Thực   |   Thực   |
|   Health check Primary   |   Thực   |   Thực   |
|   HAProxy backend switching   |   Thực   |   Thực   |
|   VRRP VIP migration   |   Mạng thật   |   Mô phỏng qua Docker bridge   |
|   Mất điện hoặc lỗi vật lý   |   Có khả năng chịu lỗi nếu thiết kế phù hợp   |   Toàn bộ lab cùng mất   |

Lab mặc định không bật authentication/TLS và không publish cổng MongoDB ra máy host. Chỉ sử dụng cho môi trường thử nghiệm cô lập. Không sao chép phần cấu hình bảo mật này sang production.

Ngoài ra, VRRP trên Docker Desktop/WSL có thể gặp hạn chế về network capability hoặc ARP. Nếu VIP không chuyển được dù Keepalived chạy, cần kiểm tra Docker networking trước khi kết luận cấu hình HA sai.

7\. Tiêu chí hoàn thành LAB
---------------------------

Checklist thực hành

0/10 hoàn thành

Docker Compose khởi động đủ 9 container

Replica Set có 1 Primary và 2 Secondary

Có đúng một proxy sở hữu VIP

Client kết nối VIP:27017 thành công

Ghi và đọc dữ liệu qua VIP thành công

Dừng Primary và bầu được Primary mới

HAProxy tự nhận biết Primary mới

Dừng proxy đang giữ VIP và VIP chuyển sang proxy còn lại

Client kết nối lại thành công sau failover

Khôi phục toàn bộ các container về trạng thái ổn định

Sau khi hoàn thành, bạn sẽ kiểm chứng được toàn bộ chuỗi:

MongoDB election → Primary health check → HAProxy backend switching → Keepalived VIP failover → Application reconnect.

Đây là bước chuẩn bị phù hợp trước khi mở rộng sang lab nhiều VM để kiểm thử systemd, network partition, fencing và khả năng khôi phục trong điều kiện hạ tầng thực tế.

Tài liệu đối chiếu: [MongoDB Replica Set Deployment](https://www.mongodb.com/docs/manual/tutorial/deploy-replica-set) và [HAProxy Health Checks](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/reliability/health-checks).

# PHỤ LỤC KỸ THUẬT
# LAB MongoDB Replica Set + HAProxy + Keepalived trên Debian WSL2

**Phiên bản:** 1.0  
**Môi trường:** Máy tính cá nhân, Debian WSL2, Docker Compose  
**Phạm vi:** LAB độc lập, không kết nối hệ thống nội bộ  
**Mục tiêu:** Tự xây dựng, vận hành và kiểm thử cơ chế High Availability cho MongoDB.

---

# 1. Tổng quan kiến trúc

## 1.1. Mục tiêu

Xây dựng mô hình bao gồm:

- 3 MongoDB chạy Replica Set: 1 Primary, 2 Secondary.
- 3 MongoDB Primary Health Checker.
- 2 HAProxy để định tuyến các kết nối TCP tới Primary.
- 2 Keepalived để quản lý một Virtual IP (VIP).
- 1 Client để mô phỏng ứng dụng sử dụng MongoDB.

Tất cả thành phần chạy trên **một Debian WSL2**, sử dụng Docker Compose và Docker Bridge Network.

Không cần tạo ba máy ảo riêng biệt.

## 1.2. Sơ đồ luồng kết nối

```text
               Debian WSL2
                    |
              Docker Engine
                    |
        Docker Network: mongo-ha-net
          172.30.77.0/24
                    |
             Application Client
              172.30.77.41
                    |
                    v
          VIP: 172.30.77.100
                TCP 27017
                    |
           +--------+--------+
           |                 |
           v                 v
       Proxy A             Proxy B
    172.30.77.31       172.30.77.32
       HAProxy             HAProxy
      Keepalived          Keepalived
           |                 |
           +--------+--------+
                    |
           Primary-aware routing
                    |
       +------------+------------+
       |            |            |
       v            v            v
    MongoDB 1    MongoDB 2    MongoDB 3
    .11:27017    .12:27017    .13:27017
       |            |            |
       +------------+------------+
                    |
              Replica Set
                  labrs
```

Hai HAProxy đều biết Primary thực tế. Keepalived quyết định proxy nào giữ VIP.

**MongoDB election và Keepalived VRRP election hoàn toàn độc lập.**

## 1.3. Quy hoạch địa chỉ

| Thành phần | IP | Cổng |
|---|---|---|
| MongoDB 1 | 172.30.77.11 | 27017 |
| MongoDB 2 | 172.30.77.12 | 27017 |
| MongoDB 3 | 172.30.77.13 | 27017 |
| Health 1 | 172.30.77.21 | 9201 |
| Health 2 | 172.30.77.22 | 9201 |
| Health 3 | 172.30.77.23 | 9201 |
| HAProxy A | 172.30.77.31 | 27017 |
| HAProxy B | 172.30.77.32 | 27017 |
| VIP | 172.30.77.100 | 27017 |
| Client | 172.30.77.41 | — |

Đây là dải IP giả lập. Trước khi triển khai, kiểm tra bằng `ip route` và thay subnet nếu trùng với mạng Docker hoặc VPN hiện hữu.

---

# 2. Chuẩn bị Debian WSL2

## 2.1. Kiểm tra WSL

Tại Windows PowerShell:

```powershell
wsl --list --verbose
```

Đảm bảo Debian đang sử dụng WSL version 2.

Trong Debian:

```bash
cat /etc/os-release
uname -a
```

## 2.2. Kiểm tra Docker

```bash
docker --version
docker compose version
docker info
```

Nếu chưa cài Docker, sử dụng Docker Desktop với WSL Integration hoặc cài Docker Engine theo hướng dẫn chính thức của Docker cho Debian.

Không cần cài MongoDB, HAProxy hoặc Keepalived trực tiếp vào Debian host.

## 2.3. Tạo thư mục LAB

```bash
mkdir -p ~/mongodb-ha-lab
cd ~/mongodb-ha-lab

mkdir -p health
mkdir -p proxy
mkdir -p scripts
```

Cấu trúc cuối cùng:

```text
mongodb-ha-lab/
├── compose.yaml
├── health/
│   ├── Dockerfile
│   └── health.py
├── proxy/
│   ├── Dockerfile
│   ├── haproxy.cfg
│   ├── keepalived-a.conf
│   ├── keepalived-b.conf
│   ├── check-haproxy.sh
│   └── start.sh
└── scripts/
    ├── init-replica.sh
    └── status.sh
```

---

# 3. Docker Compose

Tạo file:

```bash
nano compose.yaml
```

Nội dung đầy đủ:

```yaml
name: mongodb-ha-lab

x-mongo-common: &mongo-common
  image: mongo:7.0
  command:
    - mongod
    - --replSet
    - labrs
    - --bind_ip_all
  restart: unless-stopped
  networks:
    mongo-ha-net:

x-health-common: &health-common
  build: ./health
  restart: unless-stopped
  networks:
    mongo-ha-net:

x-proxy-common: &proxy-common
  build: ./proxy
  restart: unless-stopped
  cap_add:
    - NET_ADMIN
    - NET_RAW
  networks:
    mongo-ha-net:

services:

  mongo1:
    <<: *mongo-common
    hostname: mongo1
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.11
    volumes:
      - mongo1_data:/data/db

  mongo2:
    <<: *mongo-common
    hostname: mongo2
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.12
    volumes:
      - mongo2_data:/data/db

  mongo3:
    <<: *mongo-common
    hostname: mongo3
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.13
    volumes:
      - mongo3_data:/data/db

  health1:
    <<: *health-common
    environment:
      MONGO_HOST: mongo1
      REPLICA_SET: labrs
    depends_on:
      - mongo1
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.21

  health2:
    <<: *health-common
    environment:
      MONGO_HOST: mongo2
      REPLICA_SET: labrs
    depends_on:
      - mongo2
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.22

  health3:
    <<: *health-common
    environment:
      MONGO_HOST: mongo3
      REPLICA_SET: labrs
    depends_on:
      - mongo3
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.23

  proxy1:
    <<: *proxy-common
    hostname: proxy1
    environment:
      PROXY_ID: a
    depends_on:
      - health1
      - health2
      - health3
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.31

  proxy2:
    <<: *proxy-common
    hostname: proxy2
    environment:
      PROXY_ID: b
    depends_on:
      - health1
      - health2
      - health3
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.32

  client:
    image: mongo:7.0
    command: ["sleep", "infinity"]
    networks:
      mongo-ha-net:
        ipv4_address: 172.30.77.41

networks:
  mongo-ha-net:
    name: mongo-ha-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.77.0/24

volumes:
  mongo1_data:
  mongo2_data:
  mongo3_data:
```

Các volume được giữ lại khi dùng `docker compose down` thông thường. Dữ liệu chỉ bị xóa nếu chủ động dùng tùy chọn xóa volume.

Lưu ý: LAB chưa bật MongoDB authentication, TLS hoặc network firewall ở mức production. Không expose các container này lên Internet.

---

# 4. MongoDB Primary Health Checker

## 4.1. Nguyên lý

Health checker sử dụng MongoDB driver kết nối trực tiếp tới từng node.

```text
MongoDB node
      |
      v
db.adminCommand({hello:1})
      |
      +--- isWritablePrimary = true
      |             |
      |             v
      |          HTTP 200
      |
      +--- Secondary / Error
                    |
                    v
                 HTTP 503
```

Việc HAProxy chỉ kiểm tra TCP 27017 là không đủ vì cả Primary và Secondary đều mở cổng này.

## 4.2. File health/Dockerfile

```dockerfile
FROM python:3.12-slim

RUN pip install --no-cache-dir "pymongo>=4.10,<5"

WORKDIR /app

COPY health.py /app/health.py

CMD ["python", "-u", "/app/health.py"]
```

Đối với LAB dài hạn, nên khóa phiên bản PyMongo bằng một version cụ thể đã thử nghiệm để tránh thay đổi ngoài dự kiến.

## 4.3. File health/health.py

```python
import os
from http.server import BaseHTTPRequestHandler
from http.server import ThreadingHTTPServer
from pymongo import MongoClient

MONGO_HOST = os.getenv("MONGO_HOST", "mongo1")
REPLICA_SET = os.getenv("REPLICA_SET", "labrs")

client = MongoClient(
    host=MONGO_HOST,
    port=27017,
    directConnection=True,
    serverSelectionTimeoutMS=1000,
    connectTimeoutMS=1000,
    socketTimeoutMS=1000,
    maxPoolSize=2,
)

class Handler(BaseHTTPRequestHandler):

    def do_GET(self):

        if self.path != "/primary":
            self.send_response(404)
            self.end_headers()
            return

        try:
            hello = client.admin.command("hello")

            healthy = (
                hello.get("isWritablePrimary") is True
                and hello.get("setName") == REPLICA_SET
            )

        except Exception:
            healthy = False

        self.send_response(200 if healthy else 503)
        self.end_headers()

        self.wfile.write(
            b"PRIMARY" if healthy else b"NOT_PRIMARY"
        )

    def log_message(self, fmt, *args):
        pass


server = ThreadingHTTPServer(
    ("0.0.0.0", 9201),
    Handler
)

print(
    f"Health checker for {MONGO_HOST}",
    flush=True
)

server.serve_forever()
```

Mỗi health checker kiểm tra đúng một MongoDB:

- health1 → mongo1
- health2 → mongo2
- health3 → mongo3

`directConnection=True` rất quan trọng: nó buộc health checker truy vấn node cần kiểm tra, không tự động chuyển sang member khác qua Replica Set discovery.

---

# 5. HAProxy

## 5.1. File proxy/haproxy.cfg

```haproxy
global
    log stdout format raw local0
    maxconn 5000

defaults
    log global
    mode tcp
    option tcplog

    timeout connect 3s
    timeout client 1h
    timeout server 1h

frontend mongodb_frontend
    bind 0.0.0.0:27017
    default_backend mongodb_primary

backend mongodb_primary
    mode tcp
    balance first

    option httpchk
    http-check send meth GET uri /primary ver HTTP/1.1 hdr Host mongo-health
    http-check expect status 200

    default-server inter 2s fall 2 rise 2

    server mongo1 172.30.77.11:27017 check addr 172.30.77.21 port 9201
    server mongo2 172.30.77.12:27017 check addr 172.30.77.22 port 9201
    server mongo3 172.30.77.13:27017 check addr 172.30.77.23 port 9201
```

Phân biệt:

**Đường dữ liệu:**

```text
Client → HAProxy → MongoDB:27017
```

**Đường health check:**

```text
HAProxy → Health Checker:9201 → MongoDB:27017
```

`check addr` cho phép health check đến IP khác với IP backend phục vụ dữ liệu.

Mỗi lần chỉ Primary trả HTTP 200 nên backend của Secondary sẽ bị HAProxy đánh dấu DOWN cho lưu lượng ghi.

Nếu không có Primary, tất cả backend sẽ DOWN, không fallback sang Secondary.

---

# 6. Keepalived

## 6.1. File proxy/keepalived-a.conf

Dành cho Proxy A:

```text
global_defs {
    router_id LAB_PROXY_A
    enable_script_security
}

vrrp_script chk_haproxy {
    script "/usr/local/bin/check-haproxy.sh"
    interval 2
    timeout 2
    fall 2
    rise 2
    weight 0
    user root
}

vrrp_instance VI_MONGO {
    state BACKUP
    interface eth0
    virtual_router_id 77
    priority 120
    advert_int 1

    unicast_src_ip 172.30.77.31

    unicast_peer {
        172.30.77.32
    }

    virtual_ipaddress {
        172.30.77.100/24 dev eth0
    }

    track_script {
        chk_haproxy
    }
}
```

## 6.2. File proxy/keepalived-b.conf

Dành cho Proxy B:

```text
global_defs {
    router_id LAB_PROXY_B
    enable_script_security
}

vrrp_script chk_haproxy {
    script "/usr/local/bin/check-haproxy.sh"
    interval 2
    timeout 2
    fall 2
    rise 2
    weight 0
    user root
}

vrrp_instance VI_MONGO {
    state BACKUP
    interface eth0
    virtual_router_id 77
    priority 110
    advert_int 1

    unicast_src_ip 172.30.77.32

    unicast_peer {
        172.30.77.31
    }

    virtual_ipaddress {
        172.30.77.100/24 dev eth0
    }

    track_script {
        chk_haproxy
    }
}
```

Priority 120 và 110 chỉ quyết định proxy nào được ưu tiên giữ VIP khi cả hai đều khỏe mạnh.

Không liên quan tới MongoDB Primary.

Không dùng `nopreempt` trong bản thử nghiệm đầu tiên để dễ quan sát việc Proxy A giành lại VIP khi khôi phục. Điều này cũng có nghĩa sẽ có thêm một lần chuyển VIP lúc Proxy A hoạt động trở lại.

---

# 7. Docker Image cho HAProxy + Keepalived

## 7.1. File proxy/check-haproxy.sh

```sh
#!/bin/sh

pidof haproxy >/dev/null 2>&1 || exit 1

ss -lnt | grep -q ':27017 ' || exit 1

exit 0
```

Script kiểm tra tiến trình và listener HAProxy.

Health check này không yêu cầu MongoDB phải có Primary; do đó VIP vẫn có thể tồn tại trong thời gian Replica Set election. Khi ấy HAProxy không có backend ghi khả dụng.

## 7.2. File proxy/start.sh

```sh
#!/bin/sh

set -eu

if [ "$PROXY_ID" = "a" ]; then
    cp /etc/keepalived-a.conf \
       /etc/keepalived/keepalived.conf
else
    cp /etc/keepalived-b.conf \
       /etc/keepalived/keepalived.conf
fi

haproxy -c -f /etc/haproxy/haproxy.cfg
keepalived -t -f /etc/keepalived/keepalived.conf

haproxy -db -f /etc/haproxy/haproxy.cfg &
HAPROXY_PID=$!

keepalived -n -f /etc/keepalived/keepalived.conf &
KEEPALIVED_PID=$!

cleanup() {
    kill "$KEEPALIVED_PID" "$HAPROXY_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}

trap cleanup INT TERM

while kill -0 "$HAPROXY_PID" 2>/dev/null &&
      kill -0 "$KEEPALIVED_PID" 2>/dev/null
do
    sleep 1
done

cleanup
exit 1
```

Đây là cách khởi chạy hai daemon phục vụ LAB. Nó không thay thế cấu hình systemd production.

## 7.3. File proxy/Dockerfile

```dockerfile
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      haproxy \
      keepalived \
      iproute2 \
      procps \
      curl \
      ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY haproxy.cfg /etc/haproxy/haproxy.cfg

COPY keepalived-a.conf /etc/keepalived-a.conf
COPY keepalived-b.conf /etc/keepalived-b.conf

COPY check-haproxy.sh /usr/local/bin/check-haproxy.sh
COPY start.sh /usr/local/bin/start.sh

RUN chmod 755 \
    /usr/local/bin/check-haproxy.sh \
    /usr/local/bin/start.sh

CMD ["/usr/local/bin/start.sh"]
```

Trong Docker Compose, hai proxy đã được cấp `NET_ADMIN` và `NET_RAW` để Keepalived có thể quản lý địa chỉ IP ảo và trao đổi VRRP trên bridge network.

Nếu WSL/Docker không cho phép VRRP hoạt động đúng, cần kiểm tra capability, network namespace và Docker bridge trước khi kết luận cấu hình sai.

---

# 8. Khởi tạo MongoDB Replica Set

## 8.1. File scripts/init-replica.sh

```bash
#!/bin/bash
set -euo pipefail

echo "Initializing MongoDB Replica Set..."

docker compose exec -T mongo1 mongosh --quiet --eval '
  const config = {
    _id: "labrs",
    members: [
      {
        _id: 0,
        host: "mongo1:27017",
        priority: 2
      },
      {
        _id: 1,
        host: "mongo2:27017",
        priority: 1
      },
      {
        _id: 2,
        host: "mongo3:27017",
        priority: 1
      }
    ]
  };

  try {
    rs.initiate(config);
    print("Replica Set initialized");
  } catch (e) {
    if (e.code === 23 ||
        e.codeName === "AlreadyInitialized") {
      print("Replica Set already initialized");
    } else {
      throw e;
    }
  }
'
```

Phân bố priority:

| MongoDB | Priority |
|---|---:|
| mongo1 | 2 |
| mongo2 | 1 |
| mongo3 | 1 |

`mongo1` được ưu tiên trở thành Primary, nhưng không được bảo đảm luôn là Primary.

Việc chọn priority 2 giúp LAB dễ quan sát quá trình election và khả năng node ban đầu giành lại Primary khi phục hồi. Trong production cần đánh giá riêng chính sách election và re-election.

## 8.2. File scripts/status.sh

```bash
#!/bin/bash

set -u

echo "====== CONTAINERS ======"
docker compose ps

echo
echo "====== REPLICA SET ======"

docker compose exec -T mongo1 mongosh --quiet --eval '
  try {
    printjson(
      rs.status().members.map(m => ({
        name: m.name,
        state: m.stateStr,
        health: m.health
      }))
    );
  } catch (e) {
    print(e.message);
  }
' || true

echo
echo "====== VIP ON PROXY A ======"
docker compose exec -T proxy1 \
  ip -4 addr show dev eth0 || true

echo
echo "====== VIP ON PROXY B ======"
docker compose exec -T proxy2 \
  ip -4 addr show dev eth0 || true

echo
echo "====== HEALTH CHECK ======"

for name in health1 health2 health3
do
    echo -n "$name: "

    docker compose exec -T "$name" python -c '
import urllib.request
try:
    r = urllib.request.urlopen(
        "http://127.0.0.1:9201/primary",
        timeout=2
    )
    print(r.status)
except Exception as e:
    print(type(e).__name__)
' || true
done
```

Script `status.sh` dùng `mongo1` làm điểm truy vấn mặc định. Khi `mongo1` bị dừng, phần trạng thái Replica Set có thể không hiển thị; lúc đó truy vấn `mongo2` hoặc `mongo3`.

---

# 9. Khởi động toàn bộ LAB

## 9.1. Kiểm tra cấu hình Compose

```bash
cd ~/mongodb-ha-lab

docker compose config --quiet
```

Nếu báo lỗi, kiểm tra lại định dạng YAML và các đường dẫn file.

## 9.2. Cấp quyền script

```bash
chmod +x scripts/*.sh
chmod +x proxy/*.sh
```

## 9.3. Build và khởi động

```bash
docker compose up -d --build
```

Kiểm tra:

```bash
docker compose ps
```

Dự kiến có 9 container:

```text
mongo1
mongo2
mongo3

health1
health2
health3

proxy1
proxy2

client
```

## 9.4. Khởi tạo Replica Set

```bash
bash scripts/init-replica.sh
```

Đợi MongoDB hoàn thành election, rồi chạy:

```bash
bash scripts/status.sh
```

Kiểm tra Replica Set:

```bash
docker compose exec mongo1 mongosh \
  --eval 'rs.status()'
```

Điều kiện đạt:

- Ba MongoDB ở trạng thái khỏe mạnh.
- Có đúng một Primary.
- Hai Secondary.
- Health checker của Primary trả HTTP 200.
- Health checker Secondary trả HTTP 503.
- VIP nằm trên đúng một proxy.

---

# 10. Kiểm thử kết nối và ghi dữ liệu

## TEST 01 – Kiểm tra kết nối qua VIP

```bash
docker compose exec client mongosh \
  'mongodb://172.30.77.100:27017/?directConnection=true' \
  --eval 'db.adminCommand({hello:1})'
```

Trường quan trọng:

```javascript
isWritablePrimary: true
```

Đây là bằng chứng rằng kết nối TCP mới qua VIP đến Primary.

## TEST 02 – Ghi dữ liệu qua VIP

```bash
docker compose exec client mongosh \
  'mongodb://172.30.77.100:27017/labtest?directConnection=true' \
  --eval '
    db.checks.insertOne({
      event: "before_failover",
      timestamp: new Date()
    });

    printjson(db.checks.find().toArray());
  '
```

Kỳ vọng dữ liệu được ghi thành công.

## TEST 03 – Kiểm tra replication

Kết nối một Secondary trực tiếp:

```bash
docker compose exec client mongosh \
  'mongodb://mongo2:27017/labtest?directConnection=true' \
  --eval '
    db.getMongo().setReadPref("secondary");
    printjson(db.checks.find().toArray());
  '
```

Chỉ thực hiện test này khi `mongo2` đang là Secondary. Nếu role đã thay đổi, chọn node Secondary khác.

Kết quả mong đợi: sau khi replication hoàn tất, dữ liệu ghi trước đó có mặt tại Secondary.

---

# 11. Thử nghiệm MongoDB failover

## TEST 04 – Dừng Primary

Xác định Primary thực tế:

```bash
docker compose exec mongo1 mongosh \
  --eval 'rs.status()'
```

Giả sử `mongo1` đang là Primary:

```bash
docker compose stop mongo1
```

Kiểm tra trạng thái qua node còn sống:

```bash
docker compose exec mongo2 mongosh \
  --eval 'rs.status()'
```

Một trong hai MongoDB còn lại phải trở thành Primary.

Kiểm tra VIP:

```bash
docker compose exec proxy1 \
  ip -4 addr show eth0

docker compose exec proxy2 \
  ip -4 addr show eth0
```

VIP có thể vẫn nằm trên proxy ban đầu, vì chỉ MongoDB backend thay đổi.

Thử ghi qua VIP lần nữa:

```bash
docker compose exec client mongosh \
  'mongodb://172.30.77.100:27017/labtest?directConnection=true' \
  --eval '
    db.checks.insertOne({
      event: "after_primary_failover",
      timestamp: new Date()
    });
  '
```

Trong lúc election chưa hoàn thành hoặc HAProxy chưa đánh dấu backend mới UP, thao tác ghi có thể tạm thời thất bại. Thực hiện lại sau khi xác nhận Primary mới ổn định.

Khôi phục:

```bash
docker compose start mongo1
```

Theo dõi:

```bash
docker compose logs -f mongo1
```

---

# 12. Thử nghiệm Keepalived VIP failover

## TEST 05 – Dừng Proxy A

Trước tiên xác nhận proxy nào đang sở hữu VIP:

```bash
docker compose exec proxy1 \
  ip -4 addr show eth0

docker compose exec proxy2 \
  ip -4 addr show eth0
```

Nếu Proxy A đang giữ VIP:

```bash
docker compose stop proxy1
```

Kiểm tra Proxy B:

```bash
docker compose exec proxy2 \
  ip -4 addr show eth0
```

Kỳ vọng Proxy B nhận được:

```text
172.30.77.100/24
```

Tiếp tục kiểm tra kết nối qua VIP:

```bash
docker compose exec client mongosh \
  'mongodb://172.30.77.100:27017/?directConnection=true' \
  --eval 'db.adminCommand({hello:1}).isWritablePrimary'
```

Kỳ vọng:

```text
true
```

Khởi động Proxy A:

```bash
docker compose start proxy1
```

Theo dõi:

```bash
docker compose logs -f proxy1 proxy2
```

Proxy A có priority cao hơn nên có thể giành lại VIP khi hoạt động ổn định.

---

# 13. Thử nghiệm mất quorum

## TEST 06 – Chỉ còn một MongoDB

Thực hiện trong LAB, sau khi các bài kiểm thử cơ bản đã thành công.

Giả sử `mongo1` đang là Primary:

```bash
docker compose stop mongo2 mongo3
```

Một Replica Set ba voting members cần đa số hai phiếu để bầu Primary.

Khi chỉ còn một thành viên hoạt động và nhận biết mất đa số, Replica Set không thể duy trì Primary phục vụ ghi.

Kiểm tra:

```bash
docker compose exec mongo1 mongosh \
  --eval 'db.adminCommand({hello:1})'
```

Sau khi trạng thái election ổn định, HAProxy không được định tuyến thao tác ghi sang Secondary.

Khôi phục:

```bash
docker compose start mongo2 mongo3
```

Kiểm tra:

```bash
bash scripts/status.sh
```

---

# 14. Troubleshooting

## 14.1. Không truy cập được VIP

Kiểm tra Keepalived:

```bash
docker compose logs proxy1 proxy2
```

Kiểm tra network capability:

```bash
docker compose exec proxy1 ip addr
docker compose exec proxy2 ip addr
```

Kiểm tra cấu hình:

```bash
docker compose exec proxy1 \
  keepalived -t -f /etc/keepalived/keepalived.conf
```

Nếu Keepalived không thể gán VIP, kiểm tra `NET_ADMIN`, `NET_RAW`, network interface và hạn chế của Docker/WSL.

## 14.2. VIP có nhưng MongoDB không ghi được

Kiểm tra Primary:

```bash
docker compose exec mongo1 mongosh \
  --eval 'rs.status()'
```

Kiểm tra health checker:

```bash
docker compose logs health1 health2 health3
```

Kiểm tra HAProxy:

```bash
docker compose logs proxy1 proxy2
```

Các khả năng:

- MongoDB đang election.
- Không có Primary.
- Health checker trả 503.
- HAProxy chưa cập nhật backend.
- Driver đang giữ kết nối cũ.
- Mongosh chưa reconnect.

## 14.3. VIP xuất hiện trên cả hai proxy

Đây là trạng thái không mong muốn.

Kiểm tra VRRP peer, quyền `NET_RAW`, network isolation và log Keepalived.

Trong lab có thể dừng một proxy để cô lập hiện tượng, sau đó điều tra cấu hình VRRP. Không coi kết quả test thành công nếu hai proxy cùng giữ VIP.

## 14.4. MongoDB driver vẫn kết nối vào Secondary

Kiểm tra cấu hình URI.

Với bài thử bắt buộc truy cập qua HAProxy:

```text
mongodb://172.30.77.100:27017/?directConnection=true
```

Điều này giữ driver ở chế độ một endpoint.

Với production thực tế, cần đánh giá lại cách ứng dụng sử dụng Replica Set discovery, retryable writes, TLS, authentication, connection pooling và lựa chọn read preference.

---

# 15. Dừng và dọn dẹp LAB

## 15.1. Dừng container nhưng giữ dữ liệu

```bash
docker compose stop
```

Khởi động lại:

```bash
docker compose start
```

## 15.2. Xóa container và network, giữ volume

```bash
docker compose down
```

## 15.3. Xóa toàn bộ LAB và dữ liệu thử nghiệm

Chỉ chạy khi không cần giữ dữ liệu:

```bash
docker compose down -v
```

Lệnh trên xóa các Docker volumes MongoDB của LAB.

Không dùng `docker system prune --volumes` để dọn LAB vì có thể ảnh hưởng tài nguyên Docker của những dự án khác trên máy cá nhân.

---

# 16. Những điều LAB chứng minh và không chứng minh được

**LAB có thể kiểm thử:**

1. MongoDB election thực tế giữa ba member.
2. MongoDB replication.
3. Primary-aware HTTP health check.
4. HAProxy lựa chọn đúng Primary.
5. Keepalived trao đổi VRRP và chuyển VIP.
6. MongoDB client reconnect sau failover.
7. Không định tuyến ghi sang Secondary.
8. Hành vi mất quorum.

**LAB không chứng minh được:**

1. Khả năng chịu lỗi phần cứng của ba VM độc lập.
2. Hành vi systemd thực tế trên ba OS riêng biệt.
3. Khả năng chống network partition ở hạ tầng production.
4. Khả năng chống split-brain VIP trong mọi tình huống.
5. Hiệu năng, throughput hoặc SLA downtime của môi trường thật.
6. Tính an toàn của cấu hình authentication/TLS chưa được triển khai trong LAB.

Cần thực hiện một LAB nhiều VM hoặc môi trường staging tương đương production để kiểm chứng các nội dung này.

---

# 17. Tiêu chí nghiệm thu cuối cùng

| ID | Tiêu chí | Kết quả mong đợi |
|---|---|---|
| AC01 | 9 container hoạt động | PASS |
| AC02 | 3 MongoDB tạo thành Replica Set | PASS |
| AC03 | Có 1 Primary, 2 Secondary | PASS |
| AC04 | Chỉ Primary trả health HTTP 200 | PASS |
| AC05 | Chỉ một HAProxy node sở hữu VIP | PASS |
| AC06 | Ghi dữ liệu qua VIP thành công | PASS |
| AC07 | Primary hỏng, Secondary được bầu thay thế | PASS |
| AC08 | HAProxy định tuyến đến Primary mới | PASS |
| AC09 | Proxy sở hữu VIP lỗi, VIP chuyển proxy | PASS |
| AC10 | Dữ liệu còn nguyên sau khi khôi phục | PASS |
| AC11 | Mất quorum không cho phép ghi sai Secondary | PASS |
| AC12 | Có thể dọn LAB mà không ảnh hưởng Docker project khác | PASS |

**Lưu ý:** Các giá trị PASS là mục tiêu nghiệm thu, không phải kết quả đã kiểm thử.

## Kết luận

Bộ LAB này mô phỏng cơ chế High Availability theo mô hình:

**MongoDB Replica Set → MongoDB-aware Health Checker → HAProxy → Keepalived → VIP → Application.**

Điểm quan trọng nhất cần rút ra là việc phát hiện Primary và việc quản lý VIP là hai nhiệm vụ khác nhau.

HAProxy lựa chọn backend MongoDB; Keepalived chỉ quyết định proxy nào tiếp nhận kết nối qua VIP.

Khi chuyển sang production, cần bổ sung authentication, TLS, secret management, service supervision bằng systemd, network fencing, observability, kiểm thử rollback và xác nhận chính xác URI driver của ứng dụng.