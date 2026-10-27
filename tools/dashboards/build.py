#!/usr/bin/env python3
"""Generate the Grafana dashboards in config/grafana/dashboards (dashboards as code).

The JSON files are committed so Grafana can provision them directly; this script is the
source of truth for their layout. Standard library only.

    python3 tools/dashboards/build.py           # write the JSON files
    python3 tools/dashboards/build.py --check   # fail if the files are out of date (CI)
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

OUT = Path(__file__).resolve().parents[2] / "config" / "grafana" / "dashboards"
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}

Panel = dict[str, Any]


class Layout:
    """Places panels left to right on Grafana's 24-column grid."""

    def __init__(self) -> None:
        self.panels: list[Panel] = []
        self.x = 0
        self.y = 0
        self.row_height = 0

    def row(self, title: str) -> None:
        self._newline()
        self._add({"type": "row", "title": title, "collapsed": False, "panels": []}, 24, 1)
        self._newline()

    def add(self, panel: Panel, w: int, h: int) -> None:
        if self.x + w > 24:
            self._newline()
        self._add(panel, w, h)

    def _add(self, panel: Panel, w: int, h: int) -> None:
        panel["id"] = len(self.panels) + 1
        panel["gridPos"] = {"h": h, "w": w, "x": self.x, "y": self.y}
        self.panels.append(panel)
        self.x += w
        self.row_height = max(self.row_height, h)

    def _newline(self) -> None:
        if self.x:
            self.y += self.row_height
        self.x = 0
        self.row_height = 0


def thresholds(*steps: tuple[float | None, str]) -> dict[str, Any]:
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in steps]}


GREEN_AMBER_RED = thresholds((None, "green"), (0.7, "#EAB839"), (0.9, "red"))


def prom(expr: str, legend: str = "", *, instant: bool = False, ref: str = "A") -> dict[str, Any]:
    target: dict[str, Any] = {"datasource": PROM, "expr": expr, "refId": ref, "legendFormat": legend}
    if instant:
        target.update({"instant": True, "range": False, "format": "table"})
    return target


def loki(expr: str, legend: str = "", ref: str = "A") -> dict[str, Any]:
    return {"datasource": LOKI, "expr": expr, "refId": ref, "legendFormat": legend, "queryType": "range"}


def stat(title: str, expr: str, unit: str, *, steps: dict[str, Any] | None = None, desc: str = "") -> Panel:
    return {
        "type": "stat",
        "title": title,
        "description": desc,
        "datasource": PROM,
        "targets": [prom(expr)],
        "fieldConfig": {
            "defaults": {"unit": unit, "decimals": 2, "thresholds": steps or thresholds((None, "green"))},
            "overrides": [],
        },
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": "value",
            "graphMode": "area",
            "textMode": "auto",
            "justifyMode": "auto",
            "orientation": "auto",
        },
    }


def gauge(title: str, expr: str, *, desc: str = "") -> Panel:
    return {
        "type": "gauge",
        "title": title,
        "description": desc,
        "datasource": PROM,
        "targets": [prom(expr)],
        "fieldConfig": {
            "defaults": {"unit": "percentunit", "min": 0, "max": 1, "decimals": 1, "thresholds": GREEN_AMBER_RED},
            "overrides": [],
        },
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "showThresholdLabels": False,
            "showThresholdMarkers": True,
        },
    }


def timeseries(
    title: str,
    targets: list[dict[str, Any]],
    unit: str,
    *,
    stack: bool = False,
    bars: bool = False,
    datasource: dict[str, str] = PROM,
    desc: str = "",
    minimum: float | None = 0,
) -> Panel:
    defaults: dict[str, Any] = {
        "unit": unit,
        "custom": {
            "drawStyle": "bars" if bars else "line",
            "lineWidth": 1,
            "fillOpacity": 60 if bars else (25 if stack else 10),
            "showPoints": "never",
            "spanNulls": False,
            "stacking": {"mode": "normal" if stack else "none", "group": "A"},
        },
    }
    if minimum is not None:
        defaults["min"] = minimum
    return {
        "type": "timeseries",
        "title": title,
        "description": desc,
        "datasource": datasource,
        "targets": targets,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
    }


