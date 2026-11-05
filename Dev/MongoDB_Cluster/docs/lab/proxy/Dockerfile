FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# haproxy     - primary-aware TCP proxy
# keepalived  - VRRP daemon that owns the VIP
# iproute2    - ss/ip (used by check-haproxy.sh and by you during tests)
# procps      - pidof (used by check-haproxy.sh)
# socat       - talk to the HAProxy stats socket during tests
# curl/ca-certificates - manual probing of the health checkers
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        haproxy \
        keepalived \
        iproute2 \
        procps \
        socat \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/keepalived /run/haproxy

COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY keepalived-a.conf /etc/keepalived-a.conf
COPY keepalived-b.conf /etc/keepalived-b.conf
COPY check-haproxy.sh /usr/local/bin/check-haproxy.sh
COPY start.sh /usr/local/bin/start.sh

# Fail the image build immediately if either config file is broken.
RUN chmod 0644 /etc/haproxy/haproxy.cfg /etc/keepalived-a.conf /etc/keepalived-b.conf \
    && chmod 0755 /usr/local/bin/check-haproxy.sh /usr/local/bin/start.sh \
    && haproxy -c -f /etc/haproxy/haproxy.cfg \
    && cp /etc/keepalived-a.conf /etc/keepalived/keepalived.conf \
    && keepalived -t -f /etc/keepalived/keepalived.conf \
    && keepalived -t -f /etc/keepalived-b.conf

EXPOSE 27017

STOPSIGNAL SIGTERM

CMD ["/usr/local/bin/start.sh"]
