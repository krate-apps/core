#!/usr/bin/env bash
# dispatcharr@ ExecStart — uWSGI master (gevent) + attach-daemon celery/beat/daphne (upstream pattern).
set -euo pipefail

user="${1:?usage: krate-run.sh USER}"

install_dir="/opt/${user}/dispatcharr"
venv="${install_dir}/.venv"
uwsgi_bin="${venv}/bin/uwsgi"
ini="/opt/Krate/share/applications/official/dispatcharr/krate-uwsgi.ini"

: "${PORT:?PORT is required}"
: "${DAPHNE_PORT:?DAPHNE_PORT is required}"

cd "${install_dir}"
[[ -f "${install_dir}/.env" ]] && { set -a; # shellcheck source=/dev/null
	source "${install_dir}/.env"; set +a; }

export DISPATCHARR_ENV="${DISPATCHARR_ENV:-aio}"
export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-dispatcharr.settings}"
export POSTGRES_PORT="${POSTGRES_PORT:-5432}"
: "${POSTGRES_HOST:?POSTGRES_HOST is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required in install_dir/.env}"
export CELERY_NICE_LEVEL="${CELERY_NICE_LEVEL:-5}"

redis_host="${REDIS_HOST:-127.0.0.1}"
redis_port="${REDIS_PORT:-6379}"
if ! redis-cli -h "${redis_host}" -p "${redis_port}" ping >/dev/null 2>&1; then
	echo "redis-server is not reachable on ${redis_host}:${redis_port}" >&2
	exit 1
fi

"${venv}/bin/python" manage.py migrate --noinput
"${venv}/bin/python" manage.py collectstatic --noinput
"${venv}/bin/python" scripts/wait_for_redis.py

exec "${uwsgi_bin}" \
	--ini "${ini}" \
	--chdir "${install_dir}" \
	--virtualenv "${venv}" \
	--env "DAPHNE_PORT=${DAPHNE_PORT}" \
	--http "127.0.0.1:${PORT}" \
	--static-map "/static=${install_dir}/static" \
	--static-map "/assets=${install_dir}/static/assets" \
	--attach-daemon "nice -n ${CELERY_NICE_LEVEL} ${venv}/bin/celery -A dispatcharr worker -Q celery -n default@%h --autoscale=6,1" \
	--attach-daemon "nice -n ${CELERY_NICE_LEVEL} ${venv}/bin/celery -A dispatcharr worker -Q dvr -n dvr@%h --pool=threads --concurrency=20" \
	--attach-daemon "nice -n ${CELERY_NICE_LEVEL} ${venv}/bin/celery -A dispatcharr beat" \
	--attach-daemon "${venv}/bin/daphne -b 127.0.0.1 -p ${DAPHNE_PORT} --proxy-headers dispatcharr.asgi:application"
