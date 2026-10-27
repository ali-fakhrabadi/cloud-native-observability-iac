#!/usr/bin/env python3
"""Dark-mode screenshots of every provisioned Grafana dashboard.

Runs inside the pinned Playwright image (`make screenshots`): logs in through Grafana's
API with the admin password from the Docker secret file, opens each dashboard in kiosk
mode, grows the viewport to the dashboard's full height so every panel renders, and saves
a PNG. The password is read from the file and never printed.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

DASHBOARDS = ("linux-docker-overview", "sentinel-service", "observability-stack")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--grafana", default="http://127.0.0.1:3000")
    parser.add_argument("--user", default="admin")
    parser.add_argument("--password-file", type=Path, default=Path("/run/secrets/grafana_admin_password"))
    parser.add_argument("--range", default="now-6h", help="dashboard time range start")
    parser.add_argument("--width", type=int, default=1600)
    parser.add_argument("--out", type=Path, default=Path("/out"))
    args = parser.parse_args()

    password = args.password_file.read_text().strip()
    args.out.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        context = browser.new_context(viewport={"width": args.width, "height": 1000}, color_scheme="dark")
        login = context.request.post(f"{args.grafana}/login", data={"user": args.user, "password": password})
        if not login.ok:
            print(f"Grafana login failed: HTTP {login.status}", file=sys.stderr)
            return 1
        page = context.new_page()
        for uid in DASHBOARDS:
            url = f"{args.grafana}/d/{uid}?orgId=1&theme=dark&kiosk&from={args.range}&to=now"
            page.set_viewport_size({"width": args.width, "height": 1000})
            page.goto(url, wait_until="networkidle")
            height = page.evaluate("document.documentElement.scrollHeight")
            # Panels outside the viewport are not rendered: make the viewport the page.
            page.set_viewport_size({"width": args.width, "height": min(max(height, 1000), 8000)})
            page.wait_for_load_state("networkidle")
            page.wait_for_timeout(5000)
            path = args.out / f"{uid}.png"
            page.screenshot(path=path, full_page=True)
            print(f"saved {path.name} ({args.width}x{height})")
        browser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
