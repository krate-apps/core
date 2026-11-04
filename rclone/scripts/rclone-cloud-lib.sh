#!/usr/bin/env bash
# Shared helpers for rclone cloud mount / mergerfs / move stack.
# Real FUSE/mergerfs live under /run/krate-rclone/<user>/ (root-owned).
# ~/mounts/{remote,media,union} are stable symlinks for apps and docs.
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
	# User-visible symlink paths (stable for apps).
	RCLONE_MEDIA="${RCLONE_HOME}/mounts/media"
	RCLONE_UNION="${RCLONE_HOME}/mounts/union"
	RCLONE_REMOTE_LINK="${RCLONE_HOME}/mounts/remote/${RCLONE_BRANCH}"
	# Real mount roots outside the home (root-owned; web server cannot enter).
	RCLONE_RUN_ROOT="/run/krate-rclone/${RCLONE_USER}"
	RCLONE_RUN_MEDIA="${RCLONE_RUN_ROOT}/media"
	RCLONE_RUN_UNION="${RCLONE_RUN_ROOT}/union"
	RCLONE_REMOTE_MOUNT="${RCLONE_RUN_ROOT}/remote/${RCLONE_BRANCH}"
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

# Primary branch id used by media (and default move dest). Defaults to main.
rclone_cloud::primary_branch() {
	local b="${RCLONE_PRIMARY_BRANCH:-}"
	if [[ -z "${b}" ]]; then
		# Legacy: MEDIA_CLOUD_BRANCH=remote meant the anonymous main mount.
		case "${RCLONE_MEDIA_CLOUD_BRANCH:-}" in
		"" | remote) b="main" ;;
		union) b="main" ;;
		*) b="${RCLONE_MEDIA_CLOUD_BRANCH}" ;;
		esac
	fi
	printf '%s\n' "${b}"
}

