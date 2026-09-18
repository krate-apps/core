#!/usr/bin/env bash
# Install systemd templates + apply cloud profile for a user.
# shellcheck disable=SC1090,SC2154
set -euo pipefail

SCRIPTS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC_DST="/usr/lib/krate/rclone"
SYSTEMD_DST="/etc/systemd/system"
KRATE_HOME="${KRATE_HOME:-/opt/Krate}"

# Templates live next to the app (…/rclone/templates) or mirrored under libexec after install.
# Never `cd` a missing path here — this file is also sourced from /usr/lib/krate/rclone.
rclone_cloud_setup::resolve_templates() {
	local c home="${KRATE_HOME:-/opt/Krate}"
	for c in \
		"${SCRIPTS_SRC}/templates" \
		"${SCRIPTS_SRC}/../templates" \
		"${LIBEXEC_DST}/templates" \
		"${home}/share/applications/official/rclone/templates" \
		"${home}/share/applications/community/rclone/templates"; do
		if [[ -d "${c}" && -f "${c}/rclone-mount@.service" ]]; then
			# Prefer realpath without failing the whole script on odd layouts.
			(cd "${c}" && pwd) && return 0
		fi
	done
	return 1
}

TEMPLATES_SRC="$(rclone_cloud_setup::resolve_templates || true)"

# shellcheck source=rclone-cloud-lib.sh
[[ "$(type -t rclone_cloud::parse_instance 2>/dev/null || true)" == "function" ]] || source "${SCRIPTS_SRC}/rclone-cloud-lib.sh"

