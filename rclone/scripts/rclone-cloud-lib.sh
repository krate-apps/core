#!/usr/bin/env bash
# Shared helpers for rclone cloud mount / mergerfs / move stack.
# shellcheck disable=SC2034
set -euo pipefail

# Instance: USERNAME or USERNAME--BRANCH
rclone_cloud::parse_instance() {
	local instance="${1:?}"
	if [[ "${instance}" == *--* ]]; then
		RCLONE_USER="${instance%%--*}"
		RCLONE_BRANCH="${instance#*--}"
	else
		RCLONE_USER="${instance}"
		RCLONE_BRANCH="main"
	fi
	RCLONE_HOME="/home/${RCLONE_USER}"
	RCLONE_CONF="${RCLONE_HOME}/.config/rclone/rclone.conf"
	RCLONE_STATE_DIR="${RCLONE_HOME}/.krate/applications/rclone-cloud"
	RCLONE_MOUNT_ENV="${RCLONE_STATE_DIR}/mounts/${RCLONE_BRANCH}.env"
	RCLONE_PROFILE="${RCLONE_STATE_DIR}/profile.env"
	RCLONE_LOG_DIR="${RCLONE_HOME}/.krate/logs/rclone"
	RCLONE_CACHE="${RCLONE_HOME}/mounts/cache"
	RCLONE_MEDIA="${RCLONE_HOME}/mounts/media"
	RCLONE_UNION="${RCLONE_HOME}/mounts/union"
	if [[ "${RCLONE_BRANCH}" == "main" ]]; then
		RCLONE_REMOTE_MOUNT="${RCLONE_HOME}/mounts/remote"
	else
		RCLONE_REMOTE_MOUNT="${RCLONE_HOME}/mounts/remotes/${RCLONE_BRANCH}"
	fi
}

rclone_cloud::load_profile() {
	[[ -f "${RCLONE_PROFILE}" ]] || return 0
	# shellcheck disable=SC1090
	set -a
	# shellcheck source=/dev/null
	source "${RCLONE_PROFILE}"
	set +a
}

rclone_cloud::load_mount_env() {
	[[ -f "${RCLONE_MOUNT_ENV}" ]] || {
		echo "missing mount env: ${RCLONE_MOUNT_ENV}" >&2
		return 1
	}
	# shellcheck disable=SC1090
	set -a
	# shellcheck source=/dev/null
	source "${RCLONE_MOUNT_ENV}"
	set +a
	: "${RCLONE_REMOTE_SPEC:?RCLONE_REMOTE_SPEC required in ${RCLONE_MOUNT_ENV}}"
}

rclone_cloud::rclone_bin() {
	local u="${RCLONE_USER:-}"
	if [[ -n "${u}" && -x "/opt/${u}/rclone/rclone" ]]; then
		printf '%s\n' "/opt/${u}/rclone/rclone"
		return 0
	fi
	command -v rclone
}

rclone_cloud::run_as_user() {
	local u="${RCLONE_USER:?}"
	if [[ "$(id -un)" == "${u}" ]]; then
		"$@"
	else
		runuser -u "${u}" -- "$@"
	fi
}

rclone_cloud::ensure_dirs() {
	install -d -m 0755 -o "${RCLONE_USER}" -g "${RCLONE_USER}" \
		"${RCLONE_HOME}/mounts" \
		"${RCLONE_HOME}/mounts/remotes" \
		"${RCLONE_HOME}/mounts/views" \
		"${RCLONE_HOME}/.cache/rclone" \
		"${RCLONE_CACHE}" \
		"${RCLONE_MEDIA}" \
		"${RCLONE_UNION}" \
		"${RCLONE_REMOTE_MOUNT}" \
		"${RCLONE_STATE_DIR}" \
		"${RCLONE_STATE_DIR}/mounts" \
		"${RCLONE_STATE_DIR}/views" \
		"${RCLONE_LOG_DIR}"
}

