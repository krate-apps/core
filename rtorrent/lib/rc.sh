#!/usr/bin/env bash
# Shared .rtorrent.rc conversion helpers (sourced by handler + bin/rtorrent-rc-convert.sh).
# shellcheck disable=SC2034
set -euo pipefail

# Canonical rc dialect threshold: schedule2/encoding.add break without -D from 0.16.14+.
_RC_MODERN_SINCE="0.16.14"
# Defaults when reverse-injecting legacy socket ceilings (aligned with LimitNOFILE=16384).
_RC_LEGACY_MAX_OPEN_FILES="4096"
_RC_LEGACY_MAX_OPEN_SOCKETS="4096"
# Modern ceiling (match systemd LimitNOFILE). Keep below RLIMIT; avoid adjust_alloc.
_RC_SOCKET_MAX_SIZE="16384"
_RC_SOCKET_FILES_MIN_ALLOC="2048"
_RC_SOCKET_HTTP_MIN_ALLOC="250"
# 0.15.x session save can stall when fdatasync is left on; KRATE injects = 0 with
# a marker so 0.16.x can drop only the managed line and preserve a user override.
_RC_FDATASYNC_MARKER="# krate:managed-session-fdatasync"
_RC_FDATASYNC_LINE="system.files.session.fdatasync.set = 0"

# True (exit 0) when version uses modern rc dialect (no schedule2 / encoding.add).
_rc_is_modern() {
	local ver="${1:-}"
	[[ -n "${ver}" ]] || return 1
	# sort -V ascending: first line is the lower bound → ver >= _RC_MODERN_SINCE
	[[ "$(printf '%s\n' "${_RC_MODERN_SINCE}" "${ver}" | sort -V | head -n1)" == "${_RC_MODERN_SINCE}" ]]
}

# Exit 0 when from/to cross the modern dialect boundary (or either side unknown).
_rc_dialect_changed() {
	local from="${1:-}" to="${2:-}"
	[[ -n "${to}" ]] || return 1
	[[ -n "${from}" ]] || return 0
	if _rc_is_modern "${from}"; then
		_rc_is_modern "${to}" && return 1 || return 0
	else
		_rc_is_modern "${to}" && return 0 || return 1
	fi
}

# Raise global open limits below 512 (avoids rTorrent crash on 0.16.13+).
# Category min_alloc (http/files/…) stays as configured — only global ceilings are floored.
_rc_floor_max_open() {
	local rc_path="${1:?}" line key val prefix rest out
	[[ -f "${rc_path}" ]] || return 0
	out="$(mktemp)"
	while IFS= read -r line || [[ -n "${line}" ]]; do
		if [[ "${line}" =~ ^([[:space:]]*)((network\.max_open_(sockets|files)|system\.sockets\.max_size)\.set)[[:space:]]*=[[:space:]]*([0-9]+)(.*)$ ]]; then
			prefix="${BASH_REMATCH[1]}"
			key="${BASH_REMATCH[2]}"
			val="${BASH_REMATCH[5]}"
			rest="${BASH_REMATCH[6]}"
			if (( val > 0 && val < 512 )); then
				line="${prefix}${key} = 512${rest}"
			fi
		fi
		printf '%s\n' "${line}"
	done <"${rc_path}" >"${out}"
	mv -f "${out}" "${rc_path}"
}

# Resync listen port range from autogen (both dialects).
_rc_sync_port_range() {
	local rc_path="${1:?}" port_range="${2:-}"
	[[ -f "${rc_path}" && -n "${port_range}" ]] || return 0
	sed -i -E \
		-e "s|^([[:space:]]*network\.listen\.port\.range\.set[[:space:]]*=[[:space:]]*).*$|\1${port_range}|" \
		-e "s|^([[:space:]]*network\.port_range\.set[[:space:]]*=[[:space:]]*).*$|\1${port_range}|" \
		"${rc_path}"
}

