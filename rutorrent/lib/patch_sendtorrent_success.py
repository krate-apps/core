#!/usr/bin/env python3
"""Do not treat void XML-RPC success as a failed torrent add.

sendTorrent() requires run()&&!fault; sendMagnet()/mkdir use success().
run() stays false when rtorrent/tinyxml2 answers with empty <params>, so
the UI shows addTorrentFailed while the torrent is already listed.

Judge those loads by !fault after run(). Idempotent.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

MARKER = "KRATE: judge load success by !fault"

REPLACEMENTS = (
    (
        "\t\t\tif($req->run() && !$req->fault)\n"
        "\t\t\t\t$hash = $torrent->hash_info();",
        "\t\t\t// KRATE: judge load success by !fault (void tinyxml2 answers make run() false)\n"
        "\t\t\t$req->run();\n"
        "\t\t\tif(!$req->fault)\n"
        "\t\t\t\t$hash = $torrent->hash_info();",
    ),
    (
        "\t\t\t\tif($req->success())\n"
        "\t\t\t\t\treturn($hash);",
        "\t\t\t\t// KRATE: judge load success by !fault (void tinyxml2 answers make run() false)\n"
        "\t\t\t\t$req->run();\n"
        "\t\t\t\tif(!$req->fault)\n"
        "\t\t\t\t\treturn($hash);",
    ),
    (
        "\t\t\t$mkdir = new rXMLRPCRequest( new rXMLRPCCommand( 'execute', array('mkdir','-p',$directory) ) );\n"
        "\t\t\treturn($mkdir->success() ? true : self::directoryFailed());",
        "\t\t\t$mkdir = new rXMLRPCRequest( new rXMLRPCCommand( 'execute', array('mkdir','-p',$directory) ) );\n"
        "\t\t\t// KRATE: judge load success by !fault (void tinyxml2 answers make run() false)\n"
        "\t\t\t$mkdir->run();\n"
        "\t\t\treturn(!$mkdir->fault ? true : self::directoryFailed());",
    ),
)


def patch(app_root: Path) -> int:
    path = app_root / "php" / "rtorrent.php"
    if not path.is_file():
        print(f"rutorrent: sendTorrent patch: missing {path}", file=sys.stderr)
        return 1
    text = path.read_text(encoding="utf-8")
    if all(new in text for _, new in REPLACEMENTS):
        print("rutorrent: sendTorrent success checks already patched")
        return 0
    for old, new in REPLACEMENTS:
        if new in text:
            continue
        if old not in text:
            print(
                f"rutorrent: sendTorrent patch: block not found in {path}",
                file=sys.stderr,
            )
            print(f"  missing:\n{old!r}", file=sys.stderr)
            return 1
        text = text.replace(old, new, 1)
    path.write_text(text, encoding="utf-8")
    print(f"rutorrent: patched php/rtorrent.php sendTorrent/sendMagnet/mkdir success ({MARKER})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_root", type=Path, help="ruTorrent app root")
    return patch(parser.parse_args().app_root)


if __name__ == "__main__":
    sys.exit(main())
