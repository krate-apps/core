#!/usr/bin/env bash
# Shared .rtorrent.rc conversion helpers (sourced by handler + bin/rtorrent-rc-convert.sh).
# shellcheck disable=SC2034
set -euo pipefail

# Canonical rc dialect threshold: schedule2/encoding.add break without -D from 0.16.14+.
_RC_MODERN_SINCE="0.16.14"
# Defaults when reverse-injecting legacy socket ceilings (aligned with LimitNOFILE=16384).
_RC_LEGACY_MAX_OPEN_FILES="4096"
_RC_LEGACY_MAX_OPEN_SOCKETS="4096"

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
	# Global socket ceiling is discouraged once category min_alloc is set — drop it.
	sed -i \
		-e '/^[[:space:]]*network\.max_open_sockets\.set[[:space:]]*=/d' \
		-e '/^[[:space:]]*system\.sockets\.max_size\.set[[:space:]]*=/d' \
		"${rc_path}"
	# Ensure adjust_alloc follows category floors when files/http mins exist.
	if grep -qE '^[[:space:]]*system\.sockets\.(http|files)\.min_alloc\.set[[:space:]]*=' "${rc_path}"; then
		if ! grep -qE '^[[:space:]]*system\.sockets\.adjust_alloc[[:space:]]*=' "${rc_path}"; then
			if grep -qE '^[[:space:]]*system\.sockets\.files\.min_alloc\.set[[:space:]]*=' "${rc_path}"; then
				sed -i '/^[[:space:]]*system\.sockets\.files\.min_alloc\.set[[:space:]]*=/a system.sockets.adjust_alloc =' "${rc_path}"
			else
				sed -i '/^[[:space:]]*system\.sockets\.http\.min_alloc\.set[[:space:]]*=/a system.sockets.adjust_alloc =' "${rc_path}"
			fi
		fi
	fi
	_rc_floor_max_open "${rc_path}"
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
	_rc_floor_max_open "${rc_path}"
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