rclone_cloud_setup::install_files() {
	install -d -m 0755 "${LIBEXEC_DST}"

	# Refresh template resolution first so we can pull scripts from the same package tree.
	TEMPLATES_SRC="$(rclone_cloud_setup::resolve_templates || true)"
	local scripts_from="${SCRIPTS_SRC}"
	if [[ -n "${TEMPLATES_SRC}" && -d "${TEMPLATES_SRC}/../scripts" ]]; then
		scripts_from="$(cd "${TEMPLATES_SRC}/../scripts" && pwd)"
	fi
	install -m 0755 "${scripts_from}"/*.sh "${LIBEXEC_DST}/"
	# Ensure management entrypoint is executable even if umask odd
	chmod 0755 "${LIBEXEC_DST}/rclone-cloud-ctl.sh" "${LIBEXEC_DST}/rclone-unit.sh" 2>/dev/null || true
	# Drop legacy per-hook scripts from older installs
	rm -f \
		"${LIBEXEC_DST}/rclone-mount-pre.sh" \
		"${LIBEXEC_DST}/rclone-mount-start.sh" \
		"${LIBEXEC_DST}/rclone-mount-stop.sh" \
		"${LIBEXEC_DST}/mergerfs-media-pre.sh" \
		"${LIBEXEC_DST}/mergerfs-media-start.sh" \
		"${LIBEXEC_DST}/mergerfs-media-stop.sh" \
		"${LIBEXEC_DST}/mergerfs-union-pre.sh" \
		"${LIBEXEC_DST}/mergerfs-union-start.sh" \
		"${LIBEXEC_DST}/mergerfs-union-stop.sh"

	if [[ -n "${TEMPLATES_SRC}" ]]; then
		install -d -m 0755 "${LIBEXEC_DST}/templates"
		install -m 0644 \
			"${TEMPLATES_SRC}/rclone-mount@.service" \
			"${TEMPLATES_SRC}/mergerfs-media@.service" \
			"${TEMPLATES_SRC}/mergerfs-union@.service" \
			"${TEMPLATES_SRC}/rclone-move@.service" \
			"${TEMPLATES_SRC}/rclone-move@.timer" \
			"${LIBEXEC_DST}/templates/"
		install -m 0644 "${LIBEXEC_DST}/templates/rclone-mount@.service" "${SYSTEMD_DST}/rclone-mount@.service"
		install -m 0644 "${LIBEXEC_DST}/templates/mergerfs-media@.service" "${SYSTEMD_DST}/mergerfs-media@.service"
		install -m 0644 "${LIBEXEC_DST}/templates/mergerfs-union@.service" "${SYSTEMD_DST}/mergerfs-union@.service"
		install -m 0644 "${LIBEXEC_DST}/templates/rclone-move@.service" "${SYSTEMD_DST}/rclone-move@.service"
		install -m 0644 "${LIBEXEC_DST}/templates/rclone-move@.timer" "${SYSTEMD_DST}/rclone-move@.timer"
	elif [[ -f "${SYSTEMD_DST}/rclone-mount@.service" ]]; then
		# Scripts-only refresh: units already on disk from a prior install.
		:
	else
		echo "rclone cloud templates not found (expected …/rclone/templates or ${LIBEXEC_DST}/templates)" >&2
		return 1
	fi

	# FUSE allow_other required for mergerfs/rclone multi-user mounts
	if [[ -f /etc/fuse.conf ]] && ! grep -qE '^[[:space:]]*user_allow_other' /etc/fuse.conf; then
		echo 'user_allow_other' >>/etc/fuse.conf
	fi
	systemctl daemon-reload
}

# Write profile + main mount env; enable units for preset.
# Args via env: username, preset, mode, provider, remote, team_drive, drive_root
rclone_cloud_setup::apply_user() {
	local user="${1:?username}"
	local preset="${2:-media}"
	local mode="${3:-import}"
	local provider="${4:-import}"
	local remote="${5:-Media}"
	local team_drive="${6:-}"
	local drive_root="${7:-mydrive}"

	# Legacy "browse" preset removed — always run the media stack.
	preset="media"

	local home="/home/${user}"
	local state="${home}/.krate/applications/rclone-cloud"
	local conf="${home}/.config/rclone/rclone.conf"
	local remote_spec="${remote}:"

	install -d -m 0755 -o "${user}" -g "${user}" \
		"${home}/mounts" "${home}/mounts/cache" "${home}/mounts/media" \
		"${home}/mounts/remote" "${home}/mounts/remote/main" \
		"${state}" "${state}/mounts" "${home}/.krate/logs/rclone" \
		"${home}/.config/rclone"

	rclone_cloud::migrate_layout "${user}" 2>/dev/null || true

	[[ -f "${conf}" ]] || install -m 0600 -o "${user}" -g "${user}" /dev/null "${conf}"

	# Optional Shared Drive / Team Drive annotation for Google remotes (user may still need OAuth).
	if [[ -n "${team_drive}" && "${provider}" == "drive" ]]; then
		if ! grep -q "^\[${remote}\]" "${conf}" 2>/dev/null; then
			{
				printf '\n[%s]\n' "${remote}"
				printf 'type = drive\n'
				printf 'scope = drive\n'
				printf 'team_drive = %s\n' "${team_drive}"
			} >>"${conf}"
			chown "${user}:${user}" "${conf}"
			chmod 0600 "${conf}"
		elif ! grep -q "^team_drive" "${conf}"; then
			# Best-effort: append under section if missing (simple cases).
			true
		fi
	fi

	local existing_cal="" existing_unit="" existing_boot="" existing_bw="" existing_min=""
	local existing_move_flags="" prev_provider="" existing_primary="main" existing_media_cloud="main"
	# Reset so write_mount_env / defaults don't inherit caller's environment.
	unset RCLONE_MOUNT_FLAGS RCLONE_BACKEND_FLAGS RCLONE_MOVE_FLAGS || true
	if [[ -f "${state}/profile.env" ]]; then
		# shellcheck source=/dev/null
		set -a && source "${state}/profile.env" && set +a
		existing_cal="${RCLONE_MOVE_ON_CALENDAR:-}"
		existing_unit="${RCLONE_MOVE_ON_UNIT_ACTIVE:-}"
		existing_boot="${RCLONE_MOVE_ON_BOOT:-}"
		existing_bw="${RCLONE_MOVE_BWLIMIT:-}"
		existing_min="${RCLONE_MOVE_MIN_AGE:-30m}"
		existing_move_flags="${RCLONE_MOVE_FLAGS:-}"
		prev_provider="${RCLONE_PROVIDER:-}"
		existing_primary="${RCLONE_PRIMARY_BRANCH:-main}"
		existing_media_cloud="${RCLONE_MEDIA_CLOUD_BRANCH:-main}"
		case "${existing_media_cloud}" in
		remote) existing_media_cloud="main" ;;
		esac
	fi
	if [[ -f "${state}/mounts/main.env" ]]; then
		# shellcheck source=/dev/null
		set -a && source "${state}/mounts/main.env" && set +a
		[[ -n "${prev_provider}" ]] || prev_provider="${RCLONE_PROVIDER:-}"
	fi
	# Keep custom flags only when provider unchanged.
	if [[ "${prev_provider}" != "${provider}" ]]; then
		unset RCLONE_MOUNT_FLAGS RCLONE_BACKEND_FLAGS || true
		existing_move_flags=""
	fi

	local move_flags="${existing_move_flags}"
	if [[ -z "${move_flags}" ]]; then
		RCLONE_HOME="${home}" move_flags="$(rclone_cloud::default_move_flags "${provider}")"
	fi

	cat >"${state}/profile.env" <<EOF
RCLONE_PRESET=media
RCLONE_MODE=${mode}
RCLONE_PROVIDER=${provider}
RCLONE_DRIVE_ROOT=${drive_root}
RCLONE_MOVE_ENABLED=1
RCLONE_MOVE_DEST=${remote_spec}
RCLONE_MOVE_MIN_AGE=${existing_min:-30m}
RCLONE_MOVE_BWLIMIT=${existing_bw}
RCLONE_MOVE_FLAGS='${move_flags}'
RCLONE_PRIMARY_BRANCH=${existing_primary}
RCLONE_MEDIA_CLOUD_BRANCH=${existing_media_cloud}
RCLONE_MOVE_ON_CALENDAR=${existing_cal}
RCLONE_MOVE_ON_UNIT_ACTIVE=${existing_unit:-30min}
RCLONE_MOVE_ON_BOOT=${existing_boot:-15min}
EOF
	chown "${user}:${user}" "${state}/profile.env"
	chmod 0600 "${state}/profile.env"

	RCLONE_HOME="${home}" rclone_cloud::write_mount_env "${state}/mounts/main.env" "${remote_spec}" "${provider}"
	chown "${user}:${user}" "${state}/mounts/main.env"
	chmod 0600 "${state}/mounts/main.env"

	local mount_unit="rclone-mount@${user}.service"
	systemctl enable "${mount_unit}" || true

	systemctl enable "mergerfs-media@${user}.service" || true
	systemctl enable "rclone-move@${user}.timer" || true

	# Start mounts only when the remote already exists in conf (import path).
	if grep -qE "^\[${remote}\]$" "${conf}" 2>/dev/null; then
		systemctl reset-failed "${mount_unit}" 2>/dev/null || true
		systemctl restart "${mount_unit}" || true
		systemctl restart "mergerfs-media@${user}.service" || true
		systemctl start "rclone-move@${user}.timer" || true
	else
		# Avoid Restart=on-failure crash loops against a missing remote (e.g. default Media:).
		systemctl stop "${mount_unit}" 2>/dev/null || true
		systemctl reset-failed "${mount_unit}" 2>/dev/null || true
		echo "rclone remote [${remote}] not in conf yet — complete OAuth (zen rclone oauth-*) or service-account / import-conf, then restart ${mount_unit}" >&2
	fi
}

rclone_cloud_setup::teardown_user() {
	local user="${1:?username}"
	local home="/home/${user}"
	local state="${home}/.krate/applications/rclone-cloud"
	local cache="${home}/mounts/cache"

	# Refuse any teardown/remove while staged files remain in the local cache.
	if rclone_cloud::cache_has_pending_files "${cache}"; then
		echo "rclone: refuse remove/teardown — ${cache} is not empty (pending files for move)." >&2
		echo "  Empty or finish moving that cache, then retry uninstall / zen rclone teardown ${user}." >&2
		return 1
	fi

	systemctl disable --now "rclone-mount@${user}.service" 2>/dev/null || true
	systemctl disable --now "mergerfs-media@${user}.service" 2>/dev/null || true
	systemctl disable --now "mergerfs-union@${user}.service" 2>/dev/null || true
	systemctl disable --now "rclone-move@${user}.timer" 2>/dev/null || true
	systemctl disable --now "rclone-move@${user}.service" 2>/dev/null || true

	# Extra branches + named media views: username--*
	local u
	for u in $(systemctl list-units --type=service --all --no-legend 'rclone-mount@*.service' 2>/dev/null | awk '{print $1}'); do
		case "${u}" in
		rclone-mount@"${user}"--*.service)
			systemctl disable --now "${u}" 2>/dev/null || true
			;;
		esac
	done
	for u in $(systemctl list-units --type=service --all --no-legend 'mergerfs-media@*.service' 2>/dev/null | awk '{print $1}'); do
		case "${u}" in
		mergerfs-media@"${user}"--*.service)
			systemctl disable --now "${u}" 2>/dev/null || true
			;;
		esac
	done

	# Drop FUSE before deleting mountpoint directories.
	local p
	shopt -s nullglob
	for p in \
		"${home}/mounts/media" \
		"${home}/mounts/union" \
		"${home}/mounts/remote" \
		"${home}/mounts/remote"/* \
		"${home}/mounts/remotes"/* \
		"${home}/mounts/views"/*; do
		[[ -e "${p}" ]] || continue
		rclone_cloud::fusermount_uz "${p}" 2>/dev/null || true
	done
	shopt -u nullglob

	# Remove cloud layout + state (keep ~/.config/rclone conf — data_dir lifecycle owns it).
	rm -rf \
		"${home}/mounts/cache" \
		"${home}/mounts/media" \
		"${home}/mounts/remote" \
		"${home}/mounts/remotes" \
		"${home}/mounts/union" \
		"${home}/mounts/views" \
		"${state}" \
		"${home}/.cache/rclone"
	rmdir "${home}/mounts" 2>/dev/null || true

	rm -rf "/etc/systemd/system/rclone-move@${user}.timer.d" 2>/dev/null || true
	systemctl daemon-reload 2>/dev/null || true
	systemctl reset-failed \
		"rclone-mount@${user}.service" \
		"mergerfs-media@${user}.service" \
		"mergerfs-union@${user}.service" \
		"rclone-move@${user}.timer" \
		"rclone-move@${user}.service" \
		2>/dev/null || true
}

# Add an advanced branch: rclone_cloud_setup::add_branch user branchid remote_spec [union=0|1]
rclone_cloud_setup::add_branch() {
	local user="${1:?}"
	local branch="${2:?}"
	local remote_spec="${3:?}"
	local with_union="${4:-0}"
	local home="/home/${user}"
	local state="${home}/.krate/applications/rclone-cloud"
	local mount_path
	mount_path="$(rclone_cloud::remote_mount_path "${home}" "${branch}")"

	rclone_cloud::migrate_layout "${user}" 2>/dev/null || true
	install -d -m 0755 -o "${user}" -g "${user}" \
		"${home}/mounts/remote" "${mount_path}" "${state}/mounts"
	local provider="import"
	if [[ -f "${state}/profile.env" ]]; then
		# shellcheck source=/dev/null
		set -a && source "${state}/profile.env" && set +a
		provider="${RCLONE_PROVIDER:-import}"
	fi
	unset RCLONE_MOUNT_FLAGS RCLONE_BACKEND_FLAGS || true
	RCLONE_HOME="${home}" rclone_cloud::write_mount_env "${state}/mounts/${branch}.env" "${remote_spec}" "${provider}"
	chown "${user}:${user}" "${state}/mounts/${branch}.env"
	chmod 0600 "${state}/mounts/${branch}.env"

	local instance="${user}--${branch}"
	systemctl enable --now "rclone-mount@${instance}.service"

	# Optional: merge this branch (and others) into mounts/union and point media at it.
	# Default is off so secondary remotes (e.g. backup) stay isolated under remote/<id>.
	if [[ "${with_union}" == "1" ]]; then
		rclone_cloud::rebuild_union_branches "${user}"
		local branches_file="${state}/union.branches"
		if [[ "$(grep -c . "${branches_file}" || true)" -ge 2 ]]; then
			sed -i 's/^RCLONE_MEDIA_CLOUD_BRANCH=.*/RCLONE_MEDIA_CLOUD_BRANCH=union/' "${state}/profile.env" || true
			if ! grep -q '^RCLONE_PRIMARY_BRANCH=' "${state}/profile.env" 2>/dev/null; then
				echo 'RCLONE_PRIMARY_BRANCH=main' >>"${state}/profile.env"
			fi
			systemctl enable --now "mergerfs-union@${user}.service" || true
			systemctl restart "mergerfs-media@${user}.service" || true
		fi
	fi
}

