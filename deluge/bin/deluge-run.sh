#!/usr/bin/env bash
# deluge@ ExecStart — supervise deluged + deluge-web in one systemd unit.
# deluge-web stays MainPID (visible in systemctl status); a watchdog restarts
# the unit if deluged exits while the web UI is still running.
set -euo pipefail

user="${1:?usage: deluge-run.sh USER}"

install_dir="/opt/${user}/deluge"
vendor_root="/home/${user}/.krate/active/deluge"
python="${install_dir}/.venv/bin/python"
deluged="${vendor_root}/usr/bin/deluged"
deluge_web="${vendor_root}/usr/bin/deluge-web"

: "${PORT:?PORT is required}"
CONFIG_DIR="${CONFIG_DIR:-/home/${user}/.config/deluge}"

export PYTHONPATH="${PYTHONPATH:-}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export PYTHONWARNINGS="${PYTHONWARNINGS:-ignore::UserWarning}"

deluged_pid=""
watchdog_pid=""

stop_children() {
	local sig="${1:-TERM}"
	if [[ -n "${watchdog_pid}" ]]; then
		kill "-${sig}" "${watchdog_pid}" 2>/dev/null || true
	fi
	if [[ -n "${deluged_pid}" ]]; then
		kill "-${sig}" "${deluged_pid}" 2>/dev/null || true
	fi
}

cleanup() {
	stop_children TERM
	wait 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Drop stale processes from an unclean stop (scoped to this user + config dir).
while read -r _pid; do
	[[ -n "${_pid}" ]] || continue
	kill -TERM "${_pid}" 2>/dev/null || true
done < <(pgrep -u "${user}" -f "${deluged}.*-c ${CONFIG_DIR}" 2>/dev/null || true)
while read -r _pid; do
	[[ -n "${_pid}" ]] || continue
	kill -TERM "${_pid}" 2>/dev/null || true
done < <(pgrep -u "${user}" -f "${deluge_web}.*-c ${CONFIG_DIR}" 2>/dev/null || true)
sleep 1

"${python}" "${deluged}" -d -c "${CONFIG_DIR}" &
deluged_pid=$!

# If deluged dies, stop the unit so systemd restarts both processes.
(
	while kill -0 "${deluged_pid}" 2>/dev/null; do
		sleep 2
	done
	kill -TERM "${PPID}" 2>/dev/null || true
) &
watchdog_pid=$!

wait_sec=0
while [[ ! -f "${CONFIG_DIR}/core.conf" && wait_sec -lt 45 ]]; do
	kill -0 "${deluged_pid}" 2>/dev/null || exit 1
	sleep 1
	wait_sec=$((wait_sec + 1))
done
[[ -f "${CONFIG_DIR}/core.conf" ]] || exit 1

exec "${python}" "${deluge_web}" \
	--do-not-daemonize \
	-c "${CONFIG_DIR}" \
	-p "${PORT}" \
	-i 127.0.0.1
