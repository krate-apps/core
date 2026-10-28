#!/usr/bin/env python3
"""Force a relative Location after addtorrent.php POST.

Caddy handle_path /{user}/rutorrent/* strips the prefix, so Novik
Requests::publicBaseURL('/php/addtorrent.php') becomes https://host/ and the
302 targets /php/addtorrent.php (404 or auth). The upload iframe then has no
noty(...) lines and uploadResults() always reports addTorrentFailed — even
when rTorrent already loaded the torrent.

Always redirect to ./addtorrent.php?... so the iframe stays under the
app subpath and receives the Success noty script. Idempotent.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

MARKER = "KRATE: with Caddy handle_path"

OLD = (
    "\t$base = Requests::publicBaseURL('/php/addtorrent.php');\n"
    '\t$location = "Location: ".($base===false ? "./addtorrent.php?" : $base."php/addtorrent.php?");'
)

NEW = (
    "\t// KRATE: with Caddy handle_path, publicBaseURL becomes https://host/ (prefix stripped),\n"
    "\t// so the iframe follows /php/addtorrent.php (404/auth) and uploadResults() sees no noty()\n"
    "\t// → false addTorrentFailed while the torrent was already loaded.\n"
    '\t$location = "Location: ./addtorrent.php?";'
)


def patch(app_root: Path) -> int:
    path = app_root / "php" / "addtorrent.php"
    if not path.is_file():
        print(f"rutorrent: addtorrent redirect patch: missing {path}", file=sys.stderr)
        return 1
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print("rutorrent: addtorrent relative Location already patched")
        return 0
    if OLD not in text:
        print(
            f"rutorrent: addtorrent redirect patch: expected Location block not found in {path}",
            file=sys.stderr,
        )
        return 1
    path.write_text(text.replace(OLD, NEW, 1), encoding="utf-8")
    print("rutorrent: patched php/addtorrent.php relative Location after POST")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_root", type=Path, help="ruTorrent app root")
    return patch(parser.parse_args().app_root)


if __name__ == "__main__":
    sys.exit(main())
