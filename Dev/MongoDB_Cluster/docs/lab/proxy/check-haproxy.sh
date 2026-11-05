#!/bin/sh
# Keepalived tracking script (vrrp_script chk_haproxy).
#
#   exit 0 = HAProxy is healthy
#   exit 1 = HAProxy is unhealthy  -> proxy's VRRP priority is demoted by 30
#
# It checks ONLY the proxy layer, not MongoDB. This is deliberate:
# during a MongoDB election there is no primary for a few seconds; the VIP
# must survive that window so applications get fast "no backend" errors
# instead of a VIP that keeps flapping between the two proxies.

set -eu

# 1) the haproxy process must exist
pidof haproxy >/dev/null 2>&1 || exit 1

# 2) haproxy must actually listen on the MongoDB frontend port
#    (ss output: "0.0.0.0:27017" is followed by whitespace)
ss -lnt 2>/dev/null | grep -q ':27017 ' || exit 1

exit 0
