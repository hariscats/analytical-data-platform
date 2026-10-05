#!/usr/bin/env bash
# Offline check, no Azure needed: load the SQL into a throwaway PostgreSQL as a
# non-superuser admin (as on Azure), prove the database floor, then start the
# pinned DAB image against the published views exactly as Container Apps mounts it.
set -euo pipefail
. "$(dirname "$0")/common.sh"
require docker curl

dab_image="$(sed -n 's/^ *dab_image *= *"\(.*\)"$/\1/p' "$repo_root/infra/main.tf")"
name="hsi-test-$$"
cleanup() {
  docker rm -f "$name-pg" "$name-dab" >/dev/null 2>&1 || true
  docker network rm "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$name" >/dev/null
docker run -d --name "$name-pg" --network "$name" \
  -e POSTGRES_PASSWORD=local-superuser postgres:17-alpine >/dev/null
# TCP readiness skips the image's temporary initialisation server.
until docker exec "$name-pg" pg_isready -h 127.0.0.1 -U postgres -q; do sleep 1; done

docker exec -i "$name-pg" psql -U postgres --quiet --no-psqlrc -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE seed_admin LOGIN PASSWORD 'local-seed' CREATEROLE;
CREATE DATABASE imagery OWNER seed_admin;
SQL

seed() {
  docker exec -i -e PGPASSWORD=local-seed "$name-pg" \
    psql -h 127.0.0.1 -U seed_admin -d imagery --quiet --no-psqlrc "$@"
}
seed <"$repo_root/sql/10-schema.sql"
seed -v grid=8 -v bands=16 <"$repo_root/sql/20-synthetic-data.sql"
seed <"$repo_root/sql/30-access.sql"
seed -c "CREATE ROLE dab_local LOGIN PASSWORD 'local-dab'"
seed -v api_login=dab_local <"$repo_root/sql/40-api-login.sql"
seed <"$repo_root/sql/50-assertions.sql"

docker run -d --name "$name-dab" --network "$name" --platform linux/amd64 --user 1654 \
  -e "DATABASE_CONNECTION_STRING=Host=$name-pg;Port=5432;Database=imagery;Username=dab_local;Password=local-dab;SSL Mode=Disable" \
  -e DAB_JWT_ISSUER=https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0 \
  -e API_AUDIENCE=00000000-0000-0000-0000-000000000000 \
  -e ConfigFileName=/App/config/dab-config \
  -e ASPNETCORE_URLS=http://+:5000 \
  -v "$repo_root/dab/dab-config.json:/App/config/dab-config:ro" \
  -p 127.0.0.1::5000 \
  "$dab_image" >/dev/null
port="$(docker port "$name-dab" 5000/tcp | head -n 1 | cut -d: -f2)"

# 403 means DAB loaded the config, validated both entities against the views,
# and refused an anonymous caller.
status=000
for _ in $(seq 1 60); do
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port/api/scenes" || true)"
  [ "$status" = 403 ] && break
  sleep 2
done
if [ "$status" != 403 ]; then
  docker logs "$name-dab" 2>&1 | tail -n 40 >&2
  echo "DAB did not start against the published views (last HTTP $status)." >&2
  exit 1
fi
echo "DAB started against the published views and denies anonymous reads (HTTP 403)."
