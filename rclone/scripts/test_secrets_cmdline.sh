#!/usr/bin/env bash
# Hygiene check: crypt/webdav helpers must not put plaintext or obscured secrets on argv.
# Run from repo: bash applications/unencrypted/apps/rclone/scripts/test_secrets_cmdline.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/rclone-cloud-lib.sh"

SECRET_PLAIN='s3cr3t-PLAIN-value-xyz'
SECRET_SALT='s3cr3t-SALT-value-xyz'
SEEN_LEAK=0

# Stub rclone binary: record argv; for "obscure -" echo a fake obscured blob from stdin.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "${STUB_DIR}"' EXIT
cat >"${STUB_DIR}/rclone" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" >"${STUB_ARGV_LOG}"
if [[ "${1:-}" == "obscure" && "${2:-}" == "-" ]]; then
	# Read stdin; emit a deterministic stand-in that must NOT later appear on argv either
	# when callers follow the conf-write path (they may still hold it in env briefly).
	cat >/dev/null
	printf 'obscured-blob-NOT-FOR-ARGV\n'
	exit 0
fi
exit 0
STUB
chmod +x "${STUB_DIR}/rclone"
export PATH="${STUB_DIR}:${PATH}"
STUB_ARGV_LOG="${STUB_DIR}/argv.log"
export STUB_ARGV_LOG

RCLONE_USER="$(id -un)"
RCLONE_HOME="${STUB_DIR}/home"
mkdir -p "${RCLONE_HOME}/.config/rclone"
RCLONE_CONF="${RCLONE_HOME}/.config/rclone/rclone.conf"
touch "${RCLONE_CONF}"

rclone_cloud::rclone_bin() { printf '%s\n' "${STUB_DIR}/rclone"; }
rclone_cloud::run_as_user() { "$@"; }

check_log_clean() {
	local label="$1"
	if [[ -f "${STUB_ARGV_LOG}" ]]; then
		if grep -a -F -e "${SECRET_PLAIN}" -e "${SECRET_SALT}" -e 'obscured-blob-NOT-FOR-ARGV' "${STUB_ARGV_LOG}" >/dev/null 2>&1; then
			echo "FAIL ${label}: secret appeared on rclone argv" >&2
			xxd "${STUB_ARGV_LOG}" >&2 || cat -v "${STUB_ARGV_LOG}" >&2
			SEEN_LEAK=1
		fi
	fi
	: >"${STUB_ARGV_LOG}"
}

# obscure_stdin itself must only pass "-" on argv
out="$(rclone_cloud::obscure_stdin "${SECRET_PLAIN}")"
[[ "${out}" == "obscured-blob-NOT-FOR-ARGV" ]] || {
	echo "FAIL obscure_stdin output: ${out}" >&2
	SEEN_LEAK=1
}
check_log_clean "obscure_stdin"

# conf upsert must not invoke rclone with secrets
python3 - <<PY | rclone_cloud::conf_upsert_section "${RCLONE_CONF}" "CryptTest"
import json
print(json.dumps({"type": "crypt", "remote": "Media:", "password": "obscured-blob-NOT-FOR-ARGV", "password2": "obscured-blob-NOT-FOR-ARGV"}))
PY
grep -q '^\[CryptTest\]' "${RCLONE_CONF}" || {
	echo "FAIL conf_upsert_section did not write section" >&2
	SEEN_LEAK=1
}
check_log_clean "conf_upsert_section"

if [[ "${SEEN_LEAK}" -ne 0 ]]; then
	echo "secrets cmdline hygiene: FAILED" >&2
	exit 1
fi
echo "secrets cmdline hygiene: ok"