# Append shell-quoted flag string into a nameref array (safe tokenization).
rclone_cloud::append_shlex() {
	local -n _rclone_flag_arr="${1:?}"
	local flags="${2:-}"
	[[ -z "${flags}" ]] && return 0
	local -a parts=()
	mapfile -d '' -t parts < <(python3 -c 'import shlex,sys; print("\0".join(shlex.split(sys.argv[1])), end="")' "${flags}" || true)
	local p
	for p in "${parts[@]+"${parts[@]}"}"; do
		[[ -n "${p}" ]] && _rclone_flag_arr+=("${p}")
	done
}

# Provider → rclone backend type (kdrive is WebDAV against Infomaniak).
rclone_cloud::provider_backend() {
	case "${1:-}" in
	kdrive) echo webdav ;;
	drive | dropbox | s3 | webdav | onedrive | crypt) echo "${1}" ;;
	*) echo "${1}" ;;
	esac
}

# Generic FUSE/mount flags (not backend-specific). Written into mounts/*.env.
rclone_cloud::default_mount_flags() {
	local provider="${1:-import}"
	local cache_dir="${RCLONE_HOME:-/tmp}/.cache/rclone"
	case "${provider}" in
	kdrive | webdav | crypt)
		# Infomaniak / crypt-over-webdav profile (no --daemon: systemd owns the process).
		printf '%s\n' "--allow-other --dir-cache-time 1h --umask 002 --timeout 1h --vfs-cache-mode full --vfs-cache-max-age 24h --vfs-cache-max-size 10G --cache-dir ${cache_dir}"
		;;
	drive)
		printf '%s\n' '--allow-other --dir-cache-time 72h --umask 002 --timeout 1h --tpslimit 12 --tpslimit-burst 0'
		;;
	*)
		printf '%s\n' '--allow-other --dir-cache-time 72h --umask 002 --timeout 1h --tpslimit 12 --tpslimit-burst 0'
		;;
	esac
}

# Backend-only flags (Google Drive, etc.). Empty for providers that have none.
rclone_cloud::default_backend_flags() {
	local provider="${1:-import}"
	case "${provider}" in
	drive)
		# Intentionally empty by default — add e.g. --drive-chunk-size 64M in mounts/*.env if needed.
		printf '%s\n' ''
		;;
	*)
		printf '%s\n' ''
		;;
	esac
}

# Move/copy pipeline flags (profile.env). Keep Google tpslimit out of kDrive/webdav.
rclone_cloud::default_move_flags() {
	local provider="${1:-import}"
	case "${provider}" in
	kdrive | webdav | crypt)
		printf '%s\n' '--fast-list --retries 3 --low-level-retries 10 --checkers 4 --transfers 2 --delete-empty-src-dirs'
		;;
	drive)
		printf '%s\n' '--fast-list --retries 3 --low-level-retries 10 --tpslimit 12 --tpslimit-burst 12 --checkers 8 --transfers 4 --delete-empty-src-dirs'
		;;
	*)
		printf '%s\n' '--fast-list --retries 3 --low-level-retries 10 --tpslimit 12 --tpslimit-burst 12 --checkers 8 --transfers 4 --delete-empty-src-dirs'
		;;
	esac
}

# Write mounts/<branch>.env with provider-aware flag presets (preserves custom flags if set in env).
rclone_cloud::write_mount_env() {
	local path="${1:?}"
	local remote_spec="${2:?}"
	local provider="${3:-import}"
	local extra_lines="${4:-}" # optional extra KEY=val lines
	local mount_flags="${RCLONE_MOUNT_FLAGS:-}"
	local backend_flags="${RCLONE_BACKEND_FLAGS-}"
	if [[ -z "${mount_flags}" ]]; then
		mount_flags="$(rclone_cloud::default_mount_flags "${provider}")"
	fi
	if [[ -z "${backend_flags}" ]]; then
		backend_flags="$(rclone_cloud::default_backend_flags "${provider}")"
	fi
	{
		printf 'RCLONE_REMOTE_SPEC=%s\n' "${remote_spec}"
		printf 'RCLONE_PROVIDER=%s\n' "${provider}"
		printf "RCLONE_MOUNT_FLAGS='%s'\n" "${mount_flags}"
		printf "RCLONE_BACKEND_FLAGS='%s'\n" "${backend_flags}"
		if [[ -n "${extra_lines}" ]]; then
			printf '%s\n' "${extra_lines}"
		fi
	} >"${path}"
}
