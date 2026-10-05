#!/usr/bin/env bash
# Provision the demo, seed PostgreSQL, and wait until the API answers through APIM.
# Optional: AUTO_APPROVE=1, LOCATION=..., PUBLISHER_EMAIL=..., OPERATOR_IP=...
set -euo pipefail
. "$(dirname "$0")/common.sh"
require az terraform docker jq curl

subscription_id="$(az account show --query id --output tsv)"
location="${LOCATION:-westus3}"
publisher_email="${PUBLISHER_EMAIL:-$(az account show --query user.name --output tsv)}"
operator_ip="${OPERATOR_IP:-$(curl --fail --silent --show-error https://api.ipify.org)}"

echo "Subscription: $(az account show --query name --output tsv) ($subscription_id), region $location"
echo "PostgreSQL firewall will allow this machine: $operator_ip"

# Saved for later applies and for down.sh; gitignored.
jq -n \
  --arg subscription_id "$subscription_id" \
  --arg location "$location" \
  --arg publisher_email "$publisher_email" \
  --arg operator_ip "$operator_ip" \
  '$ARGS.named' >"$repo_root/infra/terraform.tfvars.json"

tf init -input=false >/dev/null
if [ "${AUTO_APPROVE:-}" = 1 ]; then
  tf apply -input=false -auto-approve
else
  # Interactive: Terraform shows the plan and asks for approval.
  tf apply
fi
load_outputs

echo
echo "Seeding PostgreSQL as $(out postgres_admin)..."
pg postgres \
  -v dab_principal="$(out dab_principal_name)" \
  -v dab_object_id="$(out dab_principal_object_id)" \
  <"$repo_root/sql/azure/dab-principal.sql"
for script in 10-schema 20-synthetic-data 30-access; do
  pg "$(out database_name)" <"$repo_root/sql/$script.sql"
done
pg "$(out database_name)" -v api_login="$(out dab_principal_name)" <"$repo_root/sql/40-api-login.sql"
pg "$(out database_name)" <"$repo_root/sql/50-assertions.sql"

# DAB fails at startup until its role and the views exist; restart it now that they do.
echo
echo "Restarting DAB..."
revision="$(az resource show --ids "$(out container_app_id)" --query properties.latestRevisionName --output tsv)"
az rest --method post --output none \
  --url "https://management.azure.com$(out container_app_id)/revisions/$revision/restart?api-version=2024-03-01"

echo "Waiting for the API through APIM (new Entra role assignments can take a few minutes)..."
scenes_url="$(out apim_gateway_url)/api/scenes?\$first=1"
for _ in $(seq 1 60); do
  token="$(client_token catalog 2>/dev/null || true)"
  if [ -n "$token" ]; then
    status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
      -H "Authorization: Bearer $token" -H 'X-MS-API-ROLE: catalog-viewer' "$scenes_url")"
    if [ "$status" = 200 ]; then
      echo
      echo "Ready: $(out apim_gateway_url)/api"
      echo "Next:  bash scripts/demo.sh"
      exit 0
    fi
  fi
  sleep 10
done

echo "The API did not answer within 10 minutes. Inspect DAB with:" >&2
echo "  az containerapp logs show -g $(out resource_group_name) -n $(out container_app_name) --tail 50" >&2
exit 1
