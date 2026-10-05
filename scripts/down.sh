#!/usr/bin/env bash
# Delete every demo resource, the Entra app registrations, and the APIM soft-delete record.
set -euo pipefail
. "$(dirname "$0")/common.sh"
require terraform

if [ "${AUTO_APPROVE:-}" = 1 ]; then
  tf destroy -input=false -auto-approve
else
  # Interactive: Terraform shows the plan and asks for approval.
  tf destroy
fi
