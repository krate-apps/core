#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2154,SC1091
# rclone cloud management CLI (JSON stdout). Used by `zen rclone` + Harmony API.
set -euo pipefail

CTL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rclone-cloud-lib.sh
source "${CTL_DIR}/rclone-cloud-lib.sh"
# shellcheck source=rclone-cloud-setup.sh
source "${CTL_DIR}/rclone-cloud-setup.sh"

rclone_ctl::json_escape() {
	python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()[:-1] if False else sys.argv[1]))' "$1" 2>/dev/null \
		|| printf '"%s"' "${1//\"/\\\"}"
}

rclone_ctl::emit() {
	python3 - "$@" <<'PY'
import json, sys
print(json.dumps(json.loads(sys.argv[1]), ensure_ascii=False))
PY
}

rclone_ctl::fail() {
	local msg="$1"
	local code="${2:-1}"
	printf '{"ok":false,"error":%s}\n' "$(rclone_ctl::json_escape "${msg}")"
	exit "${code}"
}

rclone_ctl::unit_active() {
	systemctl is-active --quiet "$1" 2>/dev/null && echo active || echo inactive
}

rclone_ctl::remote_has_token() {
	# Ready when OAuth/SA/S3/WebDAV/crypt/alias fields are present.
	local conf="$1" remote="$2"
	python3 - "$conf" "$remote" <<'PY'
import sys
conf, remote = sys.argv[1], sys.argv[2]
section = None
keys = set()
try:
    with open(conf, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1]
                continue
            if section != remote or "=" not in line:
                continue
            k = line.split("=", 1)[0].strip().lower()
            keys.add(k)
except FileNotFoundError:
    pass
ok = bool(keys & {
    "token",
    "service_account_file",
    "service_account_credentials",
    "access_key_id",
    "url",
    "password",
    "password2",
    "remote",  # crypt / alias point at another remote
})
print("1" if ok else "0")
PY
}

rclone_ctl::list_remotes() {
	local conf="$1"
	python3 - "$conf" <<'PY'
import sys
conf = sys.argv[1]
names = []
try:
    with open(conf, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                names.append(line[1:-1])
except FileNotFoundError:
    pass
print("\n".join(names))
PY
}

rclone_ctl::provider_type() {
	rclone_cloud::provider_backend "${1}"
}

rclone_ctl::oauth_needs_browser() {
	case "${1}" in
	drive | dropbox | onedrive) return 0 ;;
	*) return 1 ;;
	esac
}

rclone_ctl::status() {
	local user="${1:?}"
	shift
	local quick=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--quick) quick=1; shift ;;
		*) shift ;;
		esac
	done
	rclone_cloud::parse_instance "${user}"
	rclone_cloud::migrate_layout "${user}" 2>/dev/null || true
	local conf="${RCLONE_CONF}"
	local profile="${RCLONE_PROFILE}"
	local remotes=()
	local r
	while IFS= read -r r; do
		[[ -n "${r}" ]] && remotes+=("${r}")
	done < <(rclone_ctl::list_remotes "${conf}")

	local primary=""
	local primary_branch="main"
	local media_cloud_branch="main"
	local preset="media" mode="import" provider="import" drive_root="mydrive"
	local move_dest="" move_min_age="30m" move_bwlimit="" move_enabled="0" tps="12"
	if [[ -f "${profile}" ]]; then
		# shellcheck source=/dev/null
		set -a && source "${profile}" && set +a
		preset="${RCLONE_PRESET:-media}"
		mode="${RCLONE_MODE:-import}"
		provider="${RCLONE_PROVIDER:-import}"
		drive_root="${RCLONE_DRIVE_ROOT:-mydrive}"
		move_dest="${RCLONE_MOVE_DEST:-}"
		move_min_age="${RCLONE_MOVE_MIN_AGE:-30m}"
		move_bwlimit="${RCLONE_MOVE_BWLIMIT:-}"
		move_enabled="${RCLONE_MOVE_ENABLED:-0}"
		tps="${RCLONE_TPSLIMIT:-12}"
		primary_branch="$(rclone_cloud::primary_branch)"
		media_cloud_branch="${RCLONE_MEDIA_CLOUD_BRANCH:-${primary_branch}}"
		case "${media_cloud_branch}" in
		remote) media_cloud_branch="main" ;;
		esac
	fi
	if [[ -f "${RCLONE_STATE_DIR}/mounts/${primary_branch}.env" ]]; then
		# shellcheck source=/dev/null
		set -a && source "${RCLONE_STATE_DIR}/mounts/${primary_branch}.env" && set +a
		primary="${RCLONE_REMOTE_SPEC%%:*}"
	elif [[ -f "${RCLONE_STATE_DIR}/mounts/main.env" ]]; then
		# shellcheck source=/dev/null
		set -a && source "${RCLONE_STATE_DIR}/mounts/main.env" && set +a
		primary="${RCLONE_REMOTE_SPEC%%:*}"
	fi
	[[ -n "${primary}" ]] || primary="${move_dest%%:*}"
	[[ -n "${primary}" ]] || primary="Media"

	local oauth_ready="0"
	if [[ -f "${conf}" ]] && grep -q "^\[${primary}\]" "${conf}" 2>/dev/null; then
		oauth_ready="$(rclone_ctl::remote_has_token "${conf}" "${primary}")"
		# Non-OAuth remotes (s3/webdav) or crypt: section presence is enough
		if [[ "${oauth_ready}" != "1" ]]; then
			local typ
			typ="$(python3 - "${conf}" "${primary}" <<'PY'
import sys
conf, remote = sys.argv[1], sys.argv[2]
section=None
typ=""
with open(conf, encoding="utf-8") as f:
    for line in f:
        line=line.strip()
        if line.startswith("[") and line.endswith("]"):
            section=line[1:-1]; continue
        if section==remote and line.lower().startswith("type"):
            typ=line.split("=",1)[-1].strip(); break
