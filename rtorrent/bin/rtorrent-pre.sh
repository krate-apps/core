#!/bin/sh

# rtorrent@ pre-start (systemd runs this as root via ExecStartPre=+).
set -eu

user="${1:?usage: rtorrent-pre.sh USER}"
rt_dir="/run/krate/user"
tmux_sock="${rt_dir}/${user}.rtorrent.tmux"
tmpfiles="/usr/lib/tmpfiles.d/krate-run.conf"
rc="/home/${user}/.config/rtorrent/.rtorrent.rc"
rc_dir="/home/${user}/.config/rtorrent"

if [ -f "${tmpfiles}" ]; then
	systemd-tmpfiles --create "${tmpfiles}"
fi

install -d -m 2770 -o root -g krate "${rt_dir}"

actual="$(stat -c '%U:%G %a' "${rt_dir}")"
if [ "${actual}" != "root:krate 2770" ]; then
	echo "rtorrent-pre: ${rt_dir} must be root:krate 2770, got ${actual}" >&2
	exit 1
fi

# Template/copy as root can leave .rtorrent.rc root:root 0600 (e.g. umask 077);
# User=%i then cannot import and exits before SCGI. Fix ownership every start.
install -d -m 0750 -o "${user}" -g "${user}" "${rc_dir}"
if [ -f "${rc}" ]; then
	chown "${user}:${user}" "${rc}"
	chmod 644 "${rc}"
else
	echo "rtorrent-pre: missing ${rc}" >&2
	exit 1
fi

# Prefer the dedicated socket; also clear a stale default-server session name.
/usr/bin/tmux -S "${tmux_sock}" -f /dev/null kill-session -t "rtorrent-${user}" 2>/dev/null || true
/usr/bin/tmux kill-session -t "rtorrent-${user}" 2>/dev/null || true
pkill -u "${user}" -x rtorrent 2>/dev/null || true
rm -f \
	"/home/${user}/medias/rtorrent/.sessions/rtorrent.lock" \
	"${rt_dir}/${user}.rtorrent.sock" \
	"${tmux_sock}"