# Real FUSE path under /run (second arg is username when called as (user, branch)).
rclone_cloud::remote_mount_path() {
	local user_or_home="${1:?}" branch="${2:?}"
	local user="${user_or_home}"
	[[ "${user_or_home}" == /home/* ]] && user="$(basename "${user_or_home}")"
	printf '%s\n' "/run/krate-rclone/${user}/remote/${branch}"
}

rclone_cloud::remote_link_path() {
	local home="${1:?}" branch="${2:?}"
	printf '%s\n' "${home}/mounts/remote/${branch}"
}

# Cloud leg for mergerfs-media (primary branch path, or union) — real /run paths.
rclone_cloud::media_cloud_path() {
	local branch cloud
	if [[ "${RCLONE_MEDIA_CLOUD_BRANCH:-}" == "union" ]] || mountpoint -q "${RCLONE_RUN_UNION:-${RCLONE_UNION}}" 2>/dev/null; then
		printf '%s\n' "${RCLONE_RUN_UNION:-${RCLONE_UNION}}"
		return 0
	fi
	branch="$(rclone_cloud::primary_branch)"
	cloud="$(rclone_cloud::remote_mount_path "${RCLONE_USER:?}" "${branch}")"
	printf '%s\n' "${cloud}"
}

# Ensure /run/krate-rclone/<user> tree is root-owned, account can traverse, others cannot.
rclone_cloud::ensure_run_root() {
	local user="${1:?}"
	local root="/run/krate-rclone/${user}"
	install -d -m 0755 -o root -g root /run/krate-rclone
	install -d -m 0750 -o root -g "${user}" "${root}" \
		"${root}/remote" "${root}/media" "${root}/union" "${root}/views"
}

# Point ~/mounts/<name> at /run/... (replace a leftover directory if empty / unmounted).
rclone_cloud::link_mount_path() {
	local link="${1:?}" target="${2:?}" user="${3:?}"
	if [[ -L "${link}" ]]; then
		local cur
		cur="$(readlink -f "${link}" 2>/dev/null || readlink "${link}" || true)"
		[[ "${cur}" == "${target}" ]] && return 0
		rm -f "${link}"
	elif [[ -d "${link}" ]]; then
		if mountpoint -q "${link}" 2>/dev/null; then
			rclone_cloud::fusermount_uz "${link}"
		fi
		# Only remove if empty (no pending local files).
		rmdir "${link}" 2>/dev/null || {
			echo "rclone: leave ${link} in place (not empty); expected symlink to ${target}" >&2
			return 0
		}
	elif [[ -e "${link}" ]]; then
		rm -f "${link}"
	fi
	install -d -m 0755 -o "${user}" -g "${user}" "$(dirname "${link}")"
	ln -sfn "${target}" "${link}"
	chown -h "${user}:${user}" "${link}" 2>/dev/null || true
}

# Comment out user_allow_other so non-root accounts cannot make web-readable FUSE mounts.
# Root can still pass --allow-other for managed mounts.
rclone_cloud::retire_user_allow_other() {
	local conf="/etc/fuse.conf"
	[[ -f "${conf}" ]] || return 0
	if grep -qE '^[[:space:]]*user_allow_other' "${conf}"; then
		sed -i -E 's/^([[:space:]]*user_allow_other)/# \1 # retired by krate rclone isolation/' "${conf}"
	fi
}

# Strip setuid from FUSE helpers that ignore fuse.conf (e.g. ntfs-3g).
rclone_cloud::strip_setuid_fuse_mounters() {
	local path
	for path in /bin/ntfs-3g /usr/bin/ntfs-3g /sbin/ntfs-3g /usr/sbin/ntfs-3g; do
		[[ -e "${path}" ]] || continue
		dpkg-statoverride --update --add root root 0755 "${path}" 2>/dev/null \
			|| chmod 0755 "${path}" 2>/dev/null \
			|| true
	done
	# Pre-register so a later package install unpacks at 755.
	if ! dpkg-statoverride --list /usr/bin/ntfs-3g >/dev/null 2>&1; then
		dpkg-statoverride --add root root 0755 /usr/bin/ntfs-3g 2>/dev/null || true
	fi
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

# Obscure a secret via rclone stdin ("obscure -") so the plaintext never hits argv.
rclone_cloud::obscure_stdin() {
	local plain="${1:?}"
	local bin obscured
	bin="$(rclone_cloud::rclone_bin)"
	obscured="$(
		rclone_cloud::run_as_user "${bin}" obscure - <<EOF
${plain}
EOF
	)" || return 1
	# rclone obscure prints a trailing newline
	printf '%s' "${obscured%%$'\n'}"
}

# Upsert an rclone.conf section. Keys/values arrive as JSON object on stdin
# ({"type":"crypt","remote":"Media:","password":"<obscured>",...}) so secrets stay
# off process arguments. Writes as the account when possible.
rclone_cloud::conf_upsert_section() {
	local conf="${1:?}" section="${2:?}"
	local u="${RCLONE_USER:-}"
	local tmp
	tmp="$(mktemp)"
	cat >"${tmp}"
	python3 - "${conf}" "${section}" "${tmp}" <<'PY'
import pathlib, sys
conf_path, section, payload_path = sys.argv[1], sys.argv[2], sys.argv[3]
raw = pathlib.Path(payload_path).read_text(encoding="utf-8")
import json
kv = json.loads(raw)
path = pathlib.Path(conf_path)
text = path.read_text(encoding="utf-8") if path.is_file() else ""
lines = text.splitlines()
out = []
i = 0
header = f"[{section}]"
while i < len(lines):
    line = lines[i]
    if line.strip() == header:
        i += 1
        while i < len(lines) and not lines[i].startswith("["):
            i += 1
        continue
    out.append(line)
    i += 1
if out and out[-1] != "":
    out.append("")
out.append(header)
for key, val in kv.items():
    out.append(f"{key} = {val}")
out.append("")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(out), encoding="utf-8")
PY
	rm -f "${tmp}"
	if [[ -n "${u}" ]]; then
		chown "${u}:${u}" "${conf}" 2>/dev/null || true
	fi
	chmod 0600 "${conf}" 2>/dev/null || true
}

rclone_cloud::fusermount_uz() {
	local target="${1:?}"
	if mountpoint -q "${target}" 2>/dev/null; then
		fusermount3 -uz "${target}" 2>/dev/null || fusermount -uz "${target}" 2>/dev/null || true
	fi
}

# True when ~/mounts/cache (local move staging) still has files — must not tear down.
rclone_cloud::cache_has_pending_files() {
	local cache="${1:?}"
	[[ -d "${cache}" ]] || return 1
	# Any regular file under cache (empty dirs are OK).
	local hit
	hit="$(find "${cache}" -xdev -type f -print -quit 2>/dev/null || true)"
	[[ -n "${hit}" ]]
}

# Idempotent layout migration: mounts/remote leaf + mounts/remotes/* → mounts/remote/<name>.
rclone_cloud::migrate_layout() {
	local user="${1:?}"
	local home="/home/${user}"
	local state="${home}/.krate/applications/rclone-cloud"
	local remote_root="${home}/mounts/remote"
	local remotes_root="${home}/mounts/remotes"
	local profile="${state}/profile.env"
	local branches_file="${state}/union.branches"
	local migrated=0

	install -d -m 0755 -o "${user}" -g "${user}" "${home}/mounts" "${state}" "${state}/mounts"

	# Old leaf mount at mounts/remote (no subdirectory named after a branch).
	if mountpoint -q "${remote_root}" 2>/dev/null; then
		rclone_cloud::fusermount_uz "${remote_root}"
		migrated=1
	fi

	# If mounts/remote exists but is not yet a parent of main/, promote to remote/main.
	if [[ -d "${remote_root}" && ! -d "${remote_root}/main" ]]; then
		# Only treat as legacy leaf if it has no branch-like children yet.
		local child has_branch_child=0
		shopt -s nullglob
		for child in "${remote_root}"/*; do
			[[ -d "${child}" ]] || continue
			case "$(basename "${child}")" in
			main | cache | media | union | remotes | views) ;;
			*)
				# Already looks like new layout (e.g. remote/backup) without main yet.
				has_branch_child=1
				;;
			esac
		done
		shopt -u nullglob
		if [[ "${has_branch_child}" -eq 0 ]]; then
			# Empty (post-umount) or leftover files: create main and move loose entries aside.
			install -d -m 0755 -o "${user}" -g "${user}" "${remote_root}/main"
			migrated=1
		fi
	fi

	install -d -m 0755 -o "${user}" -g "${user}" "${remote_root}/main"

	# Move legacy plural remotes/* → remote/*
	if [[ -d "${remotes_root}" ]]; then
		local d name dest
		shopt -s nullglob
		for d in "${remotes_root}"/*; do
			[[ -e "${d}" ]] || continue
			name="$(basename "${d}")"
			dest="${remote_root}/${name}"
			if mountpoint -q "${d}" 2>/dev/null; then
				rclone_cloud::fusermount_uz "${d}"
			fi
			if [[ -e "${dest}" ]]; then
				# Prefer keeping existing target; drop empty source.
				rmdir "${d}" 2>/dev/null || true
			else
				mv "${d}" "${dest}"
			fi
			migrated=1
		done
		shopt -u nullglob
		rmdir "${remotes_root}" 2>/dev/null || true
	fi

	# Rewrite union.branches paths.
	if [[ -f "${branches_file}" ]]; then
		local tmp
		tmp="$(mktemp)"
		while IFS= read -r line || [[ -n "${line}" ]]; do
			[[ -z "${line}" || "${line}" =~ ^# ]] && continue
			line="${line//${home}\/mounts\/remotes\//${home}\/mounts\/remote\/}"
			if [[ "${line}" == "${home}/mounts/remote" ]]; then
				line="${home}/mounts/remote/main"
			fi
			printf '%s\n' "${line}"
		done <"${branches_file}" >"${tmp}"
		mv "${tmp}" "${branches_file}"
		chown "${user}:${user}" "${branches_file}" 2>/dev/null || true
	fi

	# Profile: introduce PRIMARY_BRANCH; map legacy MEDIA_CLOUD_BRANCH=remote → main.
	if [[ -f "${profile}" ]]; then
		if ! grep -q '^RCLONE_PRIMARY_BRANCH=' "${profile}" 2>/dev/null; then
			echo 'RCLONE_PRIMARY_BRANCH=main' >>"${profile}"
			migrated=1
		fi
		if grep -q '^RCLONE_MEDIA_CLOUD_BRANCH=remote$' "${profile}" 2>/dev/null; then
			sed -i 's/^RCLONE_MEDIA_CLOUD_BRANCH=remote$/RCLONE_MEDIA_CLOUD_BRANCH=main/' "${profile}"
			migrated=1
		fi
		chown "${user}:${user}" "${profile}" 2>/dev/null || true
		chmod 0600 "${profile}" 2>/dev/null || true
	fi

	[[ "${migrated}" -eq 1 ]] || return 0

	# status/setup may umount the legacy leaf; bring mounts back unless a unit
	# ExecStartPre is about to mount (avoid restart loops).
	if [[ "${RCLONE_MIGRATE_NO_RESTART:-0}" != "1" ]]; then
		rclone_cloud::restart_mounts_after_migrate "${user}"
	fi
	return 0
}

# Restart rclone FUSE + mergerfs after a layout migrate that may have umounted.
# Prefer restart/start — try-restart is a no-op (exit 0) when the unit is inactive.
rclone_cloud::restart_mounts_after_migrate() {
	local user="${1:?}"
	local state="/home/${user}/.krate/applications/rclone-cloud"
	local f b
	_restart_unit() {
		local u="${1:?}"
		systemctl restart "${u}" 2>/dev/null || systemctl start "${u}" 2>/dev/null || true
	}
	_restart_unit "rclone-mount@${user}.service"
	shopt -s nullglob
	for f in "${state}/mounts"/*.env; do
		[[ -f "${f}" ]] || continue
		b="$(basename "${f}" .env)"
		[[ "${b}" == "main" ]] && continue
		if grep -q '^RCLONE_VIEW_MODE=1' "${f}" 2>/dev/null; then
			continue
		fi
		_restart_unit "rclone-mount@${user}--${b}.service"
	done
	shopt -u nullglob
	_restart_unit "mergerfs-union@${user}.service"
	_restart_unit "mergerfs-media@${user}.service"
}

rclone_cloud::rebuild_union_branches() {
	local user="${1:?}"
	local home="/home/${user}"
	local state="${home}/.krate/applications/rclone-cloud"
	local branches_file="${state}/union.branches"
	local f b
	{
		echo "$(rclone_cloud::remote_mount_path "${user}" "main")"
		for f in "${state}/mounts"/*.env; do
			[[ -f "${f}" ]] || continue
			b="$(basename "${f}" .env)"
			[[ "${b}" == "main" ]] && continue
			# Skip dedicated media views (they have their own mergerfs).
			if grep -q '^RCLONE_VIEW_MODE=1' "${f}" 2>/dev/null; then
				continue
			fi
			echo "$(rclone_cloud::remote_mount_path "${user}" "${b}")"
		done
	} >"${branches_file}"
	chown "${user}:${user}" "${branches_file}" 2>/dev/null || true
}

rclone_cloud::ensure_dirs() {
	local primary
	primary="$(rclone_cloud::primary_branch 2>/dev/null || echo main)"
	rclone_cloud::ensure_run_root "${RCLONE_USER}"
	install -d -m 0750 -o root -g "${RCLONE_USER}" \
		"${RCLONE_REMOTE_MOUNT}" \
		"$(rclone_cloud::remote_mount_path "${RCLONE_USER}" "${primary}")" \
		"${RCLONE_RUN_MEDIA}" \
		"${RCLONE_RUN_UNION}"
	install -d -m 0755 -o "${RCLONE_USER}" -g "${RCLONE_USER}" \
		"${RCLONE_HOME}/mounts" \
		"${RCLONE_HOME}/.cache/rclone" \
		"${RCLONE_CACHE}" \
		"${RCLONE_HOME}/mounts/remote" \
		"${RCLONE_STATE_DIR}" \
		"${RCLONE_STATE_DIR}/mounts" \
		"${RCLONE_LOG_DIR}"
	rclone_cloud::link_mount_path "${RCLONE_REMOTE_LINK}" "${RCLONE_REMOTE_MOUNT}" "${RCLONE_USER}"
	rclone_cloud::link_mount_path \
		"$(rclone_cloud::remote_link_path "${RCLONE_HOME}" "${primary}")" \
		"$(rclone_cloud::remote_mount_path "${RCLONE_USER}" "${primary}")" \
		"${RCLONE_USER}"
	rclone_cloud::link_mount_path "${RCLONE_MEDIA}" "${RCLONE_RUN_MEDIA}" "${RCLONE_USER}"
	rclone_cloud::link_mount_path "${RCLONE_UNION}" "${RCLONE_RUN_UNION}" "${RCLONE_USER}"
}

# Lazy-unmount any FUSE that masks /opt/<user> (program trees must stay local).
rclone_cloud::refuse_fuse_over_opt() {
	local user="${1:?}"
	local opt="/opt/${user}"
	local tgt fstype
	[[ -d "${opt}" ]] || return 0
	while IFS= read -r tgt; do
		[[ -n "${tgt}" ]] || continue
		fstype="$(findmnt -n -o FSTYPE "${tgt}" 2>/dev/null || true)"
		case "${fstype}" in
		fuse | fuse.* | fuseblk)
			echo "rclone: refusing FUSE over program path ${tgt} (${fstype}) — unmounting" >&2
			rclone_cloud::fusermount_uz "${tgt}"
			;;
		esac
	done < <(findmnt -n -o TARGET -R "${opt}" 2>/dev/null || true)
}

# Move legacy in-home FUSE/mergerfs mounts to /run and leave ~/mounts as symlinks.
rclone_cloud::secure_mounts() {
	local user="${1:?}"
	rclone_cloud::parse_instance "${user}"
	rclone_cloud::ensure_run_root "${user}"
	rclone_cloud::retire_user_allow_other
	rclone_cloud::strip_setuid_fuse_mounters
	rclone_cloud::refuse_fuse_over_opt "${user}"

	local home="${RCLONE_HOME}"
	local path
	for path in \
		"${home}/mounts/media" \
		"${home}/mounts/union" \
		"${home}/mounts/remote" \
		"${home}/mounts/remote"/* \
		"${home}/mounts/remotes"/* \
		"${home}/mounts/views"/*; do
		[[ -e "${path}" || -L "${path}" ]] || continue
		if [[ -d "${path}" ]] && ! [[ -L "${path}" ]] && mountpoint -q "${path}" 2>/dev/null; then
			rclone_cloud::fusermount_uz "${path}"
		fi
	done

	rclone_cloud::ensure_dirs
	# Re-link every known branch env.
	local f b
	shopt -s nullglob
	for f in "${RCLONE_STATE_DIR}/mounts"/*.env; do
		b="$(basename "${f}" .env)"
		rclone_cloud::link_mount_path \
			"$(rclone_cloud::remote_link_path "${home}" "${b}")" \
			"$(rclone_cloud::remote_mount_path "${user}" "${b}")" \
			"${user}"
	done
	shopt -u nullglob
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
