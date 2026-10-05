#!/usr/bin/env bash
# Shared helpers for up.sh, demo.sh, and down.sh. Source, don't run.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tf() {
  terraform -chdir="$repo_root/infra" "$@"
}

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || { echo "Missing required tool: $cmd" >&2; exit 1; }
  done
}

# Read every Terraform output once; sensitive values included.
load_outputs() {
  outputs="$(tf output -json)"
}

out() {
  jq -er --arg name "$1" '.[$name].value' <<<"$outputs"
}

# Client-credentials token for a demo client: analyst-a, analyst-b, or catalog.
client_token() {
  local client
  client="$(jq -ec --arg name "$1" '.clients.value[$name]' <<<"$outputs")"
  curl --fail --silent --show-error \
    --data-urlencode "client_id=$(jq -r .client_id <<<"$client")" \
    --data-urlencode "client_secret=$(jq -r .client_secret <<<"$client")" \
    --data-urlencode "scope=$(out api_scope)" \
    --data-urlencode "grant_type=client_credentials" \
    "https://login.microsoftonline.com/$(out tenant_id)/oauth2/v2.0/token" |
    jq -er .access_token
}

# psql in a throwaway container, signed in as the operator with a Microsoft Entra token.
# Usage: pg <database> [psql args...] < script.sql
pg() {
  local database=$1
  shift
  if [ -z "${pg_token:-}" ]; then
    pg_token="$(az account get-access-token --resource-type oss-rdbms --query accessToken --output tsv)"
  fi
  docker run --rm -i \
    -e PGHOST="$(out postgres_host)" \
    -e PGUSER="$(out postgres_admin)" \
    -e PGPASSWORD="$pg_token" \
    -e PGDATABASE="$database" \
    -e PGSSLMODE=require \
    postgres:17-alpine psql --quiet --no-psqlrc "$@"
}