# Drop the KRATE-managed fdatasync pair (marker + following set line). Keep user overrides.
_rc_drop_managed_fdatasync() {
	local rc_path="${1:?}" out
	[[ -f "${rc_path}" ]] || return 0
	out="$(mktemp)"
	# mawk treats /*...*/ as a regex, not a comment — never use C-style comments in awk.
	awk -v marker="${_RC_FDATASYNC_MARKER}" '
		BEGIN { hold = 0 }
		{
			if ($0 == marker) { hold = 1; next }
			if (hold) {
				hold = 0
				if ($0 ~ /^[[:space:]]*system\.files\.session\.fdatasync\.set[[:space:]]*=/) next
				print marker
			}
			print
		}
		# Trailing managed marker with no set line: already skipped via next.
	' "${rc_path}" >"${out}"
	mv -f "${out}" "${rc_path}"
}

# Ensure 0.15.x gets fdatasync=0 after session.path.set unless the user already set it.
_rc_ensure_session_fdatasync() {
	local rc_path="${1:?}" out
	[[ -f "${rc_path}" ]] || return 0
	# Active user/custom line: leave alone (including = 1).
	if grep -qE '^[[:space:]]*system\.files\.session\.fdatasync\.set[[:space:]]*=' "${rc_path}"; then
		return 0
	fi
	# Restore a previously commented managed/user line (marker form).
	if grep -qE "^[[:space:]]*#[[:space:]]*system\.files\.session\.fdatasync\.set[[:space:]]*=" "${rc_path}" \
		&& grep -qF "${_RC_FDATASYNC_MARKER}" "${rc_path}"; then
		sed -i -E "s|^([[:space:]]*)#[[:space:]]*(system\\.files\\.session\\.fdatasync\\.set[[:space:]]*=.*)|\1\2|" "${rc_path}"
		return 0
	fi
	out="$(mktemp)"
	awk -v marker="${_RC_FDATASYNC_MARKER}" -v line="${_RC_FDATASYNC_LINE}" '
		BEGIN { done = 0 }
		{
			print
			if (!done && $0 ~ /^[[:space:]]*session\.path\.set[[:space:]]*=/) {
				print marker
				print line
				done = 1
			}
		}
		END {
			if (!done) {
				print ""
				print marker
				print line
			}
		}
	' "${rc_path}" >"${out}"
	mv -f "${out}" "${rc_path}"
}

# Production defaults that keep SCGI responsive (idempotent; safe on user rcs).
# - preload type 2 blocks the event loop while touching piece data
# - debug/connection log channels flood disk under peer churn
_rc_harden_scgi_responsiveness() {
	local rc_path="${1:?}"
	[[ -f "${rc_path}" ]] || return 0
	sed -i -E \
		-e 's/^([[:space:]]*pieces\.preload\.type\.set[[:space:]]*=[[:space:]]*)2([[:space:]]*(#.*)?)?$/\10\2/' \
		-e '/^[[:space:]]*log\.add_output[[:space:]]*=[[:space:]]*"debug"[[:space:]]*,/d' \
		-e '/^[[:space:]]*log\.add_output[[:space:]]*=[[:space:]]*"connection"[[:space:]]*,/d' \
		"${rc_path}"
}

