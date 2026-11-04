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
	# Root may pass --allow-other without user_allow_other; non-root must not.
	bin="$(rclone_cloud::rclone_bin)"
	if [[ ! -x "${bin}" ]]; then
		echo "rclone mount: binary not executable: ${bin}" >&2
		exit 1
	fi
}

rclone_unit::mount_pre() {
	RCLONE_MIGRATE_NO_RESTART=1 rclone_cloud::migrate_layout "${RCLONE_USER}" 2>/dev/null || true
	rclone_cloud::secure_mounts "${RCLONE_USER}" 2>/dev/null || true
	rclone_cloud::ensure_dirs
	rclone_cloud::load_mount_env
	rclone_unit::mount_preflight
}

rclone_unit::mount_start() {
	rclone_cloud::load_mount_env
	rclone_cloud::load_profile
	# Always /run/krate-rclone/<user>/remote/<branch>
	RCLONE_REMOTE_MOUNT="$(rclone_cloud::remote_mount_path "${RCLONE_USER}" "${RCLONE_BRANCH}")"
	rclone_cloud::ensure_run_root "${RCLONE_USER}"
	install -d -m 0750 -o root -g "${RCLONE_USER}" "${RCLONE_REMOTE_MOUNT}"
	rclone_cloud::link_mount_path "${RCLONE_REMOTE_LINK}" "${RCLONE_REMOTE_MOUNT}" "${RCLONE_USER}"
	rclone_unit::mount_preflight
	local bin ua uid gid
	bin="$(rclone_cloud::rclone_bin)"
	ua="${RCLONE_USER_AGENT:-krate-rclone}"
	uid="$(id -u "${RCLONE_USER}")"
	gid="$(id -g "${RCLONE_USER}")"
	# Mount as root into /run (root can use --allow-other without user_allow_other).
	# rclone still applies the account uid/gid on the visible files.
	local -a args=(
		mount "${RCLONE_REMOTE_SPEC}" "${RCLONE_REMOTE_MOUNT}"
		--config="${RCLONE_CONF}"
		--log-level INFO
		--user-agent "${ua}"
		--uid "${uid}"
		--gid "${gid}"
		--allow-other
		--allow-non-empty
	)
	if [[ -n "${RCLONE_MOUNT_FLAGS:-}" ]]; then
		# Drop a duplicate --allow-other from presets; we always set it as root above.
		local filtered
		filtered="$(python3 -c 'import shlex,sys
parts=[p for p in shlex.split(sys.argv[1]) if p!="--allow-other"]
print(" ".join(shlex.quote(p) for p in parts))' "${RCLONE_MOUNT_FLAGS}")"
		rclone_cloud::append_shlex args "${filtered}"
	else
		args+=(
			--dir-cache-time "${RCLONE_DIR_CACHE_TIME:-72h}"
			--umask 002
			--timeout 1h
			--tpslimit "${RCLONE_TPSLIMIT:-12}"
			--tpslimit-burst 0
		)
	fi
	rclone_cloud::append_shlex args "${RCLONE_BACKEND_FLAGS:-}"
	# Run as root (systemd unit) — do not drop to the account for the mount helper.
	"${bin}" "${args[@]}"
}

rclone_unit::mount_stop() {
	rclone_unit::fusermount_uz "${RCLONE_REMOTE_MOUNT}"
}

rclone_unit::media_pre() {
	RCLONE_MIGRATE_NO_RESTART=1 rclone_cloud::migrate_layout "${RCLONE_USER}" 2>/dev/null || true
	rclone_cloud::secure_mounts "${RCLONE_USER}" 2>/dev/null || true
	rclone_cloud::ensure_dirs
	rclone_cloud::load_mount_env 2>/dev/null || true
	if [[ "${RCLONE_VIEW_MODE:-0}" == "1" && "${RCLONE_BRANCH}" != "main" ]]; then
		local view_run="${RCLONE_RUN_ROOT}/views/${RCLONE_BRANCH}"
		install -d -m 0755 -o "${RCLONE_USER}" -g "${RCLONE_USER}" \
			"${RCLONE_HOME}/mounts/views" \
			"${RCLONE_HOME}/mounts/cache/${RCLONE_BRANCH}"
		install -d -m 0750 -o root -g "${RCLONE_USER}" \
			"${view_run}" \
			"$(rclone_cloud::remote_mount_path "${RCLONE_USER}" "${RCLONE_BRANCH}")"
		rclone_cloud::link_mount_path \
			"${RCLONE_HOME}/mounts/views/${RCLONE_BRANCH}" "${view_run}" "${RCLONE_USER}"
		rclone_cloud::link_mount_path \
			"$(rclone_cloud::remote_link_path "${RCLONE_HOME}" "${RCLONE_BRANCH}")" \
			"$(rclone_cloud::remote_mount_path "${RCLONE_USER}" "${RCLONE_BRANCH}")" \
			"${RCLONE_USER}"
	fi
}

