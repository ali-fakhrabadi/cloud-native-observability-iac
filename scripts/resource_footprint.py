#!/usr/bin/env python3
"""Measured resource footprint of the running stack, from its own metrics.

Reads Prometheus (cAdvisor, Prometheus and Loki metrics) over a time window, 24 hours by
default, and Docker's volume sizes, and prints a Markdown report: average and peak memory
and CPU per service, stored series, ingestion rates and disk usage. Useful to size a host
and to see what monitoring one more service costs.

Usage: scripts/resource_footprint.py [--window 24h] [--end 2026-10-27T03:00:00Z]
Requires the running stack (make up). Standard library only.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = "observability"
SERVICE = "container_label_com_docker_compose_service"
SELECTOR = f'{{container_label_com_docker_compose_project="{PROJECT}"}}'
MIB = 1024 * 1024


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


class Prometheus:
    def __init__(self, url: str, end: datetime) -> None:
        self.url = url
        self.end = end

    def query(self, expr: str) -> list[dict]:
        params = urllib.parse.urlencode({"query": expr, "time": self.end.timestamp()})
        with urllib.request.urlopen(f"{self.url}/api/v1/query?{params}", timeout=60) as response:  # noqa: S310
            body = json.load(response)
        if body.get("status") != "success":
            raise RuntimeError(f"{expr}: {body}")
        return body["data"]["result"]

    def by_service(self, expr: str) -> dict[str, float]:
        return {r["metric"].get(SERVICE, "total"): float(r["value"][1]) for r in self.query(expr)}

    def scalar(self, expr: str) -> float | None:
        result = self.query(expr)
        return float(result[0]["value"][1]) if result else None


def volume_sizes() -> dict[str, float]:
    output = subprocess.run(  # noqa: S603 - fixed argument list
        ["docker", "system", "df", "--verbose", "--format", "{{json .Volumes}}"],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120, check=True,
    ).stdout
    sizes: dict[str, float] = {}
    for volume in json.loads(output) or []:
        name = volume.get("Name", "")
        if name.startswith(f"{PROJECT}_"):
            sizes[name.removeprefix(f"{PROJECT}_")] = parse_size(volume.get("Size", "0B"))
    return sizes


def parse_size(text: str) -> float:
    units = {"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}
    for unit in sorted(units, key=len, reverse=True):
        if text.endswith(unit):
            return float(text[: -len(unit)]) * units[unit]
    return float(text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--window", default="24h", help="Prometheus duration, e.g. 6h or 24h")
    parser.add_argument("--end", help="end of the window (ISO 8601, UTC); default now")
    args = parser.parse_args()

    env = load_env()
    end = datetime.fromisoformat(args.end.replace("Z", "+00:00")) if args.end else datetime.now(UTC)
    prom = Prometheus(f"http://127.0.0.1:{env.get('PROMETHEUS_HTTP_PORT', '9090')}", end)
    w = args.window

    # A recreated container briefly has two series (old and new cgroup) under one name:
    # take the larger per name, so it is not counted twice.
    memory_per_container = f"max by (name, {SERVICE}) (container_memory_working_set_bytes{SELECTOR})"
    cpu_per_container = f"max by (name, {SERVICE}) (rate(container_cpu_usage_seconds_total{SELECTOR}[5m]))"
    memory = f"sum by ({SERVICE}) ({memory_per_container})"
    cpu = f"sum by ({SERVICE}) ({cpu_per_container})"
    mem_avg = prom.by_service(f"avg_over_time({memory}[{w}:1m])")
    mem_max = prom.by_service(f"max_over_time({memory}[{w}:1m])")
    cpu_avg = prom.by_service(f"avg_over_time({cpu}[{w}:1m])")
    cpu_max = prom.by_service(f"max_over_time({cpu}[{w}:1m])")
    total_mem = f"sum({memory_per_container})"
    total_cpu = f"sum({cpu_per_container})"
    totals = {
        "mem_avg": prom.scalar(f"avg_over_time({total_mem}[{w}:1m])"),
        "mem_max": prom.scalar(f"max_over_time({total_mem}[{w}:1m])"),
        "cpu_avg": prom.scalar(f"avg_over_time({total_cpu}[{w}:1m])"),
        "cpu_max": prom.scalar(f"max_over_time({total_cpu}[{w}:1m])"),
    }

    print(f"Window: {w} ending {end.strftime('%Y-%m-%d %H:%M')} UTC\n")
    print("| Service | Memory avg | Memory peak | CPU avg (cores) | CPU peak (cores) |")
    print("|---|---|---|---|---|")
    for service in sorted(mem_avg, key=lambda s: -mem_avg[s]):
        print(f"| {service} | {mem_avg[service] / MIB:.0f} MiB | {mem_max.get(service, 0) / MIB:.0f} MiB "
              f"| {cpu_avg.get(service, 0):.3f} | {cpu_max.get(service, 0):.3f} |")
    print(f"| **total** | **{totals['mem_avg'] / MIB:.0f} MiB** | **{totals['mem_max'] / MIB:.0f} MiB** "
          f"| **{totals['cpu_avg']:.3f}** | **{totals['cpu_max']:.3f}** |")
    print("\nPeaks are per service; the total peak is the highest simultaneous sum.\n")

    stats = {
        "Active series (Prometheus head)": prom.scalar(f"avg_over_time(prometheus_tsdb_head_series[{w}])"),
        "Samples ingested per second": prom.scalar(f"rate(prometheus_tsdb_head_samples_appended_total[{w}])"),
        "Scrape targets": prom.scalar("count(up)"),
        "Log lines received per second (Loki)": prom.scalar(f"sum(rate(loki_distributor_lines_received_total[{w}]))"),
        "Log bytes received per second (Loki)": prom.scalar(f"sum(rate(loki_distributor_bytes_received_total[{w}]))"),
    }
    print("| Measure | Value |")
    print("|---|---|")
    for name, value in stats.items():
        print(f"| {name} | {'n/a' if value is None else f'{value:,.1f}'} |")

    sizes = volume_sizes()
    if sizes:
        print("\n| Volume | Size |")
        print("|---|---|")
        for name, size in sorted(sizes.items(), key=lambda item: -item[1]):
            print(f"| {name} | {size / 1e6:.1f} MB |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