# Legacy (pre-0.16.14) → canonical 0.16.14+ syntax. Idempotent.
_rc_patch_forward() {
	local rc_path="${1:?}"
	[[ -f "${rc_path}" ]] || return 0
	# Drop removed / no-op directives (active lines only).
	sed -i \
		-e '/^[[:space:]]*encoding\.add[[:space:]]*=/d' \
		-e '/^[[:space:]]*trackers\.use_udp\.set[[:space:]]*=/d' \
		"${rc_path}"
	sed -i \
		-e 's/^[[:space:]]*schedule2[[:space:]]*=/schedule =/' \
		-e 's/^[[:space:]]*schedule_remove2[[:space:]]*=/schedule.remove =/' \
		-e 's/\bexecute2=/execute=/g' \
		-e 's/\bexecute2{/execute{/g' \
		-e 's/network\.port_range\.set/network.listen.port.range.set/g' \
		-e 's/network\.port_random\.set/network.listen.port.random.set/g' \
		-e 's/network\.http\.max_open\.set/system.sockets.http.min_alloc.set/g' \
		-e 's/network\.max_open_files\.set/system.sockets.files.min_alloc.set/g' \
		"${rc_path}"
	# Legacy global ceiling → modern max_size; drop adjust_alloc (budget math aborts startup).
	sed -i \
		-e '/^[[:space:]]*network\.max_open_sockets\.set[[:space:]]*=/d' \
		-e '/^[[:space:]]*system\.sockets\.adjust_alloc[[:space:]]*=/d' \
		"${rc_path}"
	_rc_drop_managed_fdatasync "${rc_path}"
	_rc_ensure_socket_budget "${rc_path}"
	_rc_floor_max_open "${rc_path}"
	_rc_harden_scgi_responsiveness "${rc_path}"
}

# Ensure max_size + category mins fit without adjust_alloc (default max_open is 1024).
_rc_ensure_socket_budget() {
	local rc_path="${1:?}"
	if grep -qE '^[[:space:]]*system\.sockets\.max_size\.set[[:space:]]*=' "${rc_path}"; then
		sed -i -E "s|^([[:space:]]*system\\.sockets\\.max_size\\.set[[:space:]]*=[[:space:]]*).*$|\\1${_RC_SOCKET_MAX_SIZE}|" "${rc_path}"
	elif grep -qE '^[[:space:]]*system\.sockets\.(http|files)\.min_alloc\.set[[:space:]]*=' "${rc_path}"; then
		if grep -qE '^[[:space:]]*system\.sockets\.http\.min_alloc\.set[[:space:]]*=' "${rc_path}"; then
			sed -i "/^[[:space:]]*system\\.sockets\\.http\\.min_alloc\\.set[[:space:]]*=/i system.sockets.max_size.set = ${_RC_SOCKET_MAX_SIZE}" "${rc_path}"
		else
			sed -i "/^[[:space:]]*system\\.sockets\\.files\\.min_alloc\\.set[[:space:]]*=/i system.sockets.max_size.set = ${_RC_SOCKET_MAX_SIZE}" "${rc_path}"
		fi
	fi
	if grep -qE '^[[:space:]]*system\.sockets\.files\.min_alloc\.set[[:space:]]*=' "${rc_path}"; then
		sed -i -E "s|^([[:space:]]*system\\.sockets\\.files\\.min_alloc\\.set[[:space:]]*=[[:space:]]*).*$|\\1${_RC_SOCKET_FILES_MIN_ALLOC}|" "${rc_path}"
	fi
	if grep -qE '^[[:space:]]*system\.sockets\.http\.min_alloc\.set[[:space:]]*=' "${rc_path}"; then
		sed -i -E "s|^([[:space:]]*system\\.sockets\\.http\\.min_alloc\\.set[[:space:]]*=[[:space:]]*).*$|\\1${_RC_SOCKET_HTTP_MIN_ALLOC}|" "${rc_path}"
	fi
}

