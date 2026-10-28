#!/usr/bin/env python3
"""Treat void XML-RPC success as success in Novik rXMLRPCRequest::run().

rtorrent (tinyxml2) answers load.raw / load.raw_start with an empty
<params></params> body. Novik only sets $ret when <value> tags exist, so
run() returns false, addtorrent.php reports Failed, and the UI shows
"could not be added" even though the torrent is already in the list.

Idempotent: no write when already patched.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

MARKER = "KRATE: void methodResponse"

OLD = """\
\t\t\t\tif($ret)
\t\t\t\t{
\t\t\t\t\tif(strstr($answer,"faultCode")!==false)
\t\t\t\t\t{
\t\t\t\t\t\t$this->fault = true;
\t\t\t\t\t\t$this->faultString = self::parseFaultString($answer);
\t\t\t\t\t\tglobal $rpcLogFaults;
\t\t\t\t\t\tif($rpcLogFaults && $this->important)
\t\t\t\t\t\t{
\t\t\t\t\t\t\tFileUtil::toLog($this->content);
\t\t\t\t\t\t\tFileUtil::toLog($answer);
\t\t\t\t\t\t}
\t\t\t\t\t\tbreak;
\t\t\t\t\t}
\t\t\t\t} else break;
"""

NEW = """\
\t\t\t\tif($ret)
\t\t\t\t{
\t\t\t\t\tif(strstr($answer,"faultCode")!==false)
\t\t\t\t\t{
\t\t\t\t\t\t$this->fault = true;
\t\t\t\t\t\t$this->faultString = self::parseFaultString($answer);
\t\t\t\t\t\tglobal $rpcLogFaults;
\t\t\t\t\t\tif($rpcLogFaults && $this->important)
\t\t\t\t\t\t{
\t\t\t\t\t\t\tFileUtil::toLog($this->content);
\t\t\t\t\t\t\tFileUtil::toLog($answer);
\t\t\t\t\t\t}
\t\t\t\t\t\tbreak;
\t\t\t\t\t}
\t\t\t\t}
\t\t\t\telse if(strstr($answer,"faultCode")!==false)
\t\t\t\t{
\t\t\t\t\t$this->fault = true;
\t\t\t\t\t$this->faultString = self::parseFaultString($answer);
\t\t\t\t\tbreak;
\t\t\t\t}
\t\t\t\telse
\t\t\t\t{
\t\t\t\t\t// KRATE: void methodResponse (no <value>) is success — load.raw*
\t\t\t\t\t// with tinyxml2 returns empty <params></params>; treating that as
\t\t\t\t\t// failure shows "could not be added" while the torrent is listed.
\t\t\t\t\t$ret = true;
\t\t\t\t}
"""


def patch(app_root: Path) -> int:
    path = app_root / "php" / "xmlrpc.php"
    if not path.is_file():
        print(f"rutorrent: xmlrpc void patch: missing {path}", file=sys.stderr)
        return 1
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print("rutorrent: xmlrpc void success already patched")
        return 0
    if OLD not in text:
        print(
            f"rutorrent: xmlrpc void patch: expected run() block not found in {path}",
            file=sys.stderr,
        )
        return 1
    path.write_text(text.replace(OLD, NEW, 1), encoding="utf-8")
    print("rutorrent: patched php/xmlrpc.php void methodResponse as success")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_root", type=Path, help="ruTorrent app root (…/srv/rutorrent/app)")
    args = parser.parse_args()
    return patch(args.app_root)


if __name__ == "__main__":
    sys.exit(main())
