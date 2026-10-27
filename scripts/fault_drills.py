#!/usr/bin/env python3
"""Fault-injection drills: break things on purpose and measure the alerting pipeline.

Each drill injects one real fault on the Docker host, waits until alert-sink receives the
matching notification, removes the fault at once and waits for the "resolved"
notification. All timestamps come from the host's clock: this script records when it
injected and removed each fault; alert-sink records when every notification arrived and
when its alert started firing (the rule's `for` period over).

  service-down     stop the stack's Grafana          -> TargetDown (critical, for 2m)
  crash-loop       container exiting after 3 s      -> ContainerRestarting (no for)
  memory-pressure  container at ~95% of its limit    -> ContainerMemoryNearLimit (for 5m)
  error-log-burst  service logging an error a second -> ContainerErrorLogBurst (Loki, for 5m)
  cpu-saturation   container spinning at its limit   -> ContainerCpuThrottled (for 15m)

The drills of a round run concurrently, in disposable containers labelled drill=true
(small CPU and memory limits). Apart from those, only the stack's own Grafana is touched.
A round ends when every drill has its resolved notification, so rounds do not overlap in
Alertmanager's notification groups. The CPU rule waits 15 minutes before firing, and a
crash loop stays alerted for up to 15 minutes after it stops (the rule counts restarts
over 15 minutes), so a round takes about 25 minutes.

Usage: scripts/fault_drills.py [--rounds 3] [--drill NAME ...] [--output FILE.json]
Requires the running stack (make up) and access to Docker. Standard library only.
"""

from __future__ import annotations

import argparse
import json
import signal
import statistics
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMPOSE = ["docker", "compose", "-f", str(ROOT / "docker-compose.observability.yml")]
POLL_SECONDS = 5


def run(*args: str, timeout: float = 120) -> str:
    result = subprocess.run(  # noqa: S603 - fixed argument lists
        list(args),
        # Never read the caller's stdin (a piped script would be swallowed).
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}: {result.stderr.strip()[:300]}")
    return result.stdout


def now() -> datetime:
    return datetime.now(UTC)


def parse_time(value: str | None) -> datetime | None:
    if not value or value.startswith("0001-"):
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


@dataclass
class Drill:
    name: str
    alertname: str
    labels: dict[str, str]
    expectation: str
    inject: Callable[[], None] = field(repr=False)
    recover: Callable[[], None] = field(repr=False)
    timeout_seconds: float = 1800
    injected_at: datetime | None = None
    fired_at: datetime | None = None
    notified_at: datetime | None = None
    recovered_at: datetime | None = None
    resolved_at: datetime | None = None
    error: str | None = None

    def matches(self, record: dict) -> bool:
        labels = record.get("labels") or {}
        return record.get("alertname") == self.alertname and all(
            labels.get(key) == value for key, value in self.labels.items()
        )

    def result(self) -> dict:
        def seconds(start: datetime | None, end: datetime | None) -> float | None:
            return round((end - start).total_seconds(), 1) if start and end else None

        return {
            "drill": self.name,
            "alert": self.alertname,
            "labels": self.labels,
            "expectation": self.expectation,
            "injected_at": self.injected_at.isoformat() if self.injected_at else None,
            # Fault to alert firing (the rule's `for` plus scrape and evaluation delays).
            "time_to_alert_s": seconds(self.injected_at, self.fired_at),
            # Fault to notification received (adds Alertmanager's group_wait and delivery).
            "time_to_notify_s": seconds(self.injected_at, self.notified_at),
            # Fault removed to "resolved" notification received.
            "time_to_resolved_s": seconds(self.recovered_at, self.resolved_at),
            "error": self.error,
        }


class Drills:
    def __init__(self, image: str, suffix: str) -> None:
        self.image = image
        self.suffix = suffix

    def container(self, kind: str, *, cpus: str, memory: str, command: str, restart: bool = False,
                  compose_service: bool = False) -> tuple[str, Callable[[], None], Callable[[], None]]:
        name = f"drill-{kind}-{self.suffix}"
        args = ["docker", "run", "--detach", "--name", name, "--label", "drill=true",
                "--cpus", cpus, "--memory", memory, "--memory-swap", memory,
                "--security-opt", "no-new-privileges", "--cap-drop", "ALL", "--network", "none"]
        if restart:
            args += ["--restart", "always"]
        if compose_service:
            # Log alerts are grouped by Compose project and service, as for real services.
            args += ["--label", "com.docker.compose.project=drill", "--label", f"com.docker.compose.service={name}"]
        args += [self.image, "python3", "-u", "-c", command]

        def inject() -> None:
            run(*args)

        def recover() -> None:
            run("docker", "rm", "--force", name)

        return name, inject, recover

    def build(self, selected: list[str]) -> list[Drill]:
        drills: list[Drill] = []

        def stop_grafana() -> None:
            run(*COMPOSE, "stop", "grafana")

        def start_grafana() -> None:
            run(*COMPOSE, "up", "--detach", "--wait", "grafana", timeout=180)

        drills.append(Drill(
            "service-down", "TargetDown", {"job": "grafana"},
            "for 2m + up to 30 s scrape and evaluation + 10 s group_wait (critical)",
            stop_grafana, start_grafana))

        name, inject, recover = self.container(
            "crash-loop", cpus="0.2", memory="64m", restart=True,
            command="import time; time.sleep(3); raise SystemExit(1)")
        drills.append(Drill(
            "crash-loop", "ContainerRestarting", {"name": name},
            "3 restarts counted by Docker (no for) + up to 30 s scrape and evaluation + 30 s group_wait",
            inject, recover))

        # ~112 MiB of touched memory plus the interpreter, under a 128 MiB limit.
        name, inject, recover = self.container(
            "memory-pressure", cpus="0.2", memory="128m",
            command="import time; data = b'x' * (112 * 1024 * 1024); time.sleep(86400)")
        drills.append(Drill(
            "memory-pressure", "ContainerMemoryNearLimit", {"name": name},
            "for 5m + up to 45 s cAdvisor collection, scrape and evaluation + 30 s group_wait",
            inject, recover))

        name, inject, recover = self.container(
            "error-log-burst", cpus="0.1", memory="32m", compose_service=True,
            command=("import json, time\n"
                     "while True:\n"
                     "    print(json.dumps({'level': 'error', 'msg': 'drill: simulated failure'}))\n"
                     "    time.sleep(1)"))
        drills.append(Drill(
            "error-log-burst", "ContainerErrorLogBurst", {"compose_project": "drill", "compose_service": name},
            "21 errors logged + for 5m + up to 1 m ruler evaluation + 30 s group_wait",
            inject, recover))

        name, inject, recover = self.container(
            "cpu-saturation", cpus="0.1", memory="32m", command="while True: pass")
        drills.append(Drill(
            "cpu-saturation", "ContainerCpuThrottled", {"name": name},
            # rate() over 5 minutes divides by the whole window, so for a new container the
            # usage ratio climbs for about 4 minutes before it passes 80%.
            "~4 min until the 5-minute usage rate passes 80% + for 15m + 30 s group_wait",
            inject, recover, timeout_seconds=2400))

        return [drill for drill in drills if not selected or drill.name in selected]