# Canonical 0.16.14+ → dialect usable on 0.15.x. Idempotent.
_rc_patch_reverse() {
	local rc_path="${1:?}"
	[[ -f "${rc_path}" ]] || return 0
	# schedule.remove before schedule (so schedule.remove is not double-touched).
	sed -i \
		-e 's/^[[:space:]]*schedule\.remove[[:space:]]*=/schedule_remove2 =/' \
		-e 's/^[[:space:]]*schedule[[:space:]]*=/schedule2 =/' \
		-e 's/network\.listen\.port\.range\.set/network.port_range.set/g' \
		-e 's/network\.listen\.port\.random\.set/network.port_random.set/g' \
		-e 's/system\.sockets\.http\.min_alloc\.set/network.http.max_open.set/g' \
		-e 's/system\.sockets\.files\.min_alloc\.set/network.max_open_files.set/g' \
		-e '/^[[:space:]]*system\.sockets\.adjust_alloc[[:space:]]*=/d' \
		-e '/^[[:space:]]*system\.sockets\.max_size\.set[[:space:]]*=/d' \
		"${rc_path}"
	# execute= → execute2= without touching execute.nothrow / execute.throw / execute2.
	sed -i -E \
		-e 's/(^|[[:space:]"{,])execute=/\1execute2=/g' \
		-e 's/(^|[[:space:]"{,])execute\{/\1execute2{/g' \
		"${rc_path}"
	# Re-inject legacy directives if missing (once).
	if ! grep -qE '^[[:space:]]*encoding\.add[[:space:]]*=' "${rc_path}"; then
		sed -i '/^[[:space:]]*system\.daemon\.set[[:space:]]*=/a encoding.add = utf8' "${rc_path}"
	fi
	if ! grep -qE '^[[:space:]]*trackers\.use_udp\.set[[:space:]]*=' "${rc_path}"; then
		if grep -qE '^[[:space:]]*protocol\.pex\.set[[:space:]]*=' "${rc_path}"; then
			sed -i '/^[[:space:]]*protocol\.pex\.set[[:space:]]*=/a trackers.use_udp.set = yes' "${rc_path}"
		else
			printf '\ntrackers.use_udp.set = yes\n' >>"${rc_path}"
		fi
	fi
	# Ensure legacy socket ceilings exist after dropping adjust_alloc.
	if ! grep -qE '^[[:space:]]*network\.max_open_files\.set[[:space:]]*=' "${rc_path}"; then
		printf '\nnetwork.max_open_files.set = %s\n' "${_RC_LEGACY_MAX_OPEN_FILES}" >>"${rc_path}"
	fi
	if ! grep -qE '^[[:space:]]*network\.max_open_sockets\.set[[:space:]]*=' "${rc_path}"; then
		if grep -qE '^[[:space:]]*network\.max_open_files\.set[[:space:]]*=' "${rc_path}"; then
			sed -i "/^[[:space:]]*network\\.max_open_files\\.set[[:space:]]*=/a network.max_open_sockets.set = ${_RC_LEGACY_MAX_OPEN_SOCKETS}" "${rc_path}"
		else
			printf 'network.max_open_sockets.set = %s\n' "${_RC_LEGACY_MAX_OPEN_SOCKETS}" >>"${rc_path}"
		fi
	fi
	_rc_ensure_session_fdatasync "${rc_path}"
	_rc_floor_max_open "${rc_path}"
	_rc_harden_scgi_responsiveness "${rc_path}"
}

_rc_patch() {
	local rc_path="${1:?}" target_slot="${2:?}"
	if _rc_is_modern "${target_slot}"; then
		_rc_patch_forward "${rc_path}"
	else
		_rc_patch_reverse "${rc_path}"
	fi
}

# Apply conversion to a copy; print unified diff. Exit 0 always when dry-run succeeds.
_rc_patch_dry_run() {
	local rc_path="${1:?}" target_slot="${2:?}" port_range="${3:-}" tmp
	[[ -f "${rc_path}" ]] || {
		echo "rtorrent: rc not found: ${rc_path}" >&2
		return 1
	}
	tmp="$(mktemp)"
	cp -a "${rc_path}" "${tmp}"
	_rc_patch "${tmp}" "${target_slot}"
	[[ -n "${port_range}" ]] && _rc_sync_port_range "${tmp}" "${port_range}"
	if diff -u "${rc_path}" "${tmp}"; then
		echo "rtorrent: rc already matches dialect for ${target_slot} (no changes)" >&2
	fi
	rm -f "${tmp}"
}
