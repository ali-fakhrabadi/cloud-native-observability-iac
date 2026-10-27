#!/usr/bin/env python3
"""Prometheus exporter for Docker's own view of containers: restarts, state and health.

cAdvisor reports a container only while it runs, and only at its housekeeping interval.
A container that Docker keeps restarting is stopped most of the time (the restart
back-off doubles up to a minute), so cAdvisor barely sees it: in this repository's
crash-loop drill, cAdvisor sampled a container twice while Docker restarted it 13
times. Docker counts restarts itself; this exporter reads that count, each container's
state and its health check status through the read-only Docker API proxy, on every
scrape.

Metrics, labelled name, compose_project and compose_service:
  docker_container_restarts_total  restarts since the container was created (RestartCount)
  docker_container_state           1 for the current state, state="running|restarting|exited|..."
  docker_container_health_status   1 for the current health, status="healthy|unhealthy|starting"
                                   (only containers with a health check)
  docker_container_exit_code       exit code of the last run

A scrape fails (HTTP 503, so `up` is 0 and TargetDown fires) when the Docker API does
not answer. Standard library only. Endpoints: GET /metrics, GET /healthz.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DOCKER_API_URL = os.environ.get("DOCKER_API_URL", "http://docker-socket-proxy:2375").rstrip("/")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9417"))
TIMEOUT_SECONDS = 5

METRICS = {
    "docker_container_restarts_total": ("counter", "Times Docker restarted the container since it was created."),
    "docker_container_state": ("gauge", "Current container state (1 for the state in the label)."),
    "docker_container_health_status": ("gauge", "Current health check status (1 for the status in the label)."),
    "docker_container_exit_code": ("gauge", "Exit code of the container's last run."),
}


def docker_get(path: str) -> object:
    with urllib.request.urlopen(f"{DOCKER_API_URL}{path}", timeout=TIMEOUT_SECONDS) as response:  # noqa: S310
        return json.load(response)


def escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def labels(**pairs: str) -> str:
    return "{" + ",".join(f'{key}="{escape(value)}"' for key, value in pairs.items()) + "}"


def collect() -> str:
    samples: dict[str, list[str]] = {name: [] for name in METRICS}
    for summary in docker_get("/containers/json?all=1"):
        try:
            container = docker_get(f"/containers/{summary['Id']}/json")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:  # removed between the list and the inspect
                continue
            raise
        config_labels = (container.get("Config") or {}).get("Labels") or {}
        identity = {
            "name": container["Name"].lstrip("/"),
            "compose_project": config_labels.get("com.docker.compose.project", ""),
            "compose_service": config_labels.get("com.docker.compose.service", ""),
        }
        state = container.get("State") or {}
        samples["docker_container_restarts_total"].append(f"{labels(**identity)} {container.get('RestartCount', 0)}")
        samples["docker_container_state"].append(f"{labels(**identity, state=state.get('Status', 'unknown'))} 1")
        samples["docker_container_exit_code"].append(f"{labels(**identity)} {state.get('ExitCode', 0)}")
        health = state.get("Health")
        if health:
            samples["docker_container_health_status"].append(
                f"{labels(**identity, status=health.get('Status', 'unknown'))} 1")

    lines = []
    for name, (kind, help_text) in METRICS.items():
        lines += [f"# HELP {name} {help_text}", f"# TYPE {name} {kind}"]
        lines += [f"{name}{sample}" for sample in samples[name]]
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    server_version = "docker-state-exporter"

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._reply(200, b"ok\n")
        elif self.path == "/metrics":
            try:
                body = collect().encode()
            except (OSError, ValueError, KeyError) as exc:
                sys.stderr.write(json.dumps({"level": "error", "msg": "Docker API request failed", "error": str(exc)}) + "\n")
                self._reply(503, b"Docker API unavailable\n")
                return
            self._reply(200, body, "text/plain; version=0.0.4; charset=utf-8")
        else:
            self._reply(404, b"not found\n")

    def _reply(self, status: int, body: bytes, content_type: str = "text/plain; charset=utf-8") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - stdlib signature
        return  # no access log: Prometheus scrapes every 15 seconds


def main() -> int:
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)  # noqa: S104 - container port
    sys.stdout.write(json.dumps({"level": "info", "msg": "listening", "port": LISTEN_PORT}) + "\n")
    sys.stdout.flush()
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
