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

dump_failure() {
	echo "rtorrent-run: ${1}" >&2
	if [ -f "${log}" ]; then
		echo "rtorrent-run: --- ${log} (tail) ---" >&2
		tail -n 40 "${log}" >&2 || true
	else
		echo "rtorrent-run: log missing at ${log}" >&2
		ls -la "$(dirname "${log}")" >&2 2>/dev/null || true
	fi
	if /usr/bin/tmux has-session -t "${session}" 2>/dev/null; then
		echo "rtorrent-run: --- tmux pane ---" >&2
		/usr/bin/tmux capture-pane -pt "${session}" -S -50 >&2 2>/dev/null || true
	fi
	ls -la "$(dirname "${sock}")" >&2 2>/dev/null || true
	ls -la "${rc}" "${bin}" >&2 2>/dev/null || true
}

/usr/bin/tmux -f /dev/null new-session -d -s "${session}" -- \
	"${bin}" -n -o "import=${rc}"

i=0
while [ "${i}" -lt 30 ]; do
	if [ -S "${sock}" ]; then
		break
	fi
	if ! /usr/bin/tmux has-session -t "${session}" 2>/dev/null; then
		dump_failure "session ${session} exited before SCGI socket ${sock}"
		exit 1
	fi
	i=$((i + 1))
	sleep 1
done

if [ ! -S "${sock}" ]; then
	dump_failure "SCGI socket missing at ${sock}"
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
dump_failure "session ${session} ended"
exit 1
