#!/usr/bin/env python3
"""Make ruTorrent ratio groups work on rTorrent 0.15.x and 0.16.x.

Novik's getRatioGroupCommand used to pick group2.* for iVersion >= 0x904.
Those aliases are stubbed on 0.15.x and removed on 0.16.x. Upstream now
always uses group.* and adapts the .set argument shape by version
(bare value on 0.15, (target, value) on 0.16+). Apply that fix after
each Novik sync so a stale tip cannot break ratio groups again.

Idempotent: exits 0 with no writes when already patched.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Optional

FIXED_HELPER = '''\
\tpublic function getRatioGroupCommand($ratio,$cmd,$args)
\t{
\t\t// KRATE: always use canonical group.* (legacy aliases are stubbed on 0.15 / gone on 0.16).
\t\t// 0.16+ .set needs (target, value); 0.15.x needs the bare value.
\t\tif(($this->iVersion >= 0x1000) && (substr($cmd, -4) === ".set"))
\t\t{
\t\t\tif(!is_array($args)) $args = array($args);
\t\t\tarray_unshift($args, "");
\t\t}
\t\treturn( new rXMLRPCCommand( "group.".$ratio.".".$cmd, $args ) );
\t}
'''

RATIO_CMDS_BLOCK = re.compile(
    r"\n\tprivate \$ratioCmds = array\s*\([\s\S]*?\);\s*\n",
    re.MULTILINE,
)

HELPER_RE = re.compile(
    r"\tpublic function getRatioGroupCommand\(\$ratio,\$cmd,\$args\)\s*\{[\s\S]*?\n\t\}",
    re.MULTILINE,
)

# Intermediate upstream shape that always prepends ("", value) in ratio.php.
RATIO_SET_CALLS = (
    (
        re.compile(
            r"getRatioGroupCommand\(\"rat_\"\.\$i,'ratio\.min\.set',array\(\"\",\$rat\[\"min\"\]\)\)"
        ),
        'getRatioGroupCommand("rat_".$i,\'ratio.min.set\',$rat["min"])',
    ),
    (
        re.compile(
            r"getRatioGroupCommand\(\"rat_\"\.\$i,'ratio\.max\.set',array\(\"\",\$rat\[\"max\"\]\)\)"
        ),
        'getRatioGroupCommand("rat_".$i,\'ratio.max.set\',$rat["max"])',
    ),
    (
        re.compile(
            r"getRatioGroupCommand\(\"rat_\"\.\$i,'ratio\.upload\.set',array\(\"\",floatval\(\$rat\[\"upload\"\]\*1024\*1024\*1024\)\)\)"
        ),
        'getRatioGroupCommand("rat_".$i,\'ratio.upload.set\',floatval($rat["upload"]*1024*1024*1024))',
    ),
)


def _already_fixed(settings: str) -> bool:
    match = HELPER_RE.search(settings)
    if not match:
        return False
    body = match.group(0)
    return (
        'array_unshift($args, "")' in body
        and 'rXMLRPCCommand( "group.".$ratio.".".$cmd, $args )' in body
        and "$prefix" not in body
        and 'group2."' not in body
    )


def patch_settings(path: Path) -> Optional[bool]:
    """Return True if changed, False if already ok, None on hard failure."""
    text = path.read_text(encoding="utf-8")
    if "function getRatioGroupCommand" not in text:
        print(f"rutorrent: ratio patch: getRatioGroupCommand not found in {path}", file=sys.stderr)
        return None
    if _already_fixed(text):
        return False
    new = RATIO_CMDS_BLOCK.sub("\n", text, count=1)
    if not HELPER_RE.search(new):
        print(f"rutorrent: ratio patch: could not locate helper body in {path}", file=sys.stderr)
        return None
    new = HELPER_RE.sub(FIXED_HELPER.rstrip("\n"), new, count=1)
    if new == text:
        return False
    path.write_text(new, encoding="utf-8")
    return True


def patch_ratio_php(path: Path) -> bool:
    if not path.is_file():
        return False
    text = path.read_text(encoding="utf-8")
    new = text
    for pattern, repl in RATIO_SET_CALLS:
        new = pattern.sub(repl, new)
    if new == text:
        return False
    path.write_text(new, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_root", type=Path, help="ruTorrent app root (contains php/ and plugins/)")
    args = parser.parse_args()
    settings = args.app_root / "php" / "settings.php"
    ratio = args.app_root / "plugins" / "ratio" / "ratio.php"
    if not settings.is_file():
        print(f"rutorrent: ratio patch: missing {settings}", file=sys.stderr)
        return 1
    result = patch_settings(settings)
    if result is None:
        return 1
    changed = bool(result)
    if result:
        print("rutorrent: patched php/settings.php getRatioGroupCommand for 0.15.x/0.16.x")
    if patch_ratio_php(ratio):
        print("rutorrent: patched plugins/ratio/ratio.php .set call shape")
        changed = True
    if not changed:
        print("rutorrent: ratio groups already compatible (no patch needed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
