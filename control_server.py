#!/usr/bin/env python3
import http.client
import json
import os
import re
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlparse

DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
HOST = os.environ.get("GALAXY_CONTROL_HOST", "0.0.0.0")
PORT = int(os.environ.get("GALAXY_CONTROL_PORT", "8097"))
ALLOWED_ORIGINS = {
    "http://192.168.2.46:8096",
    "http://localhost:8096",
    "http://127.0.0.1:8096",
}
DENY_EXACT = {"galaxy-web", "galaxy-poller", "galaxy-control", "watchtower", "n8n"}
DENY_PREFIX = ("cloudflared-",)
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
LEGENDAS_COMPOSE_DIR = "/dados/dockers/legendas"
LEGENDAS_ENV_FILE = "/dados/dockers/claude/ai/config/mimi_api.txt"


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path):
        super().__init__("localhost")
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.socket_path)


def docker_request(method, path):
    conn = UnixHTTPConnection(DOCKER_SOCK)
    try:
        conn.request(method, path)
        resp = conn.getresponse()
        body = resp.read()
        return resp.status, body, dict(resp.getheaders())
    finally:
        conn.close()


def json_body(ok, **kwargs):
    data = {"ok": ok}
    data.update(kwargs)
    return json.dumps(data, separators=(",", ":")).encode()


def decode_docker_logs(raw):
    out = []
    i = 0
    while i + 8 <= len(raw):
        stream = raw[i]
        size = int.from_bytes(raw[i + 4 : i + 8], "big")
        if stream not in (1, 2) or size < 0 or i + 8 + size > len(raw):
            break
        out.append(raw[i + 8 : i + 8 + size])
        i += 8 + size
    if out and i == len(raw):
        raw = b"".join(out)
    return raw.decode("utf-8", "replace")


def valid_name(name):
    return bool(NAME_RE.match(name or ""))


def denied(name):
    return name in DENY_EXACT or any(name.startswith(p) for p in DENY_PREFIX)


def docker_json(method, path, payload):
    body = json.dumps(payload, separators=(",", ":")).encode()
    conn = UnixHTTPConnection(DOCKER_SOCK)
    try:
        conn.request(method, path, body=body, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        data = resp.read()
        return resp.status, data, dict(resp.getheaders())
    finally:
        conn.close()


def run_legendas_compose():
    task_name = f"galaxy-legendas-start-{int(time.time())}"
    payload = {
        "Image": "docker:cli",
        "Cmd": ["sh", "-lc", f"cd {LEGENDAS_COMPOSE_DIR} && docker compose up -d legendas"],
        "WorkingDir": LEGENDAS_COMPOSE_DIR,
        "HostConfig": {
            "AutoRemove": True,
            "Binds": [
                "/var/run/docker.sock:/var/run/docker.sock",
                f"{LEGENDAS_COMPOSE_DIR}:{LEGENDAS_COMPOSE_DIR}",
                f"{LEGENDAS_ENV_FILE}:{LEGENDAS_ENV_FILE}:ro",
            ],
        },
    }
    status, body, _ = docker_json("POST", f"/containers/create?name={quote(task_name)}", payload)
    if status >= 300:
        return status, body
    status, body, _ = docker_request("POST", f"/containers/{quote(task_name)}/start")
    return status, body


class Handler(BaseHTTPRequestHandler):
    server_version = "galaxy-control/1.0"

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def _origin(self):
        origin = self.headers.get("Origin")
        if origin in ALLOWED_ORIGINS:
            return origin
        return "http://192.168.2.46:8096"

    def _headers(self, status=200, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Access-Control-Allow-Origin", self._origin())
        self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def _json(self, status=200, ok=True, **kwargs):
        self._headers(status)
        self.wfile.write(json_body(ok, **kwargs))

    def do_OPTIONS(self):
        self._headers(204)

    def do_HEAD(self):
        if urlparse(self.path).path == "/health":
            status, _, _ = docker_request("GET", "/_ping")
            return self._headers(200 if status == 200 else 503)
        return self._headers(404)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            status, _, _ = docker_request("GET", "/_ping")
            return self._json(ok=status == 200, docker=status)

        m = re.match(r"^/containers/([^/]+)/logs$", parsed.path)
        if not m:
            return self._json(404, False, error="not_found")

        name = unquote(m.group(1))
        if not valid_name(name):
            return self._json(400, False, error="invalid_container_name")

        qs = parse_qs(parsed.query)
        tail = min(max(int((qs.get("tail") or ["200"])[0]), 1), 500)
        path = (
            f"/containers/{quote(name)}/logs"
            f"?stdout=1&stderr=1&timestamps=1&tail={tail}"
        )
        status, body, _ = docker_request("GET", path)
        if status >= 300:
            return self._json(status, False, error="docker_logs_failed", detail=body.decode("utf-8", "replace")[:500])
        return self._json(container=name, tail=tail, logs=decode_docker_logs(body))

    def do_POST(self):
        parsed = urlparse(self.path)
        m = re.match(r"^/containers/([^/]+)/(start|stop|restart)$", parsed.path)
        if not m:
            return self._json(404, False, error="not_found")

        name = unquote(m.group(1))
        action = m.group(2)
        if not valid_name(name):
            return self._json(400, False, error="invalid_container_name")
        if denied(name):
            return self._json(403, False, error="container_denied", container=name)

        if name == "legendas" and action in ("start", "restart"):
            status, body = run_legendas_compose()
            if status not in (200, 201, 204, 304):
                return self._json(status, False, error="compose_start_failed", action=action, detail=body.decode("utf-8", "replace")[:500])
            return self._json(container=name, action=action, docker_status=status, mode="compose_service")

        suffix = {"start": "/start", "stop": "/stop?t=10", "restart": "/restart?t=10"}[action]
        status, body, _ = docker_request("POST", f"/containers/{quote(name)}{suffix}")
        if status not in (200, 204, 304):
            return self._json(status, False, error="docker_action_failed", action=action, detail=body.decode("utf-8", "replace")[:500])
        return self._json(container=name, action=action, docker_status=status)


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
