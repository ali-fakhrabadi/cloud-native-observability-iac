#!/usr/bin/env python3
"""Dark-mode screenshots of every provisioned Grafana dashboard.

Runs in the image built from tools/screenshots (`make screenshots`): logs in through
Grafana's API with the admin password from the Docker secret file, opens each dashboard in
kiosk mode, grows the viewport to the dashboard's full height so every panel renders, and
saves a PNG. The password is read from the file and never printed.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from urllib.parse import urlencode

from playwright.sync_api import Page, sync_playwright

DASHBOARDS = ("linux-docker-overview", "sentinel-service", "observability-stack")
MAX_HEIGHT = 8000

# Grafana scrolls the dashboard inside its own element, not the document, so the page
# height is the bottom of the tallest scrolling element that fills most of the viewport.
CONTENT_HEIGHT_JS = """() => {
    let height = document.documentElement.scrollHeight;
    for (const element of document.querySelectorAll("*")) {
        const overflow = getComputedStyle(element).overflowY;
        if ((overflow === "auto" || overflow === "scroll") && element.clientHeight > innerHeight / 2) {
            height = Math.max(height, element.getBoundingClientRect().top + element.scrollHeight);
        }
    }
    return Math.ceil(height);
}"""


def render_full_height(page: Page, width: int) -> int:
    """Grow the viewport until it holds the whole dashboard; panels below it never load."""
    height = 0
    for _ in range(4):
        content = min(page.evaluate(CONTENT_HEIGHT_JS), MAX_HEIGHT)
        if content <= height:
            break
        height = content
        page.set_viewport_size({"width": width, "height": height})
        page.wait_for_load_state("networkidle")
        page.wait_for_timeout(3000)
    return height


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--grafana", default="http://127.0.0.1:3000")
    parser.add_argument("--user", default="admin")
    parser.add_argument("--password-file", type=Path, default=Path("/run/secrets/grafana_admin_password"))
    parser.add_argument("--range", default="now-6h", help="dashboard time range start")
    parser.add_argument(
        "--var",
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="dashboard variable, repeatable (device=eth0); dashboards without it ignore it",
    )
    parser.add_argument("--width", type=int, default=1600)
    parser.add_argument("--out", type=Path, default=Path("/out"))
    args = parser.parse_args()

    query = [("orgId", "1"), ("theme", "dark"), ("from", args.range), ("to", "now")]
    for variable in args.var:
        name, _, value = variable.partition("=")
        query.append((f"var-{name}", value))

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
            page.set_viewport_size({"width": args.width, "height": 1000})
            page.goto(f"{args.grafana}/d/{uid}?{urlencode(query)}&kiosk", wait_until="networkidle")
            page.wait_for_timeout(2000)
            height = render_full_height(page, args.width)
            path = args.out / f"{uid}.png"
            page.screenshot(path=path)
            print(f"saved {path.name} ({args.width}x{height})")
        browser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
