#!/bin/sh
# rtorrent@ runtime: tmux session plus a supervisor.
# Type=notify stays active only while this process is running and the SCGI
# socket exists. RemainAfterExit used to report "active" after rtorrent exited.
set -eu

user="${1:?usage: rtorrent-run.sh USER}"
session="rtorrent-${user}"
sock="/run/krate/user/${user}.rtorrent.sock"
bin="/home/${user}/.krate/active/rtorrent/usr/bin/rtorrent"
rc="/home/${user}/.config/rtorrent/.rtorrent.rc"
log="/home/${user}/medias/rtorrent/logs/rtorrent.log"
stopping=0

stop() {
	stopping=1
	/usr/bin/tmux kill-session -t "${session}" 2>/dev/null || true
	exit 0
}
trap stop INT TERM

/usr/bin/tmux -f /dev/null new-session -d -s "${session}" -- \
	"${bin}" -n -o "import=${rc}"

i=0
while [ "${i}" -lt 30 ]; do
	if [ -S "${sock}" ]; then
		break
	fi
	if ! /usr/bin/tmux has-session -t "${session}" 2>/dev/null; then
		echo "rtorrent-run: session ${session} exited before SCGI socket ${sock}" >&2
		[ -f "${log}" ] && tail -n 40 "${log}" >&2 || true
		exit 1
	fi
	i=$((i + 1))
	sleep 1
done

if [ ! -S "${sock}" ]; then
	echo "rtorrent-run: SCGI socket missing at ${sock}" >&2
	[ -f "${log}" ] && tail -n 40 "${log}" >&2 || true
	/usr/bin/tmux kill-session -t "${session}" 2>/dev/null || true
	exit 1
fi

if [ -n "${NOTIFY_SOCKET:-}" ] && [ -x /usr/bin/systemd-notify ]; then
	/usr/bin/systemd-notify --ready
fi

while /usr/bin/tmux has-session -t "${session}" 2>/dev/null; do
	sleep 2
done

[ "${stopping}" -eq 1 ] && exit 0
echo "rtorrent-run: session ${session} ended" >&2
[ -f "${log}" ] && tail -n 40 "${log}" >&2 || true
exit 1
