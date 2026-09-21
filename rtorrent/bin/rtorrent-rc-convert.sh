#!/usr/bin/env bash
# Convert / lint a user's .rtorrent.rc for a target binary slot (no service start).
# Usage:
#   rtorrent-rc-convert.sh <username> [<slot>] [--dry-run]
# Examples:
#   rtorrent-rc-convert.sh alice 0.16.23 --dry-run
#   rtorrent-rc-convert.sh alice 0.15.7
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/rc.sh
. "${APP_DIR}/lib/rc.sh"

usage() {
	cat <<'EOF' >&2
Usage: rtorrent-rc-convert.sh <username> [<slot>] [--dry-run]

  Convert ~/.config/rtorrent/.rtorrent.rc to the dialect of <slot>
  (modern ≥ 0.16.14, legacy otherwise). Does not start/stop the service.

  If <slot> is omitted, uses the version linked at ~/.krate/active/rtorrent.
  --dry-run prints a unified diff and leaves the file unchanged.
EOF
	exit 2
}

username=""
target_slot=""
dry_run=0
for arg in "$@"; do
	case "${arg}" in
	--dry-run) dry_run=1 ;;
	-h | --help) usage ;;
	*)
		if [[ -z "${username}" ]]; then
			username="${arg}"
		elif [[ -z "${target_slot}" ]]; then
			target_slot="${arg}"
		else
			usage
		fi
		;;
	esac
done
[[ -n "${username}" ]] || usage

rc_path="/home/${username}/.config/rtorrent/.rtorrent.rc"
[[ -f "${rc_path}" ]] || {
	echo "rtorrent-rc-convert: missing ${rc_path}" >&2
	exit 1
}

if [[ -z "${target_slot}" ]]; then
	link="$(readlink -f "/home/${username}/.krate/active/rtorrent" 2>/dev/null || true)"
	if [[ "${link}" =~ rtorrent_([0-9][^/]*) ]]; then
		target_slot="${BASH_REMATCH[1]}"
	fi
fi
[[ -n "${target_slot}" ]] || {
	echo "rtorrent-rc-convert: unable to resolve slot (pass explicitly)" >&2
	exit 1
}

port_range=""
# Best-effort: read peer range from existing rc if present (dry-run/apply keep it unless sync later).
port_range="$(sed -nE 's/^[[:space:]]*network\.(listen\.)?port\.range\.set[[:space:]]*=[[:space:]]*//p' "${rc_path}" | head -n1 || true)"

from_hint="existing"
if _rc_is_modern "${target_slot}"; then
	direction="forward"
else
	direction="reverse"
fi

if [[ "${dry_run}" -eq 1 ]]; then
	echo "rtorrent-rc-convert: dry-run ${direction} → ${target_slot} (${rc_path})" >&2
	_rc_patch_dry_run "${rc_path}" "${target_slot}" "${port_range}"
	exit 0
fi

bak_dir="$(dirname "${rc_path}")"
bak="${bak_dir}/.rtorrent.rc.${from_hint}.bak"
if [[ -e "${bak}" ]]; then
	bak="${bak_dir}/.rtorrent.rc.${from_hint}.$(date -u +%Y%m%dT%H%M%SZ).bak"
fi
cp -a "${rc_path}" "${bak}"
_rc_patch "${rc_path}" "${target_slot}"
[[ -n "${port_range}" ]] && _rc_sync_port_range "${rc_path}" "${port_range}"
chown "${username}:${username}" "${rc_path}" "${bak}" 2>/dev/null || true
echo "rtorrent-rc-convert: applied ${direction} for ${target_slot}; backup ${bak}" >&2
