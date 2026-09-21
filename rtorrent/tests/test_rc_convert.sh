#!/usr/bin/env bash
# Smoke tests for rtorrent .rtorrent.rc conversion (forward / reverse / floor / port sync).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Prefer krate-tools assert if present; else minimal inline.
ASSERT_SH=""
for candidate in \
	"${APP_DIR}/../../../../krate-tools/scripts/tests/lib/assert.sh" \
	"/home/thomas/Dev/GitHub/Organizations/Krate/krate-tools/scripts/tests/lib/assert.sh"; do
	[[ -f "${candidate}" ]] && ASSERT_SH="${candidate}" && break
done
if [[ -n "${ASSERT_SH}" ]]; then
	# shellcheck source=/dev/null
	. "${ASSERT_SH}"
else
	assert_equals() {
		[[ "$1" == "$2" ]] || {
			echo "ASSERT FAILED: expected '$1', got '$2'${3:+ — $3}" >&2
			return 1
		}
	}
	assert_contains() {
		[[ "$1" == *"$2"* ]] || {
			echo "ASSERT FAILED: missing '$2'${3:+ — $3}" >&2
			return 1
		}
	}
	assert_status_code() {
		local expected="$1"
		shift
		local status=0
		"$@" >/dev/null 2>&1 || status=$?
		[[ "${status}" -eq "${expected}" ]] || {
			echo "ASSERT FAILED: expected exit ${expected}, got ${status}" >&2
			return 1
		}
	}
fi

# shellcheck source=../lib/rc.sh
. "${APP_DIR}/lib/rc.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILS=0

_ok() { echo "OK: $*"; }
_fail() {
	echo "FAIL: $*" >&2
	FAILS=$((FAILS + 1))
}

test_rc_is_modern_success() {
	_rc_is_modern "0.16.14" || {
		_fail "0.16.14 should be modern"
		return
	}
	_rc_is_modern "0.16.23" || {
		_fail "0.16.23 should be modern"
		return
	}
	_ok "rc_is_modern success"
}

test_rc_is_modern_failure() {
	if _rc_is_modern "0.15.7"; then
		_fail "0.15.7 should not be modern"
		return
	fi
	if _rc_is_modern "0.16.11"; then
		_fail "0.16.11 should not be modern"
		return
	fi
	_ok "rc_is_modern failure"
}

