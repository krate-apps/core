#!/bin/sh
# rtorrent@ runtime: dedicated tmux server plus a supervisor.
# Type=notify stays active only while this process is running and the SCGI
# socket exists. RemainAfterExit used to report "active" after rtorrent exited.
#
# Use a private tmux socket under /run/krate/user (not the per-user default
# under /tmp/tmux-<uid>). Otherwise new-session attaches to an existing login
# tmux server that still has the user's primary gid, cannot write the SCGI
# socket into root:krate 2770, and exits before bind.
set -eu

user="${1:?usage: rtorrent-run.sh USER}"
session="rtorrent-${user}"
rt_dir="/run/krate/user"
sock="${rt_dir}/${user}.rtorrent.sock"
tmux_sock="${rt_dir}/${user}.rtorrent.tmux"
bin="/home/${user}/.krate/active/rtorrent/usr/bin/rtorrent"
rc="/home/${user}/.config/rtorrent/.rtorrent.rc"
log="/home/${user}/medias/rtorrent/logs/rtorrent.log"
stopping=0

tmux_cmd() {
	/usr/bin/tmux -S "${tmux_sock}" -f /dev/null "$@"
}

stop() {
	stopping=1
	tmux_cmd kill-session -t "${session}" 2>/dev/null || true
	exit 0
}
trap stop INT TERM

dump_failure() {
	echo "rtorrent-run: ${1}" >&2
	echo "rtorrent-run: id=$(id 2>/dev/null || true)" >&2
	if [ -f "${rc}" ]; then
		echo "rtorrent-run: rc $(stat -c 'owner=%U:%G mode=%a' "${rc}" 2>/dev/null || ls -la "${rc}")" >&2
		if [ ! -r "${rc}" ]; then
			echo "rtorrent-run: rc not readable by $(id -un 2>/dev/null || echo '?') — cannot import" >&2
		fi
	else
		echo "rtorrent-run: rc missing at ${rc}" >&2
	fi
	if [ -f "${log}" ]; then
		echo "rtorrent-run: --- ${log} (tail) ---" >&2
		tail -n 40 "${log}" >&2 || true
	else
		echo "rtorrent-run: log missing at ${log}" >&2
		ls -la "$(dirname "${log}")" >&2 2>/dev/null || true
	fi
	if tmux_cmd has-session -t "${session}" 2>/dev/null; then
		echo "rtorrent-run: --- tmux pane ---" >&2
		tmux_cmd capture-pane -pt "${session}" -S -50 >&2 2>/dev/null || true
	fi
	ls -la "${rt_dir}" >&2 2>/dev/null || true
	ls -la "${rc}" "${bin}" >&2 2>/dev/null || true
}

# Fail fast with a clear message if systemd did not put us in group krate.
if ! touch "${rt_dir}/.${user}.writetest" 2>/dev/null; then
	echo "rtorrent-run: cannot write ${rt_dir} (need gid krate); id=$(id)" >&2
	ls -la "${rt_dir}" >&2 2>/dev/null || true
	exit 1
fi
rm -f "${rt_dir}/.${user}.writetest"

if [ ! -r "${rc}" ]; then
	dump_failure "rc not readable: ${rc}"
	exit 1
fi

tmux_cmd new-session -d -s "${session}" -- \
	"${bin}" -n -o "import=${rc}"

i=0
while [ "${i}" -lt 30 ]; do
	if [ -S "${sock}" ]; then
		break
	fi
	if ! tmux_cmd has-session -t "${session}" 2>/dev/null; then
		dump_failure "session ${session} exited before SCGI socket ${sock}"
		exit 1
	fi
	i=$((i + 1))
	sleep 1
done

if [ ! -S "${sock}" ]; then
	dump_failure "SCGI socket missing at ${sock}"
	tmux_cmd kill-session -t "${session}" 2>/dev/null || true
	exit 1
fi

if [ -n "${NOTIFY_SOCKET:-}" ] && [ -x /usr/bin/systemd-notify ]; then
	/usr/bin/systemd-notify --ready
fi

while tmux_cmd has-session -t "${session}" 2>/dev/null; do
	sleep 2
done

[ "${stopping}" -eq 1 ] && exit 0
dump_failure "session ${session} ended"
exit 1
