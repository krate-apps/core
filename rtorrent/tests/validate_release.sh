#!/usr/bin/env bash
# Post-release smoke checklist for rTorrent vendor packages + rc conversion.
# Run after publishing krate-rtorrent_0.16.23-*.deb (does not require a live install).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BINARIES_RT="${BINARIES_RTORRENT_DIR:-/home/thomas/Dev/GitHub/Organizations/Krate/krate-apps/binaries/rtorrent}"

echo "== 1) Unit: rc conversion =="
bash "${SCRIPT_DIR}/test_rc_convert.sh"

echo "== 2) Template has no legacy directives =="
if grep -nE 'encoding\.add|trackers\.use_udp|schedule2|execute2|network\.port_range\.set|network\.http\.max_open' \
	"${APP_DIR}/.rtorrent.rc.tpl"; then
	echo "FAIL: legacy directives in template" >&2
	exit 1
fi
echo "OK: template clean"

echo "== 3) Matrix / workflow pin 0.16.23 (not 0.16.11) =="
python3 "${BINARIES_RT}/matrix.py" | grep -q '0.16.23'
! python3 "${BINARIES_RT}/matrix.py" | grep -q '0.16.11'
grep -q '0.16.23' "${BINARIES_RT}/.github/workflows/build.yaml"
! grep -q '0.16.11' "${BINARIES_RT}/.github/workflows/build.yaml"
echo "OK: CI matrix"

echo "== 4) LimitNOFILE / socket floors =="
grep -q 'LimitNOFILE: "16384"' "${APP_DIR}/manifest.yaml"
grep -q 'files.min_alloc.set = 4096' "${APP_DIR}/.rtorrent.rc.tpl"
echo "OK: LimitNOFILE + files.min_alloc"

echo "== 5) Manual host checklist (print only) =="
cat <<'EOF'
After installing krate-rtorrent_0.16.23 on a Trixie host:
  [ ] dpkg -i krate-rtorrent_0.16.23-1_amd64.deb
  [ ] zen update rtorrent --user <u>   (or install path)
  [ ] systemctl is-active rtorrent@<u>
  [ ] test -S /run/krate/user/<u>.rtorrent.sock
  [ ] ruTorrent loads plugins (SCGI / m_trusted)
  [ ] Flood connects if installed
  [ ] watch/load and watch/start pick up a .torrent
  [ ] ~/.config/rtorrent/.rtorrent.rc has schedule= / listen.port / system.sockets.*
  [ ] Optional: bin/rtorrent-rc-convert.sh <u> 0.16.23 --dry-run
EOF

echo "validate_release.sh: static checks passed."