test_patch_forward_success() {
	local rc="${TMP}/fwd.rc"
	cat >"${rc}" <<'RC'
encoding.add = utf8
trackers.use_udp.set = yes
network.port_range.set = 50000-50010
network.port_random.set = yes
network.http.max_open.set = 250
network.max_open_files.set = 100
network.max_open_sockets.set = 200
schedule2 = watch_load, 11, 10, ((load.verbose, ./watch/*.torrent))
RC
	_rc_patch_forward "${rc}"
	grep -q encoding.add "${rc}" && {
		_fail "encoding.add still present"
		return
	}
	grep -q 'schedule = watch_load' "${rc}" || {
		_fail "schedule not converted"
		return
	}
	grep -q 'network.listen.port.range.set = 50000-50010' "${rc}" || {
		_fail "listen.port.range missing"
		return
	}
	grep -q 'system.sockets.http.min_alloc.set = 250' "${rc}" || {
		_fail "http min_alloc missing"
		return
	}
	grep -qE 'network\.max_open_sockets\.set|system\.sockets\.max_size\.set' "${rc}" && {
		_fail "orphan global socket ceiling still present"
		return
	}
	grep -q 'system.sockets.adjust_alloc' "${rc}" || {
		_fail "adjust_alloc not injected"
		return
	}
	_ok "patch_forward success"
}

test_patch_forward_idempotent() {
	local rc="${TMP}/fwd2.rc" a b
	cat >"${rc}" <<'RC'
network.listen.port.range.set = 50000-50010
system.sockets.http.min_alloc.set = 250
system.sockets.files.min_alloc.set = 4096
system.sockets.adjust_alloc =
schedule = watch_load, 11, 10, ((load.verbose, ./watch/*.torrent))
RC
	cp "${rc}" "${TMP}/fwd2.before"
	_rc_patch_forward "${rc}"
	_rc_patch_forward "${rc}"
	a="$(md5sum "${TMP}/fwd2.before" | awk '{print $1}')"
	b="$(md5sum "${rc}" | awk '{print $1}')"
	# First pass may inject nothing if already modern; second must be stable.
	_rc_patch_forward "${rc}"
	c="$(md5sum "${rc}" | awk '{print $1}')"
	[[ "${b}" == "${c}" ]] || {
		_fail "forward not idempotent"
		return
	}
	_ok "patch_forward idempotent"
}

test_patch_forward_failure_missing_file() {
	if _rc_patch_forward "${TMP}/does-not-exist.rc"; then
		_ok "patch_forward missing file is no-op"
	else
		_fail "patch_forward should no-op on missing file"
	fi
}

test_patch_reverse_success() {
	local rc="${TMP}/rev.rc"
	cp "${APP_DIR}/.rtorrent.rc.tpl" "${rc}"
	sed -i \
		-e 's|{{USERNAME}}|alice|g' \
		-e 's|{{PORT_RANGE}}|50000-50010|g' \
		-e 's|{{DATA_DIR}}|/d|g' \
		-e 's|{{DOWNLOADS_DIR}}|/dl|g' \
		-e 's|{{LOGS_DIR}}|/l|g' \
		-e 's|{{SESSION_DIR}}|/s|g' \
		-e 's|{{WATCH_DIR}}|/w|g' \
		"${rc}"
	_rc_patch_reverse "${rc}"
	grep -qE '^encoding\.add = utf8$' "${rc}" || {
		_fail "encoding.add not reinjected"
		return
	}
	grep -qE '^trackers\.use_udp\.set = yes$' "${rc}" || {
		_fail "use_udp not reinjected"
		return
	}
	grep -qE '^schedule2 = watch_load' "${rc}" || {
		_fail "schedule2 missing"
		return
	}
	grep -q 'network.port_range.set' "${rc}" || {
		_fail "port_range missing"
		return
	}
	grep -q 'system.sockets' "${rc}" && {
		_fail "system.sockets still present"
		return
	}
	grep -qE "^network\.max_open_sockets\.set = ${_RC_LEGACY_MAX_OPEN_SOCKETS}$" "${rc}" || {
		_fail "max_open_sockets default missing"
		return
	}
	_ok "patch_reverse success"
}

test_patch_reverse_idempotent() {
	local rc="${TMP}/rev2.rc" enc udp
	cp "${APP_DIR}/.rtorrent.rc.tpl" "${rc}"
	sed -i -e 's|{{USERNAME}}|alice|g' -e 's|{{PORT_RANGE}}|1-1|g' \
		-e 's|{{DATA_DIR}}|/d|g' -e 's|{{DOWNLOADS_DIR}}|/dl|g' \
		-e 's|{{LOGS_DIR}}|/l|g' -e 's|{{SESSION_DIR}}|/s|g' -e 's|{{WATCH_DIR}}|/w|g' "${rc}"
	_rc_patch_reverse "${rc}"
	_rc_patch_reverse "${rc}"
	enc="$(grep -cE '^[[:space:]]*encoding\.add' "${rc}" || true)"
	udp="$(grep -cE '^[[:space:]]*trackers\.use_udp' "${rc}" || true)"
	[[ "${enc}" -eq 1 && "${udp}" -eq 1 ]] || {
		_fail "reverse reinject duplicated (enc=${enc} udp=${udp})"
		return
	}
	_ok "patch_reverse idempotent"
}

test_floor_max_open_success() {
	local rc="${TMP}/floor.rc"
	printf 'network.max_open_sockets.set = 200\nnetwork.max_open_files.set = 100\n' >"${rc}"
	_rc_floor_max_open "${rc}"
	grep -q 'network.max_open_sockets.set = 512' "${rc}" || {
		_fail "sockets not floored"
		return
	}
	grep -q 'network.max_open_files.set = 512' "${rc}" || {
		_fail "files not floored"
		return
	}
	_ok "floor_max_open success"
}

test_floor_max_open_failure_leaves_http() {
	local rc="${TMP}/floor_http.rc"
	printf 'system.sockets.http.min_alloc.set = 250\n' >"${rc}"
	_rc_floor_max_open "${rc}"
	grep -q 'system.sockets.http.min_alloc.set = 250' "${rc}" || {
		_fail "http min_alloc should stay 250"
		return
	}
	_ok "floor_max_open leaves http alone"
}

test_sync_port_range_success() {
	local rc="${TMP}/port.rc"
	printf 'network.listen.port.range.set = 1000-1001\n' >"${rc}"
	_rc_sync_port_range "${rc}" "55555-55560"
	grep -q 'network.listen.port.range.set = 55555-55560' "${rc}" || {
		_fail "port not synced"
		return
	}
	_ok "sync_port_range success"
}

test_sync_port_range_failure_empty() {
	local rc="${TMP}/port2.rc"
	printf 'network.port_range.set = 1-2\n' >"${rc}"
	_rc_sync_port_range "${rc}" "" || true
	grep -q 'network.port_range.set = 1-2' "${rc}" || {
		_fail "empty port should leave file unchanged"
		return
	}
	_ok "sync_port_range empty no-op"
}

test_dialect_changed() {
	_rc_dialect_changed "0.16.11" "0.16.23" || {
		_fail "0.16.11→0.16.23 should change dialect"
		return
	}
	if _rc_dialect_changed "0.16.23" "0.16.23"; then
		_fail "same modern slot should not change dialect"
		return
	fi
	if _rc_dialect_changed "0.15.7" "0.15.7"; then
		_fail "same legacy slot should not change dialect"
		return
	fi
	_ok "dialect_changed"
}

test_rc_is_modern_success
test_rc_is_modern_failure
test_patch_forward_success
test_patch_forward_idempotent
test_patch_forward_failure_missing_file
test_patch_reverse_success
test_patch_reverse_idempotent
test_floor_max_open_success
test_floor_max_open_failure_leaves_http
test_sync_port_range_success
test_sync_port_range_failure_empty
test_dialect_changed

if [[ "${FAILS}" -ne 0 ]]; then
	echo "${FAILS} test(s) failed" >&2
	exit 1
fi
echo "All rtorrent rc conversion tests passed."
