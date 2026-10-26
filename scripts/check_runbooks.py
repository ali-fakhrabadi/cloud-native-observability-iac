#!/usr/bin/env python3
"""Every alert must link to its own runbook section, and every section must exist.

Checks the Prometheus rules (config/prometheus/rules) and Loki rules (config/loki/rules):
each `alert:` has a `runbook_url` ending in `#<alertname in lowercase>`, and
docs/runbooks.md has a `### <AlertName>` heading for it. Standard library only.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RULE_DIRS = (ROOT / "config" / "prometheus" / "rules", ROOT / "config" / "loki" / "rules")
RUNBOOKS = ROOT / "docs" / "runbooks.md"
BASE_URL = "https://github.com/ali-fakhrabadi/cloud-native-observability-iac/blob/main/docs/runbooks.md#"


def main() -> int:
    headings = set(re.findall(r"^### (\w+)\s*$", RUNBOOKS.read_text(encoding="utf-8"), flags=re.MULTILINE))
    problems: list[str] = []
    alerts: list[str] = []
    for directory in RULE_DIRS:
        for path in sorted(directory.rglob("*.yml")):
            # Split the file at each alert so every runbook_url belongs to its alert.
            chunks = re.split(r"^\s*- alert: ", path.read_text(encoding="utf-8"), flags=re.MULTILINE)[1:]
            for chunk in chunks:
                name = chunk.split()[0]
                alerts.append(name)
                url = re.search(r'runbook_url:\s*"([^"]+)"', chunk)
                expected = BASE_URL + name.lower()
                if url is None:
                    problems.append(f"{path.name}: {name} has no runbook_url")
                elif url.group(1) != expected:
                    problems.append(f"{path.name}: {name} links to {url.group(1)}, expected {expected}")
                if name not in headings:
                    problems.append(f"docs/runbooks.md: no '### {name}' section")
    for orphan in sorted(headings - set(alerts)):
        problems.append(f"docs/runbooks.md: section '{orphan}' has no alert")
    for problem in problems:
        print(f"ERROR {problem}")
    print(f"{len(alerts)} alerts, {len(headings)} runbook sections: {'OK' if not problems else 'FAILED'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