def bargauge(title: str, expr: str, legend: str, unit: str = "percentunit", *, desc: str = "") -> Panel:
    return {
        "type": "bargauge",
        "title": title,
        "description": desc,
        "datasource": PROM,
        # Instant, so sort_desc() orders the bars (it has no effect on range queries), but
        # still one series per bar rather than prom(instant=True)'s table format.
        "targets": [{**prom(expr, legend), "instant": True, "range": False}],
        "fieldConfig": {
            "defaults": {"unit": unit, "min": 0, "max": 1, "decimals": 1, "thresholds": GREEN_AMBER_RED},
            "overrides": [],
        },
        "options": {
            "displayMode": "gradient",
            "orientation": "horizontal",
            "showUnfilled": True,
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
        },
    }


def table(title: str, expr: str, hide: list[str], rename: dict[str, str], *, desc: str = "") -> Panel:
    return {
        "type": "table",
        "title": title,
        "description": desc,
        "datasource": PROM,
        "targets": [prom(expr, instant=True)],
        "fieldConfig": {"defaults": {}, "overrides": []},
        "options": {"showHeader": True, "cellHeight": "sm"},
        "transformations": [
            {
                "id": "organize",
                "options": {"excludeByName": {name: True for name in ["Time", *hide]}, "renameByName": rename},
            }
        ],
    }


def logs(title: str, expr: str, *, desc: str = "") -> Panel:
    return {
        "type": "logs",
        "title": title,
        "description": desc,
        "datasource": LOKI,
        "targets": [loki(expr)],
        "options": {
            "showTime": True,
            "showLabels": False,
            "showCommonLabels": False,
            "wrapLogMessage": True,
            "prettifyLogMessage": False,
            "enableLogDetails": True,
            "dedupStrategy": "none",
            "sortOrder": "Descending",
        },
    }


def query_variable(name: str, label: str, query: str) -> dict[str, Any]:
    return {
        "type": "query",
        "name": name,
        "label": label,
        "datasource": PROM,
        "definition": query,
        "query": {"query": query, "refId": f"{name}-variable"},
        "refresh": 2,
        "includeAll": True,
        "multi": True,
        # ".+" rather than ".*": Loki selectors must not match the empty string.
        "allValue": ".+",
        "current": {"selected": True, "text": ["All"], "value": ["$__all"]},
        "sort": 1,
    }


def custom_variable(name: str, label: str, values: list[str], default: list[str]) -> dict[str, Any]:
    return {
        "type": "custom",
        "name": name,
        "label": label,
        "query": ",".join(values),
        "includeAll": True,
        "multi": True,
        "allValue": ".+",
        "current": {"selected": True, "text": default, "value": default},
        "options": [{"selected": v in default, "text": v, "value": v} for v in values],
    }


def dashboard(uid: str, title: str, tags: list[str], layout: Layout, variables: list[dict[str, Any]], description: str) -> dict[str, Any]:
    return {
        "uid": uid,
        "title": title,
        "description": description,
        "tags": tags,
        "editable": False,
        "graphTooltip": 1,
        "schemaVersion": 41,
        "version": 1,
        "timezone": "browser",
        "time": {"from": "now-3h", "to": "now"},
        "refresh": "30s",
        "templating": {"list": variables},
        "annotations": {
            "list": [
                {
                    "name": "Firing alerts",
                    "datasource": PROM,
                    "enable": True,
                    "iconColor": "red",
                    "expr": 'ALERTS{alertstate="firing", alertname!="Watchdog"}',
                    "step": "60s",
                    "titleFormat": "{{alertname}}",
                    "textFormat": "{{instance}} {{name}}",
                    "useValueForTime": False,
                }
            ]
        },
        "links": [],
        "panels": layout.panels,
    }