print(typ)
PY
)"
			case "${typ}" in
			s3 | webdav | crypt | local | alias) oauth_ready="1" ;;
			esac
		fi
		# Password / key remotes: profile provider alone is not enough; conf section must exist (above).
		if [[ "${oauth_ready}" != "1" && -f "${conf}" ]] && grep -q "^\[${primary}\]" "${conf}" 2>/dev/null; then
			case "${provider}" in
			kdrive | webdav | s3 | import) oauth_ready="1" ;;
			esac
		fi
	fi

	local branches_json="["
	local first=1
	local f b mount_path is_primary
	for f in "${RCLONE_STATE_DIR}/mounts"/*.env; do
		[[ -f "${f}" ]] || continue
		b="$(basename "${f}" .env)"
		[[ "${b}" == "main" ]] && continue
		# Dedicated views are listed separately.
		if grep -q '^RCLONE_VIEW_MODE=1' "${f}" 2>/dev/null; then
			continue
		fi
		[[ "${first}" -eq 1 ]] || branches_json+=","
		first=0
		# shellcheck source=/dev/null
		set -a && source "${f}" && set +a
		mount_path="$(rclone_cloud::remote_mount_path "${RCLONE_HOME}" "${b}")"
		is_primary="false"
		[[ "${b}" == "${primary_branch}" ]] && is_primary="true"
		branches_json+=$(printf '{"id":%s,"remote_spec":%s,"unit":%s,"mount_path":%s,"primary":%s}' \
			"$(rclone_ctl::json_escape "${b}")" \
			"$(rclone_ctl::json_escape "${RCLONE_REMOTE_SPEC:-}")" \
			"$(rclone_ctl::json_escape "rclone-mount@${user}--${b}.service")" \
			"$(rclone_ctl::json_escape "${mount_path}")" \
			"${is_primary}")
	done
	branches_json+="]"

	local remotes_json="["
	first=1
	for r in "${remotes[@]+"${remotes[@]}"}"; do
		[[ "${first}" -eq 1 ]] || remotes_json+=","
		first=0
		local has_tok
		has_tok="$(rclone_ctl::remote_has_token "${conf}" "${r}")"
		remotes_json+=$(printf '{"name":%s,"has_token":%s}' \
			"$(rclone_ctl::json_escape "${r}")" \
			"$([ "${has_tok}" = 1 ] && echo true || echo false)")
	done
	remotes_json+="]"

	local move_log="${RCLONE_LOG_DIR}/move.log"
	local move_log_tail=""
	if [[ -f "${move_log}" ]]; then
		move_log_tail="$(tail -n 40 "${move_log}" 2>/dev/null || true)"
	fi

	local pending="false"
	[[ -f "${RCLONE_STATE_DIR}/oauth-pending.json" ]] && pending="true"

	local move_on_calendar="${RCLONE_MOVE_ON_CALENDAR:-}"
	local move_on_unit="${RCLONE_MOVE_ON_UNIT_ACTIVE:-30min}"
	local move_on_boot="${RCLONE_MOVE_ON_BOOT:-15min}"

	local views_json="["
	first=1
	for f in "${RCLONE_STATE_DIR}/views"/*.env; do
		[[ -f "${f}" ]] || continue
		b="$(basename "${f}" .env)"
		[[ "${first}" -eq 1 ]] || views_json+=","
		first=0
		# shellcheck source=/dev/null
		set -a && source "${f}" && set +a
		views_json+=$(printf '{"id":%s,"path":%s,"unit":%s}' \
			"$(rclone_ctl::json_escape "${b}")" \
			"$(rclone_ctl::json_escape "${RCLONE_HOME}/mounts/views/${b}")" \
			"$(rclone_ctl::json_escape "mergerfs-media@${user}--${b}.service")")
	done
	views_json+="]"

	# Health probes (best-effort). --quick skips rclone about (for alerts).
	local health_json
	health_json="$(
		if [[ "${quick}" -eq 1 ]]; then export RCLONE_STATUS_QUICK=1; else unset RCLONE_STATUS_QUICK || true; fi
		python3 - "${RCLONE_CACHE}" "${move_log}" "${conf}" "${primary}" "$(rclone_cloud::rclone_bin)" "${user}" <<'PY'
import json, os, re, shutil, subprocess, sys
cache, move_log, conf, primary, rclone_bin, user = sys.argv[1:7]
out = {
  "cache": {"path": cache, "exists": os.path.isdir(cache)},
  "about": None,
  "move_errors": [],
  "move_error_count": 0,
}
try:
    usage = shutil.disk_usage(cache if os.path.isdir(cache) else os.path.dirname(cache) or "/")
    out["cache"].update({
        "total_bytes": usage.total,
        "used_bytes": usage.used,
        "free_bytes": usage.free,
        "used_pct": round(100.0 * usage.used / usage.total, 1) if usage.total else None,
    })
except Exception as e:
    out["cache"]["error"] = str(e)
errs = []
try:
    with open(move_log, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()[-200:]
    for line in lines:
        if re.search(r"\b(ERROR|CRITICAL|Failed|error:)\b", line, re.I):
            errs.append(line.rstrip()[-300:])
except FileNotFoundError:
    pass
out["move_errors"] = errs[-10:]
out["move_error_count"] = len(errs)
if primary and os.path.isfile(rclone_bin) and os.path.isfile(conf) and os.environ.get("RCLONE_STATUS_QUICK") != "1":
    try:
        p = subprocess.run(
            ["runuser", "-u", user, "--", rclone_bin, "about", f"{primary}:", "--config", conf, "--json"],
            capture_output=True, text=True, timeout=20,
        )
        if p.returncode == 0 and p.stdout.strip():
            out["about"] = json.loads(p.stdout)
        elif p.stderr:
            out["about_error"] = p.stderr.strip()[-400:]
    except Exception as e:
        out["about_error"] = str(e)
print(json.dumps(out, ensure_ascii=False))
PY
	)"

	local health_file
	health_file="$(mktemp)"
	printf '%s' "${health_json}" >"${health_file}"

	# Nested remotes/branches/views are JSON; load them via json.loads so JSON
	# true/false are not evaluated as Python identifiers (NameError: false).
	python3 - "${health_file}" <<PY
import json, sys
health = json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps({
  "ok": True,
  "user": $(rclone_ctl::json_escape "${user}"),
  "preset": $(rclone_ctl::json_escape "${preset}"),
  "mode": $(rclone_ctl::json_escape "${mode}"),
  "provider": $(rclone_ctl::json_escape "${provider}"),
  "drive_root": $(rclone_ctl::json_escape "${drive_root}"),
  "primary_remote": $(rclone_ctl::json_escape "${primary}"),
  "primary_branch": $(rclone_ctl::json_escape "${primary_branch}"),
  "media_cloud_branch": $(rclone_ctl::json_escape "${media_cloud_branch}"),
  "oauth_ready": ${oauth_ready} == 1,
  "oauth_pending": json.loads("${pending}"),
  "move": {
    "enabled": json.loads("$( [[ "${move_enabled}" == "1" ]] && echo true || echo false )"),
    "dest": $(rclone_ctl::json_escape "${move_dest}"),
    "min_age": $(rclone_ctl::json_escape "${move_min_age}"),
    "bwlimit": $(rclone_ctl::json_escape "${move_bwlimit}"),
    "tpslimit": $(rclone_ctl::json_escape "${tps}"),
    "on_calendar": $(rclone_ctl::json_escape "${move_on_calendar}"),
    "on_unit_active": $(rclone_ctl::json_escape "${move_on_unit}"),
    "on_boot": $(rclone_ctl::json_escape "${move_on_boot}"),
  },
  "units": {
    "app": $(rclone_ctl::json_escape "$(rclone_ctl::unit_active "rclone@${user}.service")"),
    "mount": $(rclone_ctl::json_escape "$(rclone_ctl::unit_active "rclone-mount@${user}.service")"),
    "mergerfs_media": $(rclone_ctl::json_escape "$(rclone_ctl::unit_active "mergerfs-media@${user}.service")"),
    "mergerfs_union": $(rclone_ctl::json_escape "$(rclone_ctl::unit_active "mergerfs-union@${user}.service")"),
    "move_timer": $(rclone_ctl::json_escape "$(rclone_ctl::unit_active "rclone-move@${user}.timer")"),
  },
  "remotes": json.loads($(rclone_ctl::json_escape "${remotes_json}")),
  "branches": json.loads($(rclone_ctl::json_escape "${branches_json}")),
  "views": json.loads($(rclone_ctl::json_escape "${views_json}")),
  "health": health,
  "paths": {
    "remote": $(rclone_ctl::json_escape "${RCLONE_HOME}/mounts/remote"),
    "remote_primary": $(rclone_ctl::json_escape "$(rclone_cloud::remote_mount_path "${RCLONE_HOME}" "${primary_branch}")"),
    "cache": $(rclone_ctl::json_escape "${RCLONE_CACHE}"),
    "media": $(rclone_ctl::json_escape "${RCLONE_MEDIA}"),
    "union": $(rclone_ctl::json_escape "${RCLONE_UNION}"),
    "views": $(rclone_ctl::json_escape "${RCLONE_HOME}/mounts/views"),
    "conf": $(rclone_ctl::json_escape "${conf}"),
  },
  "logs": {
    "move_tail": $(rclone_ctl::json_escape "${move_log_tail}"),
  },
  "manage_ui": "Harmony Manage cloud / zen rclone — no rcd web GUI",
}, ensure_ascii=False))
PY
	rm -f "${health_file}"
}

rclone_ctl::apply() {
	local user="${1:?}"
	shift
	local preset="media" mode="import" provider="import" remote="Media"
	local remote_set=0 provider_set=0
	local team_drive="" drive_root="mydrive"
	local move_dest="" move_min_age="" move_bwlimit="" move_enabled=""
	local on_calendar="" on_unit_active="" on_boot=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--preset) preset="${2:-}"; shift 2 ;;
		--mode) mode="${2:-}"; shift 2 ;;
		--provider) provider="${2:-}"; provider_set=1; shift 2 ;;
		--remote) remote="${2:-}"; remote_set=1; shift 2 ;;
		--team-drive) team_drive="${2:-}"; shift 2 ;;
		--drive-root) drive_root="${2:-}"; shift 2 ;;
		--move-dest) move_dest="${2:-}"; shift 2 ;;
		--move-min-age) move_min_age="${2:-}"; shift 2 ;;
		--bwlimit) move_bwlimit="${2:-}"; shift 2 ;;
		--move-enabled) move_enabled="${2:-}"; shift 2 ;;
		--on-calendar) on_calendar="${2:-}"; shift 2 ;;
		--on-unit-active) on_unit_active="${2:-}"; shift 2 ;;
		--on-boot) on_boot="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	preset="media"
	# Always refresh /usr/lib/krate/rclone scripts first.
	rclone_cloud_setup::install_files

	# Bare `apply` (no --remote) must not reset a working stack to the Media default.
	local home="/home/${user}"
	local state="${home}/.krate/applications/rclone-cloud"
	local conf="${home}/.config/rclone/rclone.conf"
	if [[ "${remote_set}" -eq 0 || "${provider_set}" -eq 0 ]]; then
		local existing_spec="" existing_prov=""
		if [[ -f "${state}/mounts/main.env" ]]; then
			# shellcheck source=/dev/null
			set -a && source "${state}/mounts/main.env" && set +a
			existing_spec="${RCLONE_REMOTE_SPEC:-}"
			existing_prov="${RCLONE_PROVIDER:-}"
		fi
		if [[ -z "${existing_spec}" && -f "${state}/profile.env" ]]; then
			# shellcheck source=/dev/null
			set -a && source "${state}/profile.env" && set +a
			existing_spec="${RCLONE_MOVE_DEST:-}"
			[[ -n "${existing_prov}" ]] || existing_prov="${RCLONE_PROVIDER:-}"
		fi
		if [[ "${remote_set}" -eq 0 ]]; then
			remote="${existing_spec%%:*}"
			[[ -n "${remote}" ]] || remote="Media"
		fi
		if [[ "${provider_set}" -eq 0 && -n "${existing_prov}" ]]; then
			provider="${existing_prov}"
		fi
	fi
	# If chosen remote is missing from conf, prefer crypt then first usable section.
	if [[ -f "${conf}" ]] && ! grep -qE "^\[${remote}\]$" "${conf}" 2>/dev/null; then
		local picked
		picked="$(python3 - "${conf}" <<'PY'
import sys
conf = sys.argv[1]
sections, cur, meta = [], None, {}
try:
    with open(conf, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("[") and line.endswith("]"):
                cur = line[1:-1]
                sections.append(cur)
                meta[cur] = {"type": "", "url": ""}
                continue
            if cur is None or "=" not in line or line.startswith("#"):
                continue
            k, v = line.split("=", 1)
            k, v = k.strip().lower(), v.strip()
            if k == "type":
                meta[cur]["type"] = v.lower()
            elif k == "url":
                meta[cur]["url"] = v
except FileNotFoundError:
    pass

def score(name):
    t = meta.get(name, {}).get("type", "")
    if t == "alias":
        return -1
    if t == "crypt":
        return 100
    if t in ("webdav", "drive", "dropbox", "onedrive", "s3"):
        return 50
    return 10

cands = [n for n in sections if score(n) >= 0]
cands.sort(key=lambda n: (-score(n), n))
print(cands[0] if cands else "")
PY
)"
		if [[ -n "${picked}" ]]; then
			remote="${picked}"
			if [[ "${provider_set}" -eq 0 ]]; then
				local rtype typ url
				rtype="$(python3 - "${conf}" "${picked}" <<'PY'
import sys
conf, remote = sys.argv[1], sys.argv[2]
section = typ = url = ""
with open(conf, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]; continue
        if section != remote or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip().lower(), v.strip()
        if k == "type":
            typ = v.lower()
        elif k == "url":
            url = v
print(f"{typ}\t{url}")
PY
)"
				typ="${rtype%%$'\t'*}"
				url="${rtype#*$'\t'}"
				case "${typ}" in
				crypt) provider="crypt" ;;
				webdav)
					if [[ "${url}" == *kdrive* || "${url}" == *infomaniak* ]]; then
						provider="kdrive"
					else
						provider="webdav"
					fi
					;;
				drive | dropbox | s3 | onedrive) provider="${typ}" ;;
				*) provider="import" ;;
				esac
			fi
			[[ -n "${move_dest}" ]] || move_dest="${picked}:"
		fi
	fi

	rclone_cloud_setup::apply_user "${user}" "${preset}" "${mode}" "${provider}" "${remote}" "${team_drive}" "${drive_root}"
	local profile="${state}/profile.env"
	_profile_set() {
		local k="$1" v="$2"
		[[ -n "${v}" ]] || return 0
		if grep -q "^${k}=" "${profile}" 2>/dev/null; then
			sed -i "s|^${k}=.*|${k}=${v}|" "${profile}"
		else
			echo "${k}=${v}" >>"${profile}"
		fi
	}
	_profile_set RCLONE_MOVE_DEST "${move_dest}"
	_profile_set RCLONE_MOVE_MIN_AGE "${move_min_age}"
	_profile_set RCLONE_MOVE_BWLIMIT "${move_bwlimit}"
	_profile_set RCLONE_MOVE_ENABLED "${move_enabled}"
	_profile_set RCLONE_MOVE_ON_CALENDAR "${on_calendar}"
	_profile_set RCLONE_MOVE_ON_UNIT_ACTIVE "${on_unit_active}"
	_profile_set RCLONE_MOVE_ON_BOOT "${on_boot}"
	chown "${user}:${user}" "${profile}" 2>/dev/null || true
	if [[ -n "${on_calendar}${on_unit_active}${on_boot}" ]]; then
		rclone_ctl::write_move_timer_dropin "${user}" \
			"${on_calendar:-}" "${on_unit_active:-30min}" "${on_boot:-15min}"
	fi
	rclone_ctl::status "${user}"
}

rclone_ctl::write_move_timer_dropin() {
	local user="$1" cal="$2" unit_active="$3" boot="$4"
	local drop="/etc/systemd/system/rclone-move@${user}.timer.d"
	install -d -m 0755 "${drop}"
	{
		echo "[Timer]"
		echo "Persistent=true"
		if [[ -n "${cal}" ]]; then
			echo "OnCalendar=${cal}"
			echo "OnBootSec="
			echo "OnUnitActiveSec="
		else
			echo "OnCalendar="
			echo "OnBootSec=${boot:-15min}"
			echo "OnUnitActiveSec=${unit_active:-30min}"
		fi
	} >"${drop}/override.conf"
	systemctl daemon-reload
	systemctl restart "rclone-move@${user}.timer" 2>/dev/null || systemctl start "rclone-move@${user}.timer" 2>/dev/null || true
}

rclone_ctl::oauth_continue_loop() {
	local user="$1" remote="$2" rtype="$3"
	shift 3
	local -a extra=("$@")
	rclone_cloud::parse_instance "${user}"
	local bin conf state result out pending
	bin="$(rclone_cloud::rclone_bin)"
	conf="${RCLONE_CONF}"
	pending="${RCLONE_STATE_DIR}/oauth-pending.json"
	install -d -m 0755 -o "${user}" -g "${user}" "${RCLONE_STATE_DIR}"

	state=""
	result=""
	local guard=0
	while [[ "${guard}" -lt 24 ]]; do
		guard=$((guard + 1))
		local -a cmd=("${bin}" config create "${remote}" "${rtype}" --non-interactive --config="${conf}")
		if [[ -n "${state}" ]]; then
			cmd+=(--continue --state "${state}" --result "${result}")
		else
			cmd+=("${extra[@]}")
		fi
		set +e
		out="$(rclone_cloud::run_as_user "${cmd[@]}" 2>&1)"
		local rc=$?
		set -e
		# Finished successfully (empty State or remote created)
		if echo "${out}" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d.get("State") else 1)' 2>/dev/null; then
			rm -f "${pending}"
			printf '%s\n' "${out}"
			return 0
		fi
		# Parse question blob
		local parsed
		parsed="$(echo "${out}" | python3 -c '
import json,sys
raw=sys.stdin.read()
# rclone may print NOTICE lines before JSON
start=raw.find("{")
if start<0:
    print(json.dumps({"error": raw[-2000:]})); sys.exit(0)
d=json.loads(raw[start:])
print(json.dumps(d))
' 2>/dev/null || true)"
		[[ -n "${parsed}" ]] || {
			# Maybe already exists / non-JSON success
			if grep -q "^\[${remote}\]" "${conf}" 2>/dev/null; then
				rm -f "${pending}"
				echo '{"State":"","ok":true}'
				return 0
			fi
			rclone_ctl::fail "oauth create failed: ${out:0:500}"
		}
		local opt_name
		opt_name="$(echo "${parsed}" | python3 -c 'import json,sys; d=json.load(sys.stdin); o=d.get("Option") or {}; print(o.get("Name") or "")')"
		state="$(echo "${parsed}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("State") or "")')"
		if [[ -z "${state}" ]]; then
			rm -f "${pending}"
			echo "${parsed}"
			return 0
		fi
		case "${opt_name}" in
		config_is_local)
			result="false"
			continue
			;;
		config_token | token)
			echo "${parsed}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['ok']=True
d['needs_token']=True
d['authorize_cmd']=f'rclone authorize \"${rtype}\"'
d['remote']='${remote}'
d['provider']='${rtype}'
print(json.dumps(d, ensure_ascii=False))
" >"${pending}"
			chown "${user}:${user}" "${pending}"
			chmod 0600 "${pending}"
			cat "${pending}"
			return 0
			;;
		team_drive | drive_root)
			# Prefer empty / already set via extra kwargs; take default
			result="$(echo "${parsed}" | python3 -c 'import json,sys; d=json.load(sys.stdin); o=d.get("Option") or {}; print(o.get("Default") if o.get("Default") is not None else "")')"
			continue
			;;
		*)
			# Take default when possible
			result="$(echo "${parsed}" | python3 -c 'import json,sys; d=json.load(sys.stdin); o=d.get("Option") or {}; v=o.get("Default"); print("" if v is None else v)')"
			continue
			;;
		esac
	done
	rclone_ctl::fail "oauth flow exceeded iteration limit"
}

rclone_ctl::oauth_begin() {
	local user="${1:?}"
	shift
	local remote="Media" provider="drive" team_drive="" drive_root="mydrive"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--remote) remote="${2:-}"; shift 2 ;;
		--provider) provider="${2:-}"; shift 2 ;;
		--team-drive) team_drive="${2:-}"; shift 2 ;;
		--drive-root) drive_root="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	local rtype
	rtype="$(rclone_ctl::provider_type "${provider}")"
	rclone_cloud::parse_instance "${user}"
	[[ -x "$(rclone_cloud::rclone_bin)" ]] || rclone_ctl::fail "rclone binary missing for ${user}"

	local -a extra=(config_is_local=false)
	if [[ "${rtype}" == "drive" ]]; then
		extra+=(scope=drive)
		if [[ "${drive_root}" == "shared" && -n "${team_drive}" ]]; then
			extra+=("team_drive=${team_drive}")
		elif [[ -n "${team_drive}" ]]; then
			extra+=("team_drive=${team_drive}")
		fi
	fi

	# Remove incomplete remote section without token so create can redo
	if [[ -f "${RCLONE_CONF}" ]] && grep -q "^\[${remote}\]" "${RCLONE_CONF}"; then
		if [[ "$(rclone_ctl::remote_has_token "${RCLONE_CONF}" "${remote}")" == "1" ]]; then
			python3 - <<PY
import json
print(json.dumps({"ok": True, "already_configured": True, "remote": "${remote}", "needs_token": False}))
PY
			return 0
		fi
	fi

	if ! rclone_ctl::oauth_needs_browser "${rtype}"; then
		# Non-browser providers: create with provided extras only (may still ask questions)
		rclone_ctl::oauth_continue_loop "${user}" "${remote}" "${rtype}" "${extra[@]}"
		return
	fi

	local out
	out="$(rclone_ctl::oauth_continue_loop "${user}" "${remote}" "${rtype}" "${extra[@]}")"
	echo "${out}"
}

rclone_ctl::oauth_complete() {
	local user="${1:?}"
	shift
	local remote="" token=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--remote) remote="${2:-}"; shift 2 ;;
		--token) token="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	rclone_cloud::parse_instance "${user}"
	local pending="${RCLONE_STATE_DIR}/oauth-pending.json"
	[[ -f "${pending}" ]] || rclone_ctl::fail "no oauth pending; run oauth-begin first"
	[[ -n "${token}" ]] || rclone_ctl::fail "missing --token (paste output of: rclone authorize …)"

	local state rtype
	state="$(python3 -c 'import json; print(json.load(open("'"${pending}"'")).get("State") or "")')"
	rtype="$(python3 -c 'import json; print(json.load(open("'"${pending}"'")).get("provider") or "drive")')"
	remote="${remote:-$(python3 -c 'import json; print(json.load(open("'"${pending}"'")).get("remote") or "Media")')}"

	local bin conf out
	bin="$(rclone_cloud::rclone_bin)"
	conf="${RCLONE_CONF}"
	set +e
	out="$(rclone_cloud::run_as_user "${bin}" config create "${remote}" "${rtype}" --non-interactive \
		--continue --state "${state}" --result "${token}" --config="${conf}" 2>&1)"
	local rc=$?
	set -e

	# May need further default answers
	local guard=0
	local cur_state cur_result parsed opt_name
	while [[ "${guard}" -lt 16 ]]; do
		guard=$((guard + 1))
		parsed="$(echo "${out}" | python3 -c '
import json,sys
raw=sys.stdin.read()
start=raw.find("{")
if start<0:
    print(""); raise SystemExit
print(json.dumps(json.loads(raw[start:])))
' 2>/dev/null || true)"
		if [[ -z "${parsed}" ]]; then
			break
		fi
		cur_state="$(echo "${parsed}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("State") or "")')"
		if [[ -z "${cur_state}" ]]; then
			break
		fi
		opt_name="$(echo "${parsed}" | python3 -c 'import json,sys; d=json.load(sys.stdin); o=d.get("Option") or {}; print(o.get("Name") or "")')"
		if [[ "${opt_name}" == "config_token" || "${opt_name}" == "token" ]]; then
			rclone_ctl::fail "token rejected or still required"
		fi
		cur_result="$(echo "${parsed}" | python3 -c 'import json,sys; d=json.load(sys.stdin); o=d.get("Option") or {}; v=o.get("Default"); print("" if v is None else v)')"
		set +e
		out="$(rclone_cloud::run_as_user "${bin}" config create "${remote}" "${rtype}" --non-interactive \
			--continue --state "${cur_state}" --result "${cur_result}" --config="${conf}" 2>&1)"
		set -e
	done

	rm -f "${pending}"
	# Restart mounts if profile exists
	if [[ -f "${RCLONE_PROFILE}" ]]; then
		# shellcheck source=/dev/null
		set -a && source "${RCLONE_PROFILE}" && set +a
		systemctl restart "rclone-mount@${user}.service" || true
		systemctl restart "mergerfs-media@${user}.service" || true
		systemctl start "rclone-move@${user}.timer" || true
	fi
	python3 - <<PY
import json
print(json.dumps({"ok": True, "remote": "${remote}", "oauth_ready": True, "rc": ${rc}}))
PY
}

rclone_ctl::list_drives() {
	local user="${1:?}"
	shift
	local remote="Media"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--remote) remote="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	rclone_cloud::parse_instance "${user}"
	local bin
	bin="$(rclone_cloud::rclone_bin)"
	[[ "$(rclone_ctl::remote_has_token "${RCLONE_CONF}" "${remote}")" == "1" ]] \
		|| rclone_ctl::fail "remote ${remote} is not authenticated yet"

	local tmp
	tmp="$(mktemp)"
	set +e
	rclone_cloud::run_as_user "${bin}" backend drives "${remote}:" --config="${RCLONE_CONF}" >"${tmp}" 2>"${tmp}.err"
	local rc=$?
	set -e
	if [[ "${rc}" -ne 0 ]]; then
		local err
		err="$(head -c 400 "${tmp}.err" 2>/dev/null || true)"
		rm -f "${tmp}" "${tmp}.err"
		rclone_ctl::fail "list drives failed: ${err}"
	fi
	python3 - "${tmp}" "${remote}" <<'PY'
import json, sys
path, remote = sys.argv[1], sys.argv[2]
raw = open(path, encoding="utf-8", errors="replace").read()
drives = []
# Try whole document first, then line-delimited JSON
try:
    obj = json.loads(raw)
    if isinstance(obj, list):
        drives = obj
    elif isinstance(obj, dict):
        drives = [obj]
except Exception:
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, list):
            drives.extend(obj)
        elif isinstance(obj, dict):
            drives.append(obj)
print(json.dumps({"ok": True, "remote": remote, "drives": drives}, ensure_ascii=False))
PY
	rm -f "${tmp}" "${tmp}.err"
}

rclone_ctl::crypt_create() {
	local user="${1:?}"
	shift
	local crypt_name="" underlying="" password="" password2="" set_primary="0"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--crypt-name) crypt_name="${2:-}"; shift 2 ;;
		--remote) underlying="${2:-}"; shift 2 ;;
		--password) password="${2:-}"; shift 2 ;;
		--password2) password2="${2:-}"; shift 2 ;;
		--set-primary) set_primary="1"; shift ;;
		*) shift ;;
		esac
	done
	[[ -n "${crypt_name}" && -n "${underlying}" && -n "${password}" ]] \
		|| rclone_ctl::fail "crypt-create requires --crypt-name --remote --password"
	: "${password2:=${password}}"
	rclone_cloud::parse_instance "${user}"
	local bin
	bin="$(rclone_cloud::rclone_bin)"
	local remote_path="${underlying}"
	[[ "${remote_path}" == *: ]] || [[ "${remote_path}" == *:* ]] || remote_path="${underlying}:"

	set +e
	local out
	out="$(rclone_cloud::run_as_user "${bin}" config create "${crypt_name}" crypt \
		"remote=${remote_path}" \
		"password=${password}" \
		"password2=${password2}" \
		--non-interactive \
		--obscure \
		--config="${RCLONE_CONF}" 2>&1)"
	local rc=$?
	set -e
	[[ "${rc}" -eq 0 ]] || grep -q "^\[${crypt_name}\]" "${RCLONE_CONF}" 2>/dev/null \
		|| rclone_ctl::fail "crypt create failed: ${out:0:400}"

	if [[ "${set_primary}" == "1" ]]; then
		local preset="media" mode="import"
		if [[ -f "${RCLONE_PROFILE}" ]]; then
			# shellcheck source=/dev/null
			set -a && source "${RCLONE_PROFILE}" && set +a
			preset="${RCLONE_PRESET:-media}"
			mode="${RCLONE_MODE:-import}"
		fi
		rclone_ctl::apply "${user}" --remote "${crypt_name}" --preset "${preset}" \
			--mode "${mode}" --provider crypt --move-dest "${crypt_name}:"
		return
	fi
	python3 - <<PY
import json
print(json.dumps({"ok": True, "crypt": "${crypt_name}", "remote": "${remote_path}"}))
PY
}

rclone_ctl::add_branch() {
	local user="${1:?}"
	shift
	local branch="" remote_spec="" with_union=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--branch) branch="${2:-}"; shift 2 ;;
		--remote-spec) remote_spec="${2:-}"; shift 2 ;;
		--union) with_union=1; shift ;;
		*) shift ;;
		esac
	done
	[[ -n "${branch}" && -n "${remote_spec}" ]] || rclone_ctl::fail "add-branch requires --branch and --remote-spec"
	rclone_cloud_setup::add_branch "${user}" "${branch}" "${remote_spec}" "${with_union}"
	python3 - <<PY
import json
print(json.dumps({"ok": True, "branch": "${branch}", "remote_spec": "${remote_spec}", "union": ${with_union}, "mount_path": "/home/${user}/mounts/remote/${branch}"}))
PY
}

rclone_ctl::set_primary_branch() {
	local user="${1:?}"
	shift
	local branch=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--branch) branch="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	[[ -n "${branch}" ]] || rclone_ctl::fail "set-primary-branch requires --branch"
	rclone_cloud_setup::set_primary_branch "${user}" "${branch}" \
		|| rclone_ctl::fail "set-primary-branch failed for ${branch}"
	python3 - <<PY
import json
print(json.dumps({"ok": True, "primary_branch": "${branch}", "mount_path": "/home/${user}/mounts/remote/${branch}"}))
PY
}

rclone_ctl::remove_branch() {
	local user="${1:?}"
	shift
	local branch=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--branch) branch="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	[[ -n "${branch}" ]] || rclone_ctl::fail "remove-branch requires --branch"
	[[ "${branch}" != "main" ]] || rclone_ctl::fail "cannot remove main branch"
	local instance="${user}--${branch}"
	local state="/home/${user}/.krate/applications/rclone-cloud"
	systemctl disable --now "rclone-mount@${instance}.service" 2>/dev/null || true
	rm -f "${state}/mounts/${branch}.env"
	rclone_cloud::migrate_layout "${user}" 2>/dev/null || true
	# If this branch was primary, fall back to main.
	if [[ -f "${state}/profile.env" ]] && grep -q "^RCLONE_PRIMARY_BRANCH=${branch}$" "${state}/profile.env" 2>/dev/null; then
		rclone_cloud_setup::set_primary_branch "${user}" "main" || true
	fi
	rclone_cloud::rebuild_union_branches "${user}"
	local branches_file="${state}/union.branches"
	if [[ "$(grep -c . "${branches_file}" || true)" -ge 2 ]]; then
		systemctl restart "mergerfs-union@${user}.service" || true
	else
		systemctl disable --now "mergerfs-union@${user}.service" 2>/dev/null || true
		sed -i 's/^RCLONE_MEDIA_CLOUD_BRANCH=union$/RCLONE_MEDIA_CLOUD_BRANCH=main/' "${state}/profile.env" 2>/dev/null || true
		systemctl restart "mergerfs-media@${user}.service" 2>/dev/null || true
	fi
	python3 - <<PY
import json
print(json.dumps({"ok": True, "removed": "${branch}"}))
PY
}

rclone_ctl::logs() {
	local user="${1:?}"
	shift
	local kind="move" lines="80"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--kind) kind="${2:-}"; shift 2 ;;
		--lines) lines="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	rclone_cloud::parse_instance "${user}"
	local file=""
	case "${kind}" in
	move) file="${RCLONE_LOG_DIR}/move.log" ;;
	mount) file="${RCLONE_LOG_DIR}/mount-main.log" ;;
	*) rclone_ctl::fail "unknown log kind" ;;
	esac
	python3 - "${kind}" "${file}" "${lines}" <<'PY'
import json, sys
kind, path, lines = sys.argv[1], sys.argv[2], int(sys.argv[3])
content = ""
try:
    with open(path, encoding="utf-8", errors="replace") as f:
        content = "".join(f.readlines()[-lines:])
except FileNotFoundError:
    pass
print(json.dumps({"ok": True, "kind": kind, "path": path, "content": content}, ensure_ascii=False))
PY
}

rclone_ctl::import_conf() {
	local user="${1:?}"
	shift
	local src="" content=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--file) src="${2:-}"; shift 2 ;;
		--content) content="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	rclone_cloud::parse_instance "${user}"
	install -d -m 0700 -o "${user}" -g "${user}" "$(dirname "${RCLONE_CONF}")"
	if [[ -n "${src}" ]]; then
		[[ -f "${src}" ]] || rclone_ctl::fail "conf file not found: ${src}"
		install -m 0600 -o "${user}" -g "${user}" "${src}" "${RCLONE_CONF}"
	elif [[ -n "${content}" ]]; then
		printf '%s\n' "${content}" >"${RCLONE_CONF}"
		chown "${user}:${user}" "${RCLONE_CONF}"
		chmod 0600 "${RCLONE_CONF}"
	else
		rclone_ctl::fail "import-conf requires --file or --content"
	fi

	# Prefer crypt remotes for media stack, else first usable non-alias section.
	local picked="" provider_hint="import"
	picked="$(python3 - "${RCLONE_CONF}" <<'PY'
import sys
conf = sys.argv[1]
sections = []
cur = None
meta = {}
try:
    with open(conf, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("[") and line.endswith("]"):
                cur = line[1:-1]
                sections.append(cur)
                meta[cur] = {"type": "", "url": ""}
                continue
            if cur is None or "=" not in line or line.startswith("#"):
                continue
            k, v = line.split("=", 1)
            k = k.strip().lower()
            v = v.strip()
            if k == "type":
                meta[cur]["type"] = v.lower()
            elif k == "url":
                meta[cur]["url"] = v
except FileNotFoundError:
    pass

def score(name):
    t = meta.get(name, {}).get("type", "")
    if t == "alias":
        return -1
    if t == "crypt":
        return 100
    if t in ("webdav", "drive", "dropbox", "onedrive", "s3"):
        return 50
    return 10

cands = [n for n in sections if score(n) >= 0]
cands.sort(key=lambda n: (-score(n), n))
print(cands[0] if cands else "")
PY
)"
	if [[ -n "${picked}" ]]; then
		local rtype typ url
		rtype="$(python3 - "${RCLONE_CONF}" "${picked}" <<'PY'
import sys
conf, remote = sys.argv[1], sys.argv[2]
section = None
typ = ""
url = ""
with open(conf, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if section != remote or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip().lower()
        v = v.strip()
        if k == "type":
            typ = v.lower()
        elif k == "url":
            url = v
print(f"{typ}\t{url}")
PY
)"
		typ="${rtype%%$'\t'*}"
		url="${rtype#*$'\t'}"
		case "${typ}" in
		crypt) provider_hint="crypt" ;;
		webdav)
			if [[ "${url}" == *kdrive* ]] || [[ "${url}" == *infomaniak* ]]; then
				provider_hint="kdrive"
			else
				provider_hint="webdav"
			fi
			;;
		drive | dropbox | s3 | onedrive) provider_hint="${typ}" ;;
		*) provider_hint="import" ;;
		esac
		# Re-apply media stack bound to the imported remote (updates main.env + starts mounts).
		rclone_ctl::apply "${user}" --preset media --mode import --provider "${provider_hint}" --remote "${picked}" \
			--move-dest "${picked}:" >/dev/null || true
	else
		systemctl stop "rclone-mount@${user}.service" 2>/dev/null || true
		systemctl reset-failed "rclone-mount@${user}.service" 2>/dev/null || true
	fi

	python3 - "${RCLONE_CONF}" "${picked}" "${provider_hint}" <<'PY'
import json, sys
conf, primary, provider = sys.argv[1], sys.argv[2], sys.argv[3]
names = []
try:
    with open(conf, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                names.append(line[1:-1])
except FileNotFoundError:
    pass
print(json.dumps({
    "ok": True,
    "conf": conf,
    "imported": True,
    "primary_remote": primary,
    "provider": provider,
    "remotes": names,
}, ensure_ascii=False))
PY
}

rclone_ctl::service_account() {
	local user="${1:?}"
	shift
	local remote="Media" sa_file="" sa_json="" team_drive="" set_primary="0"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--remote) remote="${2:-}"; shift 2 ;;
		--file) sa_file="${2:-}"; shift 2 ;;
		--json) sa_json="${2:-}"; shift 2 ;;
		--team-drive) team_drive="${2:-}"; shift 2 ;;
		--set-primary) set_primary="1"; shift ;;
		*) shift ;;
		esac
	done
	rclone_cloud::parse_instance "${user}"
	local dest_dir="${RCLONE_HOME}/.config/rclone"
	local dest_sa="${dest_dir}/sa-${remote}.json"
	install -d -m 0700 -o "${user}" -g "${user}" "${dest_dir}"
	if [[ -n "${sa_file}" ]]; then
		[[ -f "${sa_file}" ]] || rclone_ctl::fail "service account file not found"
		install -m 0600 -o "${user}" -g "${user}" "${sa_file}" "${dest_sa}"
	elif [[ -n "${sa_json}" ]]; then
		printf '%s\n' "${sa_json}" >"${dest_sa}"
		chown "${user}:${user}" "${dest_sa}"
		chmod 0600 "${dest_sa}"
	else
		rclone_ctl::fail "service-account requires --file or --json"
	fi
	local bin
	bin="$(rclone_cloud::rclone_bin)"
	# Remove incomplete remote then recreate
	if grep -q "^\[${remote}\]" "${RCLONE_CONF}" 2>/dev/null; then
		python3 - "${RCLONE_CONF}" "${remote}" <<'PY'
import sys
conf, remote = sys.argv[1], sys.argv[2]
out, skip, cur = [], False, None
with open(conf, encoding="utf-8") as f:
    for line in f:
        if line.startswith("[") and line.endswith("]\n"):
            cur = line[1:-2]
            skip = cur == remote
            if not skip:
                out.append(line)
            continue
        if not skip:
            out.append(line)
open(conf, "w", encoding="utf-8").writelines(out)
PY
	fi
	local -a create_args=(config create "${remote}" drive
		"scope=drive"
		"service_account_file=${dest_sa}"
		--non-interactive --config="${RCLONE_CONF}")
	[[ -n "${team_drive}" ]] && create_args+=("team_drive=${team_drive}")
	set +e
	local out
	out="$(rclone_cloud::run_as_user "${bin}" "${create_args[@]}" 2>&1)"
	local rc=$?
	set -e
	[[ "${rc}" -eq 0 ]] || grep -q "^\[${remote}\]" "${RCLONE_CONF}" 2>/dev/null \
		|| rclone_ctl::fail "service-account create failed: ${out:0:400}"
	if [[ "${set_primary}" == "1" ]]; then
		local -a apply_extra=(--remote "${remote}" --provider drive --preset media)
		if [[ -n "${team_drive}" ]]; then
			apply_extra+=(--team-drive "${team_drive}" --drive-root shared)
		else
			apply_extra+=(--drive-root mydrive)
		fi
		rclone_ctl::apply "${user}" "${apply_extra[@]}"
		return
	fi
	python3 - <<PY
import json
print(json.dumps({"ok": True, "remote": "${remote}", "service_account_file": "${dest_sa}", "oauth_ready": True}))
PY
}

rclone_ctl::add_view() {
	local user="${1:?}"
	shift
	local view="" remote_spec=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--view) view="${2:-}"; shift 2 ;;
		--remote-spec) remote_spec="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	[[ -n "${view}" && -n "${remote_spec}" ]] || rclone_ctl::fail "add-view requires --view and --remote-spec"
	[[ "${view}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]] || rclone_ctl::fail "invalid view id"
	rclone_cloud::parse_instance "${user}"
	local home="${RCLONE_HOME}"
	local state="${RCLONE_STATE_DIR}"
	install -d -m 0755 -o "${user}" -g "${user}" \
		"${home}/mounts/views" "${home}/mounts/cache/${view}" \
		"$(rclone_cloud::remote_mount_path "${home}" "${view}")" \
		"${home}/mounts/views/${view}" "${state}/views" "${state}/mounts"

	# Ensure branch mount env (view mode)
	local provider="${RCLONE_PROVIDER:-import}"
	if [[ -f "${RCLONE_PROFILE}" ]]; then
		# shellcheck source=/dev/null
		set -a && source "${RCLONE_PROFILE}" && set +a
		provider="${RCLONE_PROVIDER:-import}"
	fi
	unset RCLONE_MOUNT_FLAGS RCLONE_BACKEND_FLAGS || true
	rclone_cloud::write_mount_env "${state}/mounts/${view}.env" "${remote_spec}" "${provider}" "RCLONE_VIEW_MODE=1"
	chown "${user}:${user}" "${state}/mounts/${view}.env"
	chmod 0600 "${state}/mounts/${view}.env"
	echo "RCLONE_VIEW=1" >"${state}/views/${view}.env"
	chown "${user}:${user}" "${state}/views/${view}.env"

	local instance="${user}--${view}"
	systemctl enable --now "rclone-mount@${instance}.service" || true
	systemctl enable --now "mergerfs-media@${instance}.service" || true
	python3 - <<PY
import json
print(json.dumps({
  "ok": True,
  "view": "${view}",
  "path": "${home}/mounts/views/${view}",
  "remote_spec": "${remote_spec}",
}))
PY
}

rclone_ctl::remote_create() {
	local user="${1:?}"
	shift
	local remote="Media" provider="kdrive" url="" webdav_user="" pass="" vendor="other"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--remote) remote="${2:-}"; shift 2 ;;
		--provider) provider="${2:-}"; shift 2 ;;
		--url) url="${2:-}"; shift 2 ;;
		--webdav-user | --login) webdav_user="${2:-}"; shift 2 ;;
		--pass | --password) pass="${2:-}"; shift 2 ;;
		--vendor) vendor="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	rclone_cloud::parse_instance "${user}"
	[[ -x "$(rclone_cloud::rclone_bin)" ]] || rclone_ctl::fail "rclone binary missing for ${user}"

	case "${provider}" in
	kdrive | webdav)
		[[ -n "${url}" && -n "${webdav_user}" && -n "${pass}" ]] \
			|| rclone_ctl::fail "remote-create ${provider} requires --url --webdav-user --pass"
		# Infomaniak: https://<driveId>.connect.kdrive.infomaniak.com
		if [[ "${provider}" == "kdrive" && "${url}" != http* ]]; then
			url="https://${url}.connect.kdrive.infomaniak.com"
		fi
		[[ "${vendor}" == "other" || "${vendor}" == "rclone" ]] || vendor="other"
		install -d -m 0755 -o "${user}" -g "${user}" "$(dirname "${RCLONE_CONF}")"
		[[ -f "${RCLONE_CONF}" ]] || install -m 0600 -o "${user}" -g "${user}" /dev/null "${RCLONE_CONF}"
		local bin
		bin="$(rclone_cloud::rclone_bin)"
		# rclone config create obscures pass= itself
		set +e
		rclone_cloud::run_as_user "${bin}" config create "${remote}" webdav \
			"url=${url}" \
			"vendor=${vendor}" \
			"user=${webdav_user}" \
			"pass=${pass}" \
			--non-interactive --config="${RCLONE_CONF}" >/dev/null 2>&1
		local rc=$?
		set -e
		[[ "${rc}" -eq 0 ]] || grep -q "^\[${remote}\]" "${RCLONE_CONF}" 2>/dev/null \
			|| rclone_ctl::fail "failed to create webdav/kdrive remote ${remote}"
		chown "${user}:${user}" "${RCLONE_CONF}" 2>/dev/null || true
		chmod 0600 "${RCLONE_CONF}" 2>/dev/null || true
		rclone_cloud_setup::apply_user "${user}" "media" "wizard" "${provider}" "${remote}" "" "mydrive"
		python3 - <<PY
import json
print(json.dumps({
  "ok": True,
  "remote": "${remote}",
  "provider": "${provider}",
  "backend": "webdav",
  "url": "${url}",
}))
PY
		;;
	*)
		rclone_ctl::fail "remote-create supports kdrive|webdav (got ${provider}); use oauth-begin for OAuth providers"
		;;
	esac
}

rclone_ctl::remove_view() {
	local user="${1:?}"
	shift
	local view=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--view) view="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	[[ -n "${view}" ]] || rclone_ctl::fail "remove-view requires --view"
	local instance="${user}--${view}"
	systemctl disable --now "mergerfs-media@${instance}.service" 2>/dev/null || true
	systemctl disable --now "rclone-mount@${instance}.service" 2>/dev/null || true
	rm -f "/home/${user}/.krate/applications/rclone-cloud/views/${view}.env"
	rm -f "/home/${user}/.krate/applications/rclone-cloud/mounts/${view}.env"
	python3 - <<PY
import json
print(json.dumps({"ok": True, "removed_view": "${view}"}))
PY
}

rclone_ctl::teardown() {
	local user="${1:?}"
	if ! rclone_cloud_setup::teardown_user "${user}"; then
		rclone_ctl::fail "teardown blocked: empty ~/mounts/cache first (pending move files)"
	fi
	python3 - <<PY
import json
print(json.dumps({"ok": True, "teardown": "${user}"}))
PY
}

# --- argv ---
USER_NAME=""
ARGS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--user)
		USER_NAME="${2:-}"
		shift 2
		;;
	*)
		ARGS+=("$1")
		shift
		;;
	esac
done
[[ -n "${USER_NAME}" ]] || rclone_ctl::fail "missing --user"
[[ ${#ARGS[@]} -ge 1 ]] || rclone_ctl::fail "missing command"

CMD="${ARGS[0]}"
unset 'ARGS[0]'
ARGS=("${ARGS[@]+"${ARGS[@]}"}")

case "${CMD}" in
status) rclone_ctl::status "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
apply) rclone_ctl::apply "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
oauth-begin) rclone_ctl::oauth_begin "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
oauth-complete) rclone_ctl::oauth_complete "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
list-drives) rclone_ctl::list_drives "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
crypt-create) rclone_ctl::crypt_create "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
add-branch) rclone_ctl::add_branch "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
set-primary-branch) rclone_ctl::set_primary_branch "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
remove-branch) rclone_ctl::remove_branch "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
logs) rclone_ctl::logs "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
import-conf) rclone_ctl::import_conf "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
service-account) rclone_ctl::service_account "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
add-view) rclone_ctl::add_view "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
remove-view) rclone_ctl::remove_view "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
remote-create) rclone_ctl::remote_create "${USER_NAME}" "${ARGS[@]+"${ARGS[@]}"}" ;;
teardown) rclone_ctl::teardown "${USER_NAME}" ;;
*) rclone_ctl::fail "unknown command: ${CMD}" ;;
esac