rclone_unit::media_start() {
	rclone_cloud::load_profile
	rclone_cloud::load_mount_env 2>/dev/null || true

	local cache_path cloud_path media_path what opts
	# Named media views: cache/<branch> + remote/<branch> → views/<branch> under /run
	if [[ "${RCLONE_VIEW_MODE:-0}" == "1" && "${RCLONE_BRANCH}" != "main" ]]; then
		cache_path="${RCLONE_HOME}/mounts/cache/${RCLONE_BRANCH}"
		cloud_path="$(rclone_cloud::remote_mount_path "${RCLONE_USER}" "${RCLONE_BRANCH}")"
		media_path="${RCLONE_RUN_ROOT}/views/${RCLONE_BRANCH}"
		install -d -m 0755 -o "${RCLONE_USER}" -g "${RCLONE_USER}" "${cache_path}"
		install -d -m 0750 -o root -g "${RCLONE_USER}" "${cloud_path}" "${media_path}"
		rclone_cloud::link_mount_path \
			"${RCLONE_HOME}/mounts/views/${RCLONE_BRANCH}" "${media_path}" "${RCLONE_USER}"
		what="${cache_path}:${cloud_path}"
		opts="${RCLONE_MERGERFS_OPTS:-async_read=false,use_ino,allow_other,auto_cache,func.getattr=newest,category.action=all,category.create=ff,dropcacheonclose=true}"
		exec mergerfs -o "${opts}" "${what}" "${media_path}"
	fi

	cloud_path="$(rclone_cloud::media_cloud_path)"
	what="${RCLONE_CACHE}:${cloud_path}"
	opts="${RCLONE_MERGERFS_OPTS:-async_read=false,use_ino,allow_other,auto_cache,func.getattr=newest,category.action=all,category.create=ff,dropcacheonclose=true}"
	install -d -m 0750 -o root -g "${RCLONE_USER}" "${RCLONE_RUN_MEDIA}"
	rclone_cloud::link_mount_path "${RCLONE_MEDIA}" "${RCLONE_RUN_MEDIA}" "${RCLONE_USER}"
	exec mergerfs -o "${opts}" "${what}" "${RCLONE_RUN_MEDIA}"
}

rclone_unit::media_stop() {
	rclone_cloud::load_mount_env 2>/dev/null || true
	local target="${RCLONE_RUN_MEDIA}"
	if [[ "${RCLONE_VIEW_MODE:-0}" == "1" && "${RCLONE_BRANCH}" != "main" ]]; then
		target="${RCLONE_RUN_ROOT}/views/${RCLONE_BRANCH}"
	fi
	rclone_unit::fusermount_uz "${target}"
}

rclone_unit::union_pre() {
	rclone_cloud::ensure_dirs
	install -d -m 0750 -o root -g "${RCLONE_USER}" "${RCLONE_RUN_UNION}"
	rclone_cloud::link_mount_path "${RCLONE_UNION}" "${RCLONE_RUN_UNION}" "${RCLONE_USER}"
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
		# Rewrite legacy ~/mounts/remote paths to /run
		if [[ "${line}" == /home/*/mounts/remote/* ]]; then
			local u b
			u="$(echo "${line}" | cut -d/ -f3)"
			b="$(basename "${line}")"
			line="$(rclone_cloud::remote_mount_path "${u}" "${b}")"
		fi
		parts+=("${line}")
	done <"${branches_file}"

	if [[ ${#parts[@]} -lt 2 ]]; then
		echo "union requires at least 2 branches" >&2
		exit 1
	fi

	local what opts
	what="$(IFS=:; echo "${parts[*]}")"
	opts="${RCLONE_MERGERFS_OPTS:-async_read=false,use_ino,allow_other,auto_cache,func.getattr=newest,category.action=all,category.create=ff,dropcacheonclose=true}"
	install -d -m 0750 -o root -g "${RCLONE_USER}" "${RCLONE_RUN_UNION}"
	rclone_cloud::link_mount_path "${RCLONE_UNION}" "${RCLONE_RUN_UNION}" "${RCLONE_USER}"
	exec mergerfs -o "${opts}" "${what}" "${RCLONE_RUN_UNION}"
}

rclone_unit::union_stop() {
	rclone_unit::fusermount_uz "${RCLONE_RUN_UNION}"
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
