#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2154,SC1091
# Unified systemd hooks for rclone cloud stack.
# Usage: rclone-unit.sh <mount|media|union> <pre|start|stop> <instance>
set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rclone-cloud-lib.sh"
# shellcheck source=rclone-cloud-lib.sh
source "${LIB}"

ROLE="${1:?role (mount|media|union)}"
ACTION="${2:?action (pre|start|stop)}"
INSTANCE="${3:?instance}"

rclone_cloud::parse_instance "${INSTANCE}"

rclone_unit::fusermount_uz() {
	local target="${1:?}"
	if mountpoint -q "${target}" 2>/dev/null; then
		fusermount3 -uz "${target}" 2>/dev/null || fusermount -uz "${target}" 2>/dev/null || true
	fi
}

rclone_unit::remote_name_from_spec() {
	local spec="${1:?}"
	# Media: / Media:Movies / Media → Media
	spec="${spec%%:*}"
	printf '%s\n' "${spec}"
}

# True when the remote section has usable credentials.
# Covers OAuth, SA, S3 keys, WebDAV url, crypt passwords, and alias→remote.
rclone_unit::remote_has_auth() {
	local conf="${1:?}" remote="${2:?}"
	awk -v r="${remote}" '
		$0 == "[" r "]" { s = 1; next }
		/^\[/ { s = 0 }
		s && /^(token|service_account_file|service_account_credentials|access_key_id|url|password|password2|remote)[[:space:]]*=/ {
			found = 1
		}
		END { exit found ? 0 : 1 }
	' "${conf}"
}

# Fail fast with a journal-visible reason (auth / missing remote / FUSE).
rclone_unit::mount_preflight() {
	local remote bin
	remote="$(rclone_unit::remote_name_from_spec "${RCLONE_REMOTE_SPEC}")"
	if [[ -z "${remote}" ]]; then
		echo "rclone mount: empty remote name in RCLONE_REMOTE_SPEC=${RCLONE_REMOTE_SPEC}" >&2
		exit 1
	fi
	if [[ ! -f "${RCLONE_CONF}" ]]; then
		echo "rclone mount: missing config ${RCLONE_CONF}" >&2
		exit 1
	fi
	if ! grep -qE "^\[${remote}\]$" "${RCLONE_CONF}" 2>/dev/null; then
		echo "rclone mount: remote [${remote}] not found in ${RCLONE_CONF}" >&2
		echo "  Fix: zen rclone import-conf ${RCLONE_USER} …  or  zen rclone oauth-begin ${RCLONE_USER} --remote ${remote}" >&2
		exit 1
	fi
	if ! rclone_unit::remote_has_auth "${RCLONE_CONF}" "${remote}"; then
		echo "rclone mount: remote [${remote}] has no credentials yet (token / password / url / keys)" >&2
		echo "  Fix: import a ready conf, or oauth-complete / remote-create for this remote" >&2
		exit 1
	fi
	if grep -qE -- '--allow-other' <<<"${RCLONE_MOUNT_FLAGS:- --allow-other}" &&
		[[ -f /etc/fuse.conf ]] && ! grep -qE '^[[:space:]]*user_allow_other' /etc/fuse.conf; then
		echo "rclone mount: --allow-other requires 'user_allow_other' in /etc/fuse.conf" >&2
		exit 1
	fi
	bin="$(rclone_cloud::rclone_bin)"
	if [[ ! -x "${bin}" ]]; then
		echo "rclone mount: binary not executable: ${bin}" >&2
		exit 1
	fi
}

rclone_unit::mount_pre() {
	rclone_cloud::ensure_dirs
	rclone_cloud::load_mount_env
	rclone_unit::mount_preflight
}

rclone_unit::mount_start() {
	rclone_cloud::load_mount_env
	rclone_cloud::load_profile
	rclone_unit::mount_preflight
	local bin ua
	bin="$(rclone_cloud::rclone_bin)"
	ua="${RCLONE_USER_AGENT:-krate-rclone}"
	# Log to stderr so journalctl -u rclone-mount@user shows failures (no silent --log-file).
	local -a args=(
		mount "${RCLONE_REMOTE_SPEC}" "${RCLONE_REMOTE_MOUNT}"
		--config="${RCLONE_CONF}"
		--log-level INFO
		--user-agent "${ua}"
	)
	if [[ -n "${RCLONE_MOUNT_FLAGS:-}" ]]; then
		rclone_cloud::append_shlex args "${RCLONE_MOUNT_FLAGS}"
	else
		# Legacy mounts/*.env without RCLONE_MOUNT_FLAGS
		args+=(
			--allow-other
			--dir-cache-time "${RCLONE_DIR_CACHE_TIME:-72h}"
			--umask 002
			--timeout 1h
			--tpslimit "${RCLONE_TPSLIMIT:-12}"
			--tpslimit-burst 0
		)
	fi
	rclone_cloud::append_shlex args "${RCLONE_BACKEND_FLAGS:-}"
	rclone_cloud::run_as_user "${bin}" "${args[@]}"
}

rclone_unit::mount_stop() {
	rclone_unit::fusermount_uz "${RCLONE_REMOTE_MOUNT}"
}

rclone_unit::media_pre() {
	rclone_cloud::ensure_dirs
	rclone_cloud::load_mount_env 2>/dev/null || true
	if [[ "${RCLONE_VIEW_MODE:-0}" == "1" && "${RCLONE_BRANCH}" != "main" ]]; then
		install -d -m 0755 -o "${RCLONE_USER}" -g "${RCLONE_USER}" \
			"${RCLONE_HOME}/mounts/views" \
			"${RCLONE_HOME}/mounts/views/${RCLONE_BRANCH}" \
			"${RCLONE_HOME}/mounts/cache/${RCLONE_BRANCH}" \
			"${RCLONE_HOME}/mounts/remotes/${RCLONE_BRANCH}"
	fi
}

rclone_unit::media_start() {
	rclone_cloud::load_profile
	rclone_cloud::load_mount_env 2>/dev/null || true

	local cache_path cloud_path media_path what opts cloud_branch
	# Named media views: cache/<branch> + remotes/<branch> → views/<branch>
	if [[ "${RCLONE_VIEW_MODE:-0}" == "1" && "${RCLONE_BRANCH}" != "main" ]]; then
		cache_path="${RCLONE_HOME}/mounts/cache/${RCLONE_BRANCH}"
		cloud_path="${RCLONE_HOME}/mounts/remotes/${RCLONE_BRANCH}"
		media_path="${RCLONE_HOME}/mounts/views/${RCLONE_BRANCH}"
		install -d -m 0755 -o "${RCLONE_USER}" -g "${RCLONE_USER}" "${cache_path}" "${cloud_path}" "${media_path}"
		what="${cache_path}:${cloud_path}"
		opts="${RCLONE_MERGERFS_OPTS:-async_read=false,use_ino,allow_other,auto_cache,func.getattr=newest,category.action=all,category.create=ff,dropcacheonclose=true}"
		exec mergerfs -o "${opts}" "${what}" "${media_path}"
	fi

	cloud_branch="${RCLONE_MEDIA_CLOUD_BRANCH:-remote}"
	if [[ "${cloud_branch}" == "union" ]]; then
		cloud_path="${RCLONE_UNION}"
	else
		cloud_path="${RCLONE_REMOTE_MOUNT}"
		if [[ "${RCLONE_BRANCH}" == "main" ]]; then
			cloud_path="${RCLONE_HOME}/mounts/remote"
		fi
	fi

	if mountpoint -q "${RCLONE_UNION}" 2>/dev/null; then
		cloud_path="${RCLONE_UNION}"
	fi

	what="${RCLONE_CACHE}:${cloud_path}"
	opts="${RCLONE_MERGERFS_OPTS:-async_read=false,use_ino,allow_other,auto_cache,func.getattr=newest,category.action=all,category.create=ff,dropcacheonclose=true}"
	exec mergerfs -o "${opts}" "${what}" "${RCLONE_MEDIA}"
}

rclone_unit::media_stop() {
	rclone_cloud::load_mount_env 2>/dev/null || true
	local target="${RCLONE_MEDIA}"
	if [[ "${RCLONE_VIEW_MODE:-0}" == "1" && "${RCLONE_BRANCH}" != "main" ]]; then
		target="${RCLONE_HOME}/mounts/views/${RCLONE_BRANCH}"
	fi
	rclone_unit::fusermount_uz "${target}"
}

rclone_unit::union_pre() {
	rclone_cloud::ensure_dirs
	install -d -m 0755 -o "${RCLONE_USER}" -g "${RCLONE_USER}" "${RCLONE_UNION}"
}

rclone_unit::union_start() {
	local branches_file="${RCLONE_STATE_DIR}/union.branches"
	if [[ ! -f "${branches_file}" ]]; then
		echo "missing ${branches_file}" >&2
		exit 1
	fi

	local -a parts=()
	local line
	while IFS= read -r line || [[ -n "${line}" ]]; do
		[[ -z "${line}" || "${line}" =~ ^# ]] && continue
		parts+=("${line}")
	done <"${branches_file}"

	if [[ ${#parts[@]} -lt 2 ]]; then
		echo "union requires at least 2 branches" >&2
		exit 1
	fi

	local what opts
	what="$(IFS=:; echo "${parts[*]}")"
	opts="${RCLONE_MERGERFS_OPTS:-async_read=false,use_ino,allow_other,auto_cache,func.getattr=newest,category.action=all,category.create=ff,dropcacheonclose=true}"
	exec mergerfs -o "${opts}" "${what}" "${RCLONE_UNION}"
}

rclone_unit::union_stop() {
	rclone_unit::fusermount_uz "${RCLONE_UNION}"
}

case "${ROLE}" in
mount | media | union) ;;
*)
	echo "unknown role: ${ROLE} (expected mount|media|union)" >&2
	exit 2
	;;
esac
case "${ACTION}" in
pre | start | stop) ;;
*)
	echo "unknown action: ${ACTION} (expected pre|start|stop)" >&2
	exit 2
	;;
esac

"rclone_unit::${ROLE}_${ACTION}"