# Point media (+ move dest) at an existing branch: rclone_cloud_setup::set_primary_branch user branch
rclone_cloud_setup::set_primary_branch() {
	local user="${1:?}"
	local branch="${2:?}"
	local home="/home/${user}"
	local state="${home}/.krate/applications/rclone-cloud"
	local profile="${state}/profile.env"
	local envf="${state}/mounts/${branch}.env"
	[[ -f "${envf}" ]] || {
		echo "missing branch env: ${envf}" >&2
		return 1
	}
	rclone_cloud::migrate_layout "${user}" 2>/dev/null || true
	# shellcheck source=/dev/null
	set -a && source "${envf}" && set +a
	local remote_spec="${RCLONE_REMOTE_SPEC:?}"
	[[ -f "${profile}" ]] || {
		echo "missing profile: ${profile}" >&2
		return 1
	}
	if grep -q '^RCLONE_PRIMARY_BRANCH=' "${profile}" 2>/dev/null; then
		sed -i "s/^RCLONE_PRIMARY_BRANCH=.*/RCLONE_PRIMARY_BRANCH=${branch}/" "${profile}"
	else
		echo "RCLONE_PRIMARY_BRANCH=${branch}" >>"${profile}"
	fi
	# When not unioning, media follows the primary branch path.
	if ! grep -q '^RCLONE_MEDIA_CLOUD_BRANCH=union$' "${profile}" 2>/dev/null; then
		sed -i "s/^RCLONE_MEDIA_CLOUD_BRANCH=.*/RCLONE_MEDIA_CLOUD_BRANCH=${branch}/" "${profile}" || \
			echo "RCLONE_MEDIA_CLOUD_BRANCH=${branch}" >>"${profile}"
	fi
	if grep -q '^RCLONE_MOVE_DEST=' "${profile}" 2>/dev/null; then
		sed -i "s|^RCLONE_MOVE_DEST=.*|RCLONE_MOVE_DEST=${remote_spec}|" "${profile}"
	else
		echo "RCLONE_MOVE_DEST=${remote_spec}" >>"${profile}"
	fi
	chown "${user}:${user}" "${profile}"
	chmod 0600 "${profile}"
	systemctl restart "mergerfs-media@${user}.service" 2>/dev/null || true
}
