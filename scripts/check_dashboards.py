#!/usr/bin/env python3
"""Check the provisioned Grafana dashboards against a running stack.

Static checks: unique panel IDs, panels inside the 24-column grid without overlapping,
only the provisioned datasource UIDs. Live checks: Grafana loaded every dashboard, and
every panel query runs without error (PromQL against Prometheus, LogQL through Grafana's
Loki datasource), with template variables replaced by their "All" values.

Queries that succeed but return no data are listed, not failed: a panel about a service
that is not deployed (for example Sentinel in CI) is legitimately empty.

Usage: scripts/check_dashboards.py [--require-data UID ...]
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DASHBOARDS = ROOT / "config" / "grafana" / "dashboards"
DATASOURCES = {"prometheus", "loki"}
SUBSTITUTIONS = {
    "$__rate_interval": "1m",
    "$__interval": "1m",
    "$__auto": "1m",
    "$project": ".+",
    "$level": ".+",
}


def env_port(name: str, default: str) -> str:
    path = ROOT / ".env"
    if path.exists():
        for line in path.read_text().splitlines():
            if line.startswith(f"{name}="):
                return line.split("=", 1)[1].strip()
    return default


def fetch(url: str, auth: str | None = None) -> tuple[int, dict[str, Any]]:
    req = urllib.request.Request(url)
    if auth:
        req.add_header("Authorization", auth)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:  # noqa: S310 - local URLs
            return response.status, json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.load(exc)
        except ValueError:
            return exc.code, {}


def static_problems(name: str, dashboard: dict[str, Any]) -> list[str]:
    problems = []
    panels = dashboard["panels"]
    ids = [p["id"] for p in panels]
    if len(ids) != len(set(ids)):
        problems.append(f"{name}: duplicate panel ids")
    occupied: dict[tuple[int, int], str] = {}
    for panel in panels:
        pos = panel["gridPos"]
        if pos["x"] < 0 or pos["x"] + pos["w"] > 24:
            problems.append(f"{name}: '{panel['title']}' is outside the 24-column grid")
        for x in range(pos["x"], pos["x"] + pos["w"]):
            for y in range(pos["y"], pos["y"] + pos["h"]):
                if (x, y) in occupied:
                    problems.append(f"{name}: '{panel['title']}' overlaps '{occupied[(x, y)]}'")
                    break
                occupied[(x, y)] = panel["title"]
            else:
                continue
            break
        if panel["type"] != "row":
            uid = panel.get("datasource", {}).get("uid")
            if uid not in DATASOURCES:
                problems.append(f"{name}: '{panel['title']}' uses unknown datasource {uid!r}")
            if not panel.get("targets"):
                problems.append(f"{name}: '{panel['title']}' has no queries")
    return problems


def substitute(expr: str) -> str:
    for variable, value in SUBSTITUTIONS.items():
        expr = expr.replace(variable, value)
    return expr


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--require-data", nargs="*", default=[], metavar="UID")
    args = parser.parse_args()

    prometheus = f"http://127.0.0.1:{env_port('PROMETHEUS_HTTP_PORT', '9090')}"
    grafana = f"http://127.0.0.1:{env_port('GRAFANA_HTTP_PORT', '3000')}"
    user = env_port("GRAFANA_ADMIN_USER", "admin")
    password = (ROOT / "secrets" / "grafana_admin_password").read_text().strip()
    auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    errors: list[str] = []
    empty: list[str] = []
    queries = 0
    for path in sorted(DASHBOARDS.rglob("*.json")):
        dashboard = json.loads(path.read_text(encoding="utf-8"))
        uid, title = dashboard["uid"], dashboard["title"]
        errors += static_problems(title, dashboard)

        status, _ = fetch(f"{grafana}/api/dashboards/uid/{uid}", auth)
        if status != 200:
            errors.append(f"{title}: not loaded by Grafana (HTTP {status})")

        for panel in dashboard["panels"]:
            for target in panel.get("targets", []):
                queries += 1
                expr = substitute(target["expr"])
                label = f"{title} / {panel['title']} [{target['refId']}]"
                if target["datasource"]["uid"] == "prometheus":
                    url = f"{prometheus}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
                    status, body = fetch(url)
                else:
                    is_metric = expr.lstrip().startswith(("sum", "count", "rate", "avg", "max", "min", "topk"))
                    endpoint = "query" if is_metric else "query_range"
                    params = {"query": expr} if is_metric else {"query": expr, "limit": "1", "since": "1h"}
                    url = f"{grafana}/api/datasources/proxy/uid/loki/loki/api/v1/{endpoint}?" + urllib.parse.urlencode(params)
                    status, body = fetch(url, auth)
                if status != 200 or body.get("status") != "success":
                    errors.append(f"{label}: {body.get('error', f'HTTP {status}')}")
                elif not body["data"]["result"]:
                    empty.append(label)
                    if uid in args.require_data:
                        errors.append(f"{label}: no data")

    print(f"{queries} panel queries checked in {len(list(DASHBOARDS.rglob('*.json')))} dashboards")
    for item in empty:
        print(f"  no data  {item}")
    for item in errors:
        print(f"  ERROR    {item}")
    print("OK" if not errors else f"{len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
