"""MongoDB primary health checker for the HA lab.

Exposes, on every health container:

    GET /primary   200 + "PRIMARY\n"       node is the writable primary of the set
                          503 + "NOT_PRIMARY"  node is secondary/recovering/unreachable
    GET /healthz   200 + "OK\n"           process liveness only

HAProxy polls GET /primary once a second and only routes MongoDB traffic to
servers whose checker answers 200. That is why TCP-27017 checks alone are not
enough: in a replica set, *every* member listens on 27017.

directConnection=True is essential: without it PyMongo would talk to whatever
node the replica set tells it to, so the checker would not test the node it was
asked to test.
"""

import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from pymongo import MongoClient

MONGO_HOST = os.getenv("MONGO_HOST", "mongo1")
MONGO_PORT = int(os.getenv("MONGO_PORT", "27017"))
REPLICA_SET = os.getenv("REPLICA_SET", "labrs")
LISTEN_PORT = int(os.getenv("LISTEN_PORT", "9201"))
TIMEOUT_MS = int(os.getenv("CHECK_TIMEOUT_MS", "1000"))

client = MongoClient(
    host=MONGO_HOST,
    port=MONGO_PORT,
    directConnection=True,
    serverSelectionTimeoutMS=TIMEOUT_MS,
    connectTimeoutMS=TIMEOUT_MS,
    socketTimeoutMS=TIMEOUT_MS,
    maxPoolSize=2,
    appname="lab-primary-health",
)

# HAProxy polls every second: log state *transitions* only, not every probe.
_state_lock = threading.Lock()
_last_healthy = None


def log_state(healthy, detail):
    global _last_healthy
    with _state_lock:
        if healthy == _last_healthy:
            return
        _last_healthy = healthy
        print(
            "state change %s:%d -> %s (%s)"
            % (
                MONGO_HOST,
                MONGO_PORT,
                "PRIMARY" if healthy else "NOT_PRIMARY",
                detail,
            ),
            flush=True,
        )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _respond(self, code, body):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/healthz":
            self._respond(200, "OK\n")
            return

        if self.path != "/primary":
            self._respond(404, "NOT_FOUND\n")
            return

        healthy = False
        detail = "unknown"
        try:
            hello = client.admin.command("hello")
            healthy = (
                hello.get("isWritablePrimary") is True
                and hello.get("setName") == REPLICA_SET
            )
            detail = "isWritablePrimary=%s secondary=%s setName=%s" % (
                hello.get("isWritablePrimary"),
                hello.get("secondary"),
                hello.get("setName"),
            )
        except Exception as exc:  # must never crash: report 503 and keep serving
            detail = "error=%s" % exc

        log_state(healthy, detail)
        self._respond(
            200 if healthy else 503,
            "PRIMARY\n" if healthy else "NOT_PRIMARY\n",
        )

    def log_message(self, fmt, *args):
        # Default access log would flood docker logs (1 request/second/server).
        return


print(
    "health checker starting: mongo=%s:%d set=%s listen=%d timeout_ms=%d"
    % (MONGO_HOST, MONGO_PORT, REPLICA_SET, LISTEN_PORT, TIMEOUT_MS),
    flush=True,
)

server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
server.daemon_threads = True
server.serve_forever(poll_interval=0.5)
