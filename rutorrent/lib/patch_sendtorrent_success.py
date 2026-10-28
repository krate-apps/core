#!/usr/bin/env python3
"""Treat torrent add as success when rTorrent already has the hash.

Two failure modes both show addTorrentFailed while the torrent is listed:

1. tinyxml2 void <params/> → run() false, fault unset
2. SCGI/RPC timeout after load → run() false, fault set (transport)

Judge success by: run(), then accept the info-hash when !fault OR the hash
is already in download_list. Idempotent (regex).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

MARKER = "KRATE: accept load if listed"

SEND_TORRENT_NEW = (
    "\t\t\t$req->addCommand( $cmd );\n"
    "\t\t\t// KRATE: accept load if listed (void tinyxml2 / timeout-after-load)\n"
    "\t\t\t$req->run();\n"
    "\t\t\t$__h = $torrent->hash_info();\n"
    "\t\t\tif($__h && (!$req->fault || isset(self::loadedHashes()[strtoupper($__h)])))\n"
    "\t\t\t\t$hash = $__h;"
)

SEND_MAGNET_NEW = (
    "\t\t\t\t$req->addCommand( $cmd );\n"
    "\t\t\t\t// KRATE: accept load if listed (void tinyxml2 / timeout-after-load)\n"
    "\t\t\t\t$req->run();\n"
    "\t\t\t\tif(!$req->fault || isset(self::loadedHashes()[strtoupper($hash)]))\n"
    "\t\t\t\t\treturn($hash);"
)

MKDIR_NEW = (
    "\t\t\t$mkdir = new rXMLRPCRequest( new rXMLRPCCommand( 'execute', array('mkdir','-p',$directory) ) );\n"
    "\t\t\t// KRATE: accept load if listed (void tinyxml2 / timeout-after-load)\n"
    "\t\t\t$mkdir->run();\n"
    "\t\t\treturn(!$mkdir->fault ? true : self::directoryFailed());"
)

# Match stock Novik and the earlier weaker KRATE !fault-only patch.
SEND_TORRENT_RE = re.compile(
    r"\t\t\t\$req->addCommand\(\s*\$cmd\s*\);\n"
    r"(?:"
    r"\t\t\t// KRATE: judge load success by !fault[^\n]*\n"
    r"\t\t\t\$req->run\(\);\n"
    r"\t\t\tif\(!\$req->fault\)\n"
    r"\t\t\t\t\$hash = \$torrent->hash_info\(\);"
    r"|"
    r"\t\t\tif\(\$req->run\(\) && !\$req->fault\)\n"
    r"\t\t\t\t\$hash = \$torrent->hash_info\(\);"
    r")"
)

SEND_MAGNET_RE = re.compile(
    r"\t\t\t\t\$req->addCommand\(\s*\$cmd\s*\);\n"
    r"(?:"
    r"\t\t\t\t// KRATE: judge load success by !fault[^\n]*\n"
    r"\t\t\t\t\$req->run\(\);\n"
    r"\t\t\t\tif\(!\$req->fault\)\n"
    r"\t\t\t\t\treturn\(\$hash\);"
    r"|"
    r"\t\t\t\tif\(\$req->success\(\)\)\n"
    r"\t\t\t\t\treturn\(\$hash\);"
    r")"
)

MKDIR_RE = re.compile(
    r"\t\t\t\$mkdir = new rXMLRPCRequest\(\s*new rXMLRPCCommand\(\s*'execute',\s*array\('mkdir','-p',\$directory\)\s*\)\s*\);\n"
    r"(?:"
    r"\t\t\t// KRATE: (?:judge load success by !fault|accept load if listed)[^\n]*\n"
    r"\t\t\t\$mkdir->run\(\);\n"
    r"\t\t\treturn\(!\$mkdir->fault \? true : self::directoryFailed\(\)\);"
    r"|"
    r"\t\t\treturn\(\$mkdir->success\(\) \? true : self::directoryFailed\(\)\);"
    r")"
)


def patch(app_root: Path) -> int:
    path = app_root / "php" / "rtorrent.php"
    if not path.is_file():
        print(f"rutorrent: sendTorrent patch: missing {path}", file=sys.stderr)
        return 1
    text = path.read_text(encoding="utf-8")
    if MARKER in text and SEND_TORRENT_NEW in text and SEND_MAGNET_NEW in text:
        print("rutorrent: sendTorrent listed-hash success already patched")
        return 0

    original = text
    text, n1 = SEND_TORRENT_RE.subn(SEND_TORRENT_NEW, text, count=1)
    text, n2 = SEND_MAGNET_RE.subn(SEND_MAGNET_NEW, text, count=1)
    text, n3 = MKDIR_RE.subn(MKDIR_NEW, text, count=1)

    if n1 != 1 or n2 != 1 or n3 != 1:
        print(
            f"rutorrent: sendTorrent patch: match failed "
            f"(torrent={n1}, magnet={n2}, mkdir={n3}) in {path}",
            file=sys.stderr,
        )
        return 1
    if text == original:
        print("rutorrent: sendTorrent patch: no change", file=sys.stderr)
        return 1
    path.write_text(text, encoding="utf-8")
    print(f"rutorrent: patched php/rtorrent.php ({MARKER})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_root", type=Path, help="ruTorrent app root")
    return patch(parser.parse_args().app_root)


if __name__ == "__main__":
    sys.exit(main())