def notifications(since: datetime) -> list[dict]:
    output = run(*COMPOSE, "logs", "--no-log-prefix", "--since", since.strftime("%Y-%m-%dT%H:%M:%SZ"), "alert-sink")
    records = []
    for line in output.splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("msg") == "notification received":
            records.append(record)
    return records


def run_round(drills: list[Drill]) -> None:
    started = now()
    for drill in drills:
        drill.injected_at = now()
        try:
            drill.inject()
        except RuntimeError as exc:
            drill.error = f"inject failed: {exc}"
        print(f"  injected {drill.name}", flush=True)

    pending = [drill for drill in drills if drill.error is None]
    while pending:
        time.sleep(POLL_SECONDS)
        records = notifications(started)
        for drill in list(pending):
            if drill.notified_at is None:
                firing = [r for r in records if drill.matches(r) and r.get("status") == "firing"]
                if firing:
                    drill.fired_at = parse_time(firing[0].get("starts_at"))
                    drill.notified_at = parse_time(firing[0].get("received_at"))
                    drill.recovered_at = now()
                    try:
                        drill.recover()
                    except RuntimeError as exc:
                        drill.error = f"recover failed: {exc}"
                        pending.remove(drill)
                    print(f"  {drill.name}: notified after {drill.result()['time_to_notify_s']} s, fault removed",
                          flush=True)
            else:
                resolved = [r for r in records if drill.matches(r) and r.get("status") == "resolved"
                            and parse_time(r.get("received_at")) > drill.recovered_at]
                if resolved:
                    drill.resolved_at = parse_time(resolved[0].get("received_at"))
                    pending.remove(drill)
                    print(f"  {drill.name}: resolved {drill.result()['time_to_resolved_s']} s after the fix",
                          flush=True)
                    continue
            if drill in pending and (now() - drill.injected_at).total_seconds() > drill.timeout_seconds:
                drill.error = "timed out"
                pending.remove(drill)
                print(f"  {drill.name}: timed out", flush=True)


def cleanup() -> None:
    names = run("docker", "ps", "--all", "--quiet", "--filter", "label=drill=true").split()
    if names:
        run("docker", "rm", "--force", *names)
    run(*COMPOSE, "up", "--detach", "--wait", "grafana", timeout=180)


def summarize(results: list[dict]) -> str:
    lines = ["| Drill | Alert | Time to alert | Time to notification | Time to resolved | Expectation |",
             "|---|---|---|---|---|---|"]
    for drill in dict.fromkeys(r["drill"] for r in results):
        rows = [r for r in results if r["drill"] == drill]

        def stat(key: str) -> str:
            values = [r[key] for r in rows if r[key] is not None]
            if not values:
                return "n/a"
            if len(values) == 1:
                return f"{values[0]:.0f} s"
            return f"{statistics.median(values):.0f} s ({min(values):.0f}-{max(values):.0f})"

        lines.append(f"| {drill} | {rows[0]['alert']} | {stat('time_to_alert_s')} | {stat('time_to_notify_s')} "
                     f"| {stat('time_to_resolved_s')} | {rows[0]['expectation']} |")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--drill", action="append", default=[], metavar="NAME")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    # Stop cleanly (drill containers removed, Grafana back) on Ctrl-C or `kill`, also when
    # started in the background, where shells leave SIGINT ignored.
    signal.signal(signal.SIGINT, signal.default_int_handler)
    signal.signal(signal.SIGTERM, signal.default_int_handler)

    config = json.loads(run(*COMPOSE, "config", "--format", "json"))
    # The alert-sink image (Python, already on the host) runs the drill containers.
    image = config["services"]["alert-sink"]["image"]
    run_id = now().strftime("%Y%m%d%H%M")
    results: list[dict] = []
    for number in range(1, args.rounds + 1):
        print(f"round {number}/{args.rounds}", flush=True)
        drills = Drills(image, f"{run_id}-{number}").build(args.drill)
        try:
            run_round(drills)
        finally:
            cleanup()
        results += [{"round": number, **drill.result()} for drill in drills]
        if args.output:  # after every round, so an interrupted run keeps what it measured
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps({"run": run_id, "results": results}, indent=2) + "\n")

    print()
    print(summarize(results))
    return 1 if any(r["error"] for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
