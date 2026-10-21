#!/usr/bin/env bash
# Tests for lib/patch_ratio_groups.py (0.15.x / 0.16.x ratio group commands).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCHER="${APP_DIR}/lib/patch_ratio_groups.py"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FAILS=0

_ok() { echo "OK: $*"; }
_fail() {
	echo "FAIL: $*" >&2
	FAILS=$((FAILS + 1))
}

_make_tree() {
	local root="${1:?}"
	mkdir -p "${root}/php" "${root}/plugins/ratio"
	cat >"${root}/php/settings.php" <<'PHP'
class rTorrentSettings
{
	static private $theSettings = null;

	private $ratioCmds = array
	(
		"view",
		"view.set",
		"ratio.min",
		"ratio.min.set",
		"ratio.max",
		"ratio.max.set",
		"ratio.upload",
		"ratio.upload.set",
	);

	public function getCommand($cmd)
	{
		return($cmd);
	}
	public function getRatioGroupCommand($ratio,$cmd,$args)
	{
		// rtorrent 0.16 removed the group2.* aliases
		if($this->iVersion >= 0x1000) {
			$prefix = "group.";
		} else {
			$prefix = ($this->iVersion >= 0x904) && in_array($cmd,$this->ratioCmds) ? "group2." : "group.";
		}
		return( new rXMLRPCCommand( $prefix.$ratio.".".$cmd, $args ) );
	}
	public function getEventCommand($cmd1,$cmd2,$args)
	{
		return(null);
	}
}
PHP
	cat >"${root}/plugins/ratio/ratio.php" <<'PHP'
$req->addCommand( rTorrentSettings::get()->getRatioGroupCommand("rat_".$i,'ratio.enable',array("")) );
$req->addCommand( rTorrentSettings::get()->getRatioGroupCommand("rat_".$i,'ratio.min.set',array("",$rat["min"])) );
$req->addCommand( rTorrentSettings::get()->getRatioGroupCommand("rat_".$i,'ratio.max.set',array("",$rat["max"])) );
$req->addCommand( rTorrentSettings::get()->getRatioGroupCommand("rat_".$i,'ratio.upload.set',array("",floatval($rat["upload"]*1024*1024*1024))) );
PHP
}

test_patch_legacy_group2_success() {
	local root="${TMP}/legacy"
	_make_tree "${root}"
	python3 "${PATCHER}" "${root}" >/dev/null
	grep -q 'array_unshift($args, "")' "${root}/php/settings.php" || {
		_fail "settings helper missing array_unshift"
		return
	}
	grep -q 'rXMLRPCCommand( "group.".$ratio.".".$cmd, $args )' "${root}/php/settings.php" || {
		_fail "settings helper still uses prefix variable"
		return
	}
	! grep -qE '\$prefix.*"group2' "${root}/php/settings.php" || {
		_fail "group2 prefix selection still present in settings.php"
		return
	}
	! grep -q 'ratioCmds' "${root}/php/settings.php" || {
		_fail "ratioCmds whitelist still present"
		return
	}
	if grep -qF 'array("",$rat["min"])' "${root}/plugins/ratio/ratio.php"; then
		_fail "ratio.php still uses array(\"\", value) for min.set"
		return
	fi
	_ok "patch legacy group2 success"
}

test_patch_idempotent() {
	local root="${TMP}/idem"
	_make_tree "${root}"
	python3 "${PATCHER}" "${root}" >/dev/null
	cp "${root}/php/settings.php" "${TMP}/settings.after"
	cp "${root}/plugins/ratio/ratio.php" "${TMP}/ratio.after"
	python3 "${PATCHER}" "${root}" >/dev/null
	diff -q "${TMP}/settings.after" "${root}/php/settings.php" >/dev/null || {
		_fail "second patch changed settings.php"
		return
	}
	diff -q "${TMP}/ratio.after" "${root}/plugins/ratio/ratio.php" >/dev/null || {
		_fail "second patch changed ratio.php"
		return
	}
	_ok "patch idempotent"
}

test_patch_missing_settings_failure() {
	local root="${TMP}/missing"
	mkdir -p "${root}/plugins/ratio"
	if python3 "${PATCHER}" "${root}" >/dev/null 2>&1; then
		_fail "missing settings.php should fail"
		return
	fi
	_ok "patch missing settings failure"
}

test_patch_legacy_group2_success
test_patch_idempotent
test_patch_missing_settings_failure

if [[ "${FAILS}" -ne 0 ]]; then
	echo "${FAILS} test(s) failed" >&2
	exit 1
fi
echo "All rutorrent ratio-group patch tests passed."
