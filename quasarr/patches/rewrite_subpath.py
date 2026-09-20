#!/usr/bin/env python3
"""Rewrite in-page navigations to quasarrUrl() so KRATE strip_prefix subpaths work.

Idempotent. html_templates.py is skipped (0001 injects the JS helper there).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ABS_ASSIGN = re.compile(
    r"(window\.location\.href\s*=\s*)(?!quasarrUrl\()(['\"])(/[^'\"]*)\2"
)
# Bare location.href='/…' — not window.location (lookbehind excludes a preceding dot).
LOC_ASSIGN = re.compile(
    r"(?<![\w.])(location\.href\s*=\s*)(?!quasarrUrl\()(['\"])(/[^'\"]*)\2"
)
IDENT_ASSIGN = re.compile(
    r"(window\.location\.href\s*=\s*)(?!quasarrUrl\()(url)\b"
)


def rewrite(text: str) -> str:
    text = ABS_ASSIGN.sub(r"\1quasarrUrl(\2\3\2)", text)
    text = LOC_ASSIGN.sub(r"\1quasarrUrl(\2\3\2)", text)
    text = IDENT_ASSIGN.sub(r"\1quasarrUrl(\2)", text)
    return text


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    pkg = root / "quasarr"
    if not pkg.is_dir():
        print(f"missing package dir: {pkg}", file=sys.stderr)
        return 1
    changed = 0
    for path in pkg.rglob("*.py"):
        if path.name == "html_templates.py":
            continue
        original = path.read_text(encoding="utf-8")
        updated = rewrite(original)
        if updated != original:
            path.write_text(updated, encoding="utf-8")
            changed += 1
    print(f"rewrote {changed} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