# ---------------------------------------------------------------------------------------
# Linux host and Docker overview
# ---------------------------------------------------------------------------------------
def linux_docker_overview() -> dict[str, Any]:
    real_fs = 'fstype!~"tmpfs|overlay|squashfs|ramfs|nsfs|fuse.*"'
    host_nics = 'device!~"lo|veth.*|br-.*|docker.*"'
    project = 'container_label_com_docker_compose_project=~"$project"'
    lay = Layout()

    lay.row("Host")
    lay.add(stat("Uptime", "time() - node_boot_time_seconds", "s"), 4, 4)
    lay.add(gauge("CPU", "instance:node_cpu_utilisation:ratio_rate5m", desc="Share of CPU time not idle, 5-minute rate."), 4, 4)
    lay.add(gauge("Memory", "instance:node_memory_utilisation:ratio", desc="1 - MemAvailable / MemTotal."), 4, 4)
    lay.add(gauge("Root filesystem", '1 - instance:node_filesystem_avail:ratio{mountpoint="/"}'), 4, 4)
    lay.add(
        stat(
            "Load per core",
            'node_load1 / scalar(count(node_cpu_seconds_total{mode="idle"}))',
            "none",
            steps=thresholds((None, "green"), (0.8, "#EAB839"), (1.5, "red")),
            desc="1-minute load average divided by the number of CPUs.",
        ),
        4,
        4,
    )
    lay.add(
        stat(
            "Firing alerts",
            'count(ALERTS{alertstate="firing", alertname!="Watchdog"}) or vector(0)',
            "none",
            steps=thresholds((None, "green"), (1, "red")),
            desc="Excludes the always-firing Watchdog heartbeat.",
        ),
        4,
        4,
    )
    lay.add(
        timeseries(
            "CPU by mode",
            [prom('sum by (mode) (rate(node_cpu_seconds_total{mode!="idle"}[$__rate_interval])) / scalar(count(node_cpu_seconds_total{mode="idle"}))', "{{mode}}")],
            "percentunit",
            stack=True,
        ),
        12,
        8,
    )
    lay.add(
        timeseries(
            "Memory",
            [
                prom("node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "used", ref="A"),
                prom("node_memory_MemAvailable_bytes", "available", ref="B"),
                prom("node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes", "swap used", ref="C"),
            ],
            "bytes",
        ),
        12,
        8,
    )
    lay.add(
        timeseries(
            "Disk I/O",
            [
                prom('sum by (device) (rate(node_disk_read_bytes_total{device!~"dm-.*"}[$__rate_interval]))', "{{device}} read", ref="A"),
                prom('-sum by (device) (rate(node_disk_written_bytes_total{device!~"dm-.*"}[$__rate_interval]))', "{{device}} write", ref="B"),
            ],
            "Bps",
            minimum=None,
            desc="Reads above the axis, writes below.",
        ),
        8,
        8,
    )
    lay.add(
        timeseries(
            "Network",
            [
                prom(f'sum by (device) (rate(node_network_receive_bytes_total{{{host_nics}, device=~"$device"}}[$__rate_interval]))', "{{device}} in", ref="A"),
                prom(f'-sum by (device) (rate(node_network_transmit_bytes_total{{{host_nics}, device=~"$device"}}[$__rate_interval]))', "{{device}} out", ref="B"),
            ],
            "Bps",
            minimum=None,
            desc="Received above the axis, sent below. Loopback and Docker's own veth and bridge interfaces are left out; the Interface variable narrows it further.",
        ),
        8,
        8,
    )
    lay.add(
        bargauge("Filesystem usage", f'1 - instance:node_filesystem_avail:ratio{{{real_fs}, mountpoint=~"$mountpoint"}}', "{{mountpoint}}"),
        8,
        8,
    )

    lay.row("Containers")
    lay.add(
        timeseries(
            "CPU by container",
            [prom(f"name:container_cpu_usage:rate5m{{{project}}}", "{{name}}")],
            "short",
            desc="CPU cores in use (1 = one full core).",
        ),
        12,
        8,
    )
    lay.add(
        timeseries(
            "Memory by container",
            [prom(f'sum by (name) (container_memory_working_set_bytes{{name!="", {project}}})', "{{name}}")],
            "bytes",
        ),
        12,
        8,
    )
    lay.add(
        bargauge(
            "Memory against limit",
            f'sort_desc(container_memory_working_set_bytes{{name!="", {project}}} / (container_spec_memory_limit_bytes{{name!="", {project}}} > 0))',
            "{{name}}",
            desc="Containers without a memory limit are not shown.",
        ),
        8,
        9,
    )
    lay.add(
        timeseries(
            "Network by container",
            [prom(f'sum by (name) (rate(container_network_receive_bytes_total{{name!="", {project}}}[$__rate_interval]))', "{{name}}")],
            "Bps",
            desc="Bytes received; containers in the host network are not listed.",
        ),
        8,
        9,
    )
    lay.add(
        table(
            "Restarts in the last hour",
            'sort_desc(round(max by (name) (increase(docker_container_restarts_total{compose_project=~"$project"}[1h]))) > 0)',
            [],
            {"name": "Container", "Value": "Restarts"},
            desc="Restarts counted by Docker (also of containers stopped between restarts).",
        ),
        8,
        9,
    )

    lay.row("Logs")
    lay.add(
        timeseries(
            "Log lines by level",
            # Lines without a detected level would otherwise be an unnamed series.
            [loki('sum by (level) (count_over_time({compose_project=~"$project"} | label_format level=`{{ or .level "unknown" }}` [$__auto]))', "{{level}}")],
            "short",
            stack=True,
            bars=True,
            datasource=LOKI,
        ),
        24,
        6,
    )
    lay.add(
        logs(
            "Errors and warnings",
            '{compose_project=~"$project", level=~"error|fatal|warn"}',
            desc="Alloy normalizes every container's level to debug, info, warn, error or fatal.",
        ),
        24,
        11,
    )

    return dashboard(
        "linux-docker-overview",
        "Linux & Docker overview",
        ["linux", "docker", "node-exporter", "cadvisor", "loki"],
        lay,
        [
            query_variable("project", "Compose project", "label_values(container_last_seen, container_label_com_docker_compose_project)"),
            query_variable("device", "Interface", f"label_values(node_network_receive_bytes_total{{{host_nics}}}, device)"),
            query_variable("mountpoint", "Mount point", f"label_values(instance:node_filesystem_avail:ratio{{{real_fs}}}, mountpoint)"),
        ],
        "Host resources from Node Exporter, containers from cAdvisor, logs from Loki.",
    )


# ---------------------------------------------------------------------------------------
# Sentinel service
# ---------------------------------------------------------------------------------------
def sentinel() -> dict[str, Any]:
    job = 'job="sentinel"'
    lay = Layout()

    lay.row("Traffic")
    lay.add(stat("Requests / s", f"job:django_http_responses:rate5m{{{job}}}", "reqps"), 4, 4)
    lay.add(
        stat(
            "5xx ratio",
            f"job:django_http_responses_5xx:ratio_rate5m{{{job}}}",
            "percentunit",
            steps=thresholds((None, "green"), (0.01, "#EAB839"), (0.05, "red")),
        ),
        4,
        4,
    )
    lay.add(
        stat(
            "Latency p95",
            f"job:django_http_request_duration_seconds:p95_rate5m{{{job}}}",
            "s",
            steps=thresholds((None, "green"), (0.5, "#EAB839"), (1, "red")),
        ),
        4,
        4,
    )
    lay.add(
        stat(
            "Events ingested / s",
            f'sum(rate(sentinel_audit_events_ingested_total{{{job}, result="accepted"}}[5m])) or vector(0)',
            "short",
        ),
        4,
        4,
    )
    lay.add(
        stat(
            "Outbox pending",
            f"sentinel_outbox_pending_messages{{{job}}}",
            "none",
            steps=thresholds((None, "green"), (100, "#EAB839"), (1000, "red")),
            desc="Security events waiting to be dispatched as webhooks.",
        ),
        4,
        4,
    )
    lay.add(
        stat(
            "Oldest pending event",
            f"sentinel_outbox_oldest_pending_age_seconds{{{job}}}",
            "s",
            steps=thresholds((None, "green"), (60, "#EAB839"), (300, "red")),
        ),
        4,
        4,
    )
    lay.add(
        timeseries(
            "Responses by status class",
            [
                prom(
                    f'sum by (class) (label_replace(rate(django_http_responses_total_by_status_total{{{job}}}[$__rate_interval]), "class", "${{1}}xx", "status", "([0-9]).."))',
                    "{{class}}",
                )
            ],
            "reqps",
            stack=True,
        ),
        12,
        8,
    )
    bucket = f"django_http_requests_latency_seconds_by_view_method_bucket{{{job}}}"
    lay.add(
        timeseries(
            "Latency percentiles",
            [
                prom(f"histogram_quantile(0.50, sum by (le) (rate({bucket}[$__rate_interval])))", "p50", ref="A"),
                prom(f"histogram_quantile(0.95, sum by (le) (rate({bucket}[$__rate_interval])))", "p95", ref="B"),
                prom(f"histogram_quantile(0.99, sum by (le) (rate({bucket}[$__rate_interval])))", "p99", ref="C"),
            ],
            "s",
        ),
        12,
        8,
    )
    lay.add(
        timeseries(
            "Slowest views (p95)",
            [prom(f"topk(5, histogram_quantile(0.95, sum by (view, le) (rate({bucket}[$__rate_interval]))))", "{{view}}")],
            "s",
        ),
        12,
        8,
    )
    lay.add(
        timeseries(
            "Audit event ingestion",
            [prom(f"sum by (result) (rate(sentinel_audit_events_ingested_total{{{job}}}[$__rate_interval]))", "{{result}}")],
            "short",
            stack=True,
            desc="Events per second by outcome: accepted, duplicate (idempotency key reused), rejected.",
        ),
        12,
        8,
    )

    lay.row("Webhooks and resources")
    lay.add(
        timeseries(
            "Webhook deliveries in progress",
            [prom(f'sentinel_webhook_deliveries{{{job}, status=~"pending|in_progress|retrying"}}', "{{status}}")],
            "short",
            stack=True,
        ),
        8,
        8,
    )
    lay.add(
        timeseries(
            "Final webhook failures",
            [prom(f'sentinel_webhook_deliveries{{{job}, status=~"failed|exhausted"}}', "{{status}}")],
            "short",
            desc="Total deliveries that failed permanently or exhausted their retries.",
        ),
        8,
        8,
    )
    lay.add(
        timeseries(
            "Container CPU",
            [prom('name:container_cpu_usage:rate5m{container_label_com_docker_compose_project="sentinel"}', "{{container_label_com_docker_compose_service}}")],
            "short",
            desc="CPU cores in use per Sentinel service.",
        ),
        8,
        8,
    )

    lay.row("Logs")
    lay.add(
        logs(
            "Sentinel logs",
            '{compose_project="sentinel", level=~"$level"}',
            desc="Open a line to see its request_id; search for it in Explore to follow one request.",
        ),
        24,
        12,
    )

    return dashboard(
        "sentinel-service",
        "Sentinel IAM & Audit Service",
        ["sentinel", "django", "service"],
        lay,
        [custom_variable("level", "Log level", ["fatal", "error", "warn", "info", "debug"], ["fatal", "error", "warn"])],
        "RED metrics, audit ingestion, webhook outbox and logs of the Sentinel service.",
    )


# ---------------------------------------------------------------------------------------
# The observability stack itself
# ---------------------------------------------------------------------------------------
def observability_stack() -> dict[str, Any]:
    # Integrations Alertmanager has tried at least once; it exports every supported one.
    used = "(sum by (integration) (alertmanager_notifications_total) > 0)"
    lay = Layout()

    lay.row("Health")
    lay.add(
        stat(
            "Targets down",
            "count(up == 0) or vector(0)",
            "none",
            steps=thresholds((None, "green"), (1, "red")),
        ),
        4,
        4,
    )
    lay.add(
        stat(
            "Firing alerts",
            'count(ALERTS{alertstate="firing", alertname!="Watchdog"}) or vector(0)',
            "none",
            steps=thresholds((None, "green"), (1, "red")),
        ),
        4,
        4,
    )
    lay.add(stat("Active series", "prometheus_tsdb_head_series", "short"), 4, 4)
    lay.add(stat("Samples / s", "sum(rate(prometheus_tsdb_head_samples_appended_total[5m]))", "short"), 4, 4)
    lay.add(stat("Log lines / s", "sum(rate(loki_distributor_lines_received_total[5m]))", "short"), 4, 4)
    lay.add(
        stat(
            "Notifications failed (1h)",
            "sum(increase(alertmanager_notifications_failed_total[1h])) or vector(0)",
            "none",
            steps=thresholds((None, "green"), (1, "red")),
        ),
        4,
        4,
    )
    lay.add(table("Scrape targets", "up", ["__name__"], {"job": "Job", "instance": "Instance", "Value": "Up"}), 12, 11)
    lay.add(
        table(
            "Firing alerts",
            'ALERTS{alertstate="firing"}',
            ["__name__", "alertstate", "Value"],
            {"alertname": "Alert", "severity": "Severity"},
        ),
        12,
        11,
    )

    lay.row("Pipelines")
    lay.add(
        timeseries(
            "Log lines into Loki",
            [
                prom("sum(rate(loki_write_sent_entries_total[$__rate_interval]))", "sent by Alloy", ref="A"),
                prom("sum(rate(loki_write_dropped_entries_total[$__rate_interval]))", "dropped by Alloy", ref="B"),
                prom("sum by (reason) (rate(loki_process_dropped_lines_total[$__rate_interval]))", "filtered: {{reason}}", ref="C"),
            ],
            "short",
            desc="Filtered lines are dropped on purpose (for example successful Docker API calls).",
        ),
        12,
        8,
    )
    lay.add(
        timeseries(
            "Alertmanager notifications",
            [
                prom(f"sum by (integration) (rate(alertmanager_notifications_total[$__rate_interval])) and on (integration) {used}", "{{integration}} attempts", ref="A"),
                prom(f"sum by (integration) (rate(alertmanager_notifications_failed_total[$__rate_interval])) and on (integration) {used}", "{{integration}} failed", ref="B"),
            ],
            "short",
            desc="Per second, for the integrations Alertmanager has used since it started (it exports a series for every integration it supports).",
        ),
        12,
        8,
    )
    lay.add(
        timeseries(
            "Rule group evaluation time",
            # rule_group is "<file>;<group>": the group name alone keeps the legend readable.
            [prom('max by (group) (label_replace(prometheus_rule_group_last_duration_seconds, "group", "$1", "rule_group", ".*;(.+)"))', "{{group}}")],
            "s",
        ),
        12,
        8,
    )
    lay.add(
        timeseries(
            "Stack memory",
            [prom('sum by (container_label_com_docker_compose_service) (container_memory_working_set_bytes{container_label_com_docker_compose_project="observability"})', "{{container_label_com_docker_compose_service}}")],
            "bytes",
            stack=True,
        ),
        12,
        8,
    )

    return dashboard(
        "observability-stack",
        "Observability stack health",
        ["prometheus", "loki", "alloy", "alertmanager", "meta-monitoring"],
        lay,
        [],
        "Meta-monitoring: is the monitoring itself working?",
    )


DASHBOARDS = {
    Path("Infrastructure/linux-docker-overview.json"): linux_docker_overview,
    Path("Services/sentinel.json"): sentinel,
    Path("Platform/observability-stack.json"): observability_stack,
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if the files differ")
    args = parser.parse_args()

    stale = []
    for relative, build in DASHBOARDS.items():
        path = OUT / relative
        content = json.dumps(build(), indent=2, ensure_ascii=False) + "\n"
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                stale.append(str(relative))
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        print(f"wrote {path.relative_to(OUT.parents[2])}")
    if stale:
        print("out of date, run `make dashboards`: " + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
