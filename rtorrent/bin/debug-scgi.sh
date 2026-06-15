#!/usr/bin/env bash
# Read-only SCGI diagnostics (permissions live in tmpfiles + rtorrent@.service manifest).
# Usage: debug-scgi.sh <username>
set -euo pipefail

username="${1:-}"
if [[ -z "${username}" ]]; then
	echo "usage: $0 <username>" >&2
	exit 1
fi

rt_rc="/home/${username}/.config/rtorrent/.rtorrent.rc"
scgi_sock="/run/krate/user/${username}.rtorrent.sock"
tmux_session="rtorrent-${username}"

printf '=== paths ===\nconfig: %s\nsocket: %s\n' "${rt_rc}" "${scgi_sock}"

printf '\n=== groups ===\n'
id www-data 2>/dev/null || true
id "${username}" 2>/dev/null || true

printf '\n=== run dir (expect root:krate 2770) ===\n'
ls -ld /run/krate/user 2>/dev/null || echo 'missing'
sudo -u "${username}" test -w /run/krate/user 2>/dev/null && echo "write as ${username} (default gid): OK" || echo "write as ${username} (default gid): FAIL"
sudo -u "${username}" -g krate test -w /run/krate/user 2>/dev/null && echo 'write as user with gid krate: OK' || echo 'write as user with gid krate: FAIL'

printf '\n=== socket (expect %s:krate 660) ===\n' "${username}"
if [[ -S "${scgi_sock}" ]]; then
	ls -la "${scgi_sock}"
	stat -c 'owner=%U group=%G mode=%a' "${scgi_sock}"
	sudo -u www-data test -r "${scgi_sock}" && echo 'www-data read: OK' || echo 'www-data read: FAIL'
else
	echo 'missing (rtorrent not bound SCGI or no write access to run dir)'
fi

printf '\n=== tmux (as %s) ===\n' "${username}"
sudo -u "${username}" tmux has-session -t "${tmux_session}" 2>/dev/null && echo active || echo missing

printf '\n=== rtorrent binary (must not be setuid) ===\n'
namei -l "/home/${username}/.krate/active/rtorrent/usr/bin/rtorrent" 2>/dev/null || true

printf '\n=== service unit ===\n'
systemctl is-active "rtorrent@${username}.service" 2>/dev/null || true
systemctl cat "rtorrent@${username}.service" 2>/dev/null | grep -E '^User=|^Group=|^UMask=|^ExecStart=' || true

printf '\n=== rtorrent rc (scgi + daemon) ===\n'
grep -E 'scgi|daemon\.set' "${rt_rc}" 2>/dev/null || echo "missing ${rt_rc}"

printf '\n=== process ===\n'
pgrep -u "${username}" -a rtorrent 2>/dev/null || echo 'no rtorrent process'
pid="$(pgrep -u "${username}" -x rtorrent 2>/dev/null | head -n1 || true)"
if [[ -n "${pid}" ]]; then
	ps -o user=,group=,egid=,cmd= -p "${pid}" 2>/dev/null || true
fi

printf '\n=== journal (last start) ===\n'
journalctl -u "rtorrent@${username}.service" -n 15 --no-pager 2>/dev/null || true

printf '\n=== log tail ===\n'
tail -20 "/home/${username}/download-clients/rtorrent/logs/rtorrent.log" 2>/dev/null || true
