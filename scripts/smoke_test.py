#!/usr/bin/env python3
"""End-to-end check of a running stack, using only the Python standard library.

Verifies, from the Docker host:
* Prometheus is ready, sees Alertmanager, and every expected scrape target is up;
* Grafana is healthy, its provisioned datasources answer their health checks, and the
  admin password from ./secrets works;
* logs flow from Docker through Alloy into Loki (queried through Grafana);
* Node Exporter and Grafana's /metrics refuse requests without credentials;
* the Docker API proxy refuses writes and endpoints it does not allow.

Usage: scripts/smoke_test.py [--timeout 120] [--require-job sentinel]
Exit code 0 when every check passes.
"""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STACK_JOBS = ("prometheus", "alertmanager", "loki", "alloy", "grafana", "node", "cadvisor")


def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    path = ROOT / ".env"
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                env[key.strip()] = value.strip()
    return env


def request(url: str, *, auth: tuple[str, str] | None = None) -> tuple[int, bytes]:
    req = urllib.request.Request(url)
    if auth is not None:
        token = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        req.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(req, timeout=10) as response:  # noqa: S310 - local URLs
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()
    except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
        return 0, str(exc).encode()


def get_json(url: str, *, auth: tuple[str, str] | None = None) -> dict:
    status, body = request(url, auth=auth)
    if status != 200:
        raise RuntimeError(f"GET {url} -> {status}: {body[:200]!r}")
    return json.loads(body)


def wait_for(check: Callable[[], str | None], timeout: float) -> str | None:
    """Retry ``check`` until it returns None (success) or the timeout expires."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            problem = check()
        except (RuntimeError, ValueError, KeyError) as exc:
            problem = str(exc)
        if problem is None or time.monotonic() > deadline:
            return problem
        time.sleep(3)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--require-job", action="append", default=[], metavar="JOB")
    args = parser.parse_args()

    env = load_env()
    prometheus = f"http://127.0.0.1:{env.get('PROMETHEUS_HTTP_PORT', '9090')}"
    alertmanager = f"http://127.0.0.1:{env.get('ALERTMANAGER_HTTP_PORT', '9093')}"
    grafana = f"http://127.0.0.1:{env.get('GRAFANA_HTTP_PORT', '3000')}"
    node_exporter = f"http://127.0.0.1:{env.get('NODE_EXPORTER_LISTEN_ADDRESS', '0.0.0.0:9100').rsplit(':', 1)[1]}"
    admin = (
        env.get("GRAFANA_ADMIN_USER", "admin"),
        (ROOT / "secrets" / "grafana_admin_password").read_text().strip(),
    )
    expected_jobs = set(STACK_JOBS) | set(args.require_job)

    def prometheus_targets() -> str | None:
        data = get_json(f"{prometheus}/api/v1/targets?state=active")["data"]["activeTargets"]
        health: dict[str, list[str]] = {}
        for target in data:
            health.setdefault(target["labels"]["job"], []).append(target["health"])
        missing = sorted(job for job in expected_jobs if job not in health)
        down = sorted(job for job in expected_jobs if any(h != "up" for h in health.get(job, [])))
        if missing or down:
            return f"targets missing={missing} not-up={down}"
        return None

    def alertmanager_discovered() -> str | None:
        data = get_json(f"{prometheus}/api/v1/alertmanagers")["data"]["activeAlertmanagers"]
        return None if data else "Prometheus has no active Alertmanager"

    def grafana_datasources() -> str | None:
        problems = []
        for uid in ("prometheus", "loki", "alertmanager"):
            status, body = request(f"{grafana}/api/datasources/uid/{uid}/health", auth=admin)
            if uid == "alertmanager":  # no health endpoint; the datasource must exist
                status, body = request(f"{grafana}/api/datasources/uid/{uid}", auth=admin)
            if status != 200:
                problems.append(f"{uid}: HTTP {status} {body[:120]!r}")
        return "; ".join(problems) or None

    def logs_in_loki() -> str | None:
        query = urllib.parse.urlencode(
            {"query": 'sum(count_over_time({compose_project="observability"}[5m]))'}
        )
        url = f"{grafana}/api/datasources/proxy/uid/loki/loki/api/v1/query?{query}"
        result = get_json(url, auth=admin)["data"]["result"]
        count = float(result[0]["value"][1]) if result else 0.0
        return None if count > 0 else "no log lines from the stack in Loki yet"

    def unauthenticated_rejected() -> str | None:
        problems = []
        for name, url in (("node-exporter", f"{node_exporter}/metrics"), ("grafana", f"{grafana}/metrics")):
            status, _ = request(url)
            if status != 401:
                problems.append(f"{name} /metrics without credentials -> {status}, expected 401")
        return "; ".join(problems) or None

    def docker_proxy_read_only() -> str | None:
        """Ask the proxy, from inside a container on its network, for things it must refuse."""
        problems = []
        probes = (
            ("POST /containers/create", ["--post-data", "{}"], "/containers/create"),
            ("GET /images/json", [], "/images/json"),
        )
        for name, extra, path in probes:
            result = subprocess.run(  # noqa: S603 - fixed argument list
                [
                    "docker", "compose", "-f", str(ROOT / "docker-compose.observability.yml"),
                    "exec", "-T", "cadvisor", "wget", "-q", "-O-", *extra,
                    f"http://docker-socket-proxy:2375{path}",
                ],
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            if "403" not in result.stderr:
                problems.append(f"{name} was not refused with 403 ({result.stderr.strip()[:80]!r})")
        return "; ".join(problems) or None

    checks: list[tuple[str, Callable[[], str | None]]] = [
        ("Prometheus ready", lambda: None if request(f"{prometheus}/-/ready")[0] == 200 else "not ready"),
        ("Alertmanager ready", lambda: None if request(f"{alertmanager}/-/ready")[0] == 200 else "not ready"),
        ("Grafana healthy", lambda: None if request(f"{grafana}/api/health")[0] == 200 else "not healthy"),
        ("Grafana admin login", lambda: None if request(f"{grafana}/api/user", auth=admin)[0] == 200 else "login failed"),
        ("Alertmanager discovered by Prometheus", alertmanager_discovered),
        (f"Scrape targets up ({', '.join(sorted(expected_jobs))})", prometheus_targets),
        ("Grafana datasources provisioned and healthy", grafana_datasources),
        ("Container logs reach Loki through Alloy", logs_in_loki),
        ("Exporters reject requests without credentials", unauthenticated_rejected),
        ("Docker API proxy refuses writes and unlisted endpoints", docker_proxy_read_only),
    ]

    failures = 0
    for name, check in checks:
        problem = wait_for(check, args.timeout)
        print(f"{'PASS' if problem is None else 'FAIL'}  {name}{'' if problem is None else f': {problem}'}")
        failures += problem is not None
    print(f"\n{len(checks) - failures}/{len(checks)} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
