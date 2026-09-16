#!/usr/bin/env bash
# Move completed files from ~/mounts/cache to the configured remote (QuickBox-style).
# Flags come from profile.env (RCLONE_MOVE_FLAGS); provider-specific opts stay out of generic mounts.
# Hard exclusion: at most one move session per user (all remotes share this lock).
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rclone-cloud-lib.sh"
# shellcheck source=rclone-cloud-lib.sh
source "${LIB}"
rclone_cloud::parse_instance "${1:?instance}"
rclone_cloud::load_profile
# Backend flags live on the primary mount env (provider-specific).
if [[ -f "${RCLONE_STATE_DIR}/mounts/main.env" ]]; then
	# shellcheck source=/dev/null
	set -a && source "${RCLONE_STATE_DIR}/mounts/main.env" && set +a
fi

if [[ "${RCLONE_MOVE_ENABLED:-1}" != "1" ]]; then
	exit 0
fi

dest="${RCLONE_MOVE_DEST:-}"
if [[ -z "${dest}" ]]; then
	echo "RCLONE_MOVE_DEST unset in ${RCLONE_PROFILE}" >&2
	exit 0
fi

install -d -m 0755 -o "${RCLONE_USER}" -g "${RCLONE_USER}" "${RCLONE_STATE_DIR}" "${RCLONE_LOG_DIR}"
lock="${RCLONE_STATE_DIR}/move.lock"
log="${RCLONE_LOG_DIR}/move.log"

# Non-blocking: if a move is already running for this user, skip (no parallel upload sessions).
exec 9>"${lock}"
if ! flock -n 9; then
	printf '%s rclone move already in progress for %s — skipping overlapping run\n' \
		"$(date -Is)" "${RCLONE_USER}" >>"${log}"
	exit 0
fi

bin="$(rclone_cloud::rclone_bin)"
ua="${RCLONE_USER_AGENT:-krate-rclone}"
min_age="${RCLONE_MOVE_MIN_AGE:-30m}"
bwlimit="${RCLONE_MOVE_BWLIMIT:-}"

provider="${RCLONE_PROVIDER:-import}"
move_flags="${RCLONE_MOVE_FLAGS:-}"
if [[ -z "${move_flags}" ]]; then
	move_flags="$(rclone_cloud::default_move_flags "${provider}")"
fi

args=(
	move "${RCLONE_CACHE}/" "${dest}"
	--config="${RCLONE_CONF}"
	--min-age "${min_age}"
	--log-file "${log}"
	--log-level INFO
	--user-agent "${ua}"
)
rclone_cloud::append_shlex args "${move_flags}"
rclone_cloud::append_shlex args "${RCLONE_BACKEND_FLAGS:-}"
if [[ -n "${bwlimit}" ]]; then
	args+=(--bwlimit "${bwlimit}")
fi

rclone_cloud::run_as_user "${bin}" "${args[@]}"
