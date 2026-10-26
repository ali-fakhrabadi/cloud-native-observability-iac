#!/usr/bin/env python3
"""Records every Alertmanager notification it receives as one JSON line per alert.

It is the default webhook receiver of the stack: notifications work without any external
service, every notification ends up in Loki (through the container logs) as an audit
trail, and fault-injection drills can measure the delay from an alert starting to its
notification arriving. Replace the receiver URL in secrets/alertmanager_webhook_url to
deliver to a real system instead.

Standard library only. Endpoints: POST /<any path> (Alertmanager webhook payload, v4),
GET /healthz.
"""

from __future__ import annotations

import json
import sys
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY_BYTES = 1024 * 1024


def _parse_time(value: str | None) -> datetime | None:
    if not value or value.startswith("0001-"):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


class Handler(BaseHTTPRequestHandler):
    server_version = "alert-sink"

    def do_GET(self) -> None:
        self._reply(200 if self.path == "/healthz" else 404)

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            self._reply(413 if length > MAX_BODY_BYTES else 400)
            return
        try:
            payload = json.loads(self.rfile.read(length))
            alerts = payload["alerts"]
        except (ValueError, KeyError, TypeError):
            self._reply(400)
            return
        received = datetime.now(UTC)
        for alert in alerts:
            labels = alert.get("labels", {})
            started = _parse_time(alert.get("startsAt"))
            record = {
                "msg": "notification received",
                "level": "info",
                "path": self.path,
                "receiver": payload.get("receiver"),
                "status": alert.get("status"),
                "alertname": labels.get("alertname"),
                "severity": labels.get("severity"),
                "instance": labels.get("instance") or labels.get("name"),
                "starts_at": alert.get("startsAt"),
                "received_at": received.isoformat(),
                # Delay from the alert starting to its notification arriving: rule `for`
                # duration, evaluation interval, Alertmanager grouping and delivery.
                "delay_seconds": round((received - started).total_seconds(), 3) if started else None,
                "fingerprint": alert.get("fingerprint"),
            }
            sys.stdout.write(json.dumps(record, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        self._reply(200)

    def _reply(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - stdlib signature
        return  # one structured line per alert is enough; no access log


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9099), Handler).serve_forever()  # noqa: S104 - container
