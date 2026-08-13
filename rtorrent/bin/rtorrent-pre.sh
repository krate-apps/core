#!/bin/sh

# rtorrent pre (sh)
#
# Usage:
#   rtorrent-pre.sh [args]

# rtorrent@ pre-start (systemd runs this as root via ExecStartPre=+).
set -eu

user="${1:?usage: rtorrent-pre.sh USER}"
rt_dir="/run/krate/user"
tmpfiles="/usr/lib/tmpfiles.d/krate-run.conf"

if [ -f "${tmpfiles}" ]; then
	systemd-tmpfiles --create "${tmpfiles}"
fi

install -d -m 2770 -o root -g krate "${rt_dir}"
chown root:krate "${rt_dir}"
chmod 2770 "${rt_dir}"

actual="$(stat -c '%U:%G %a' "${rt_dir}")"
if [ "${actual}" != "root:krate 2770" ]; then
	echo "rtorrent-pre: ${rt_dir} must be root:krate 2770, got ${actual}" >&2
	exit 1
fi

/usr/bin/tmux kill-session -t "rtorrent-${user}" 2>/dev/null || true
pkill -u "${user}" -x rtorrent 2>/dev/null || true
rm -f \
	"/home/${user}/download-clients/rtorrent/.sessions/rtorrent.lock" \
	"${rt_dir}/${user}.rtorrent.sock"
