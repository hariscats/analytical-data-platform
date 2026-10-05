#Requires -Version 7.4
<#
.SYNOPSIS
Provision the demo, seed PostgreSQL, and wait until the API answers through APIM.

.EXAMPLE
pwsh ./scripts/up.ps1
pwsh ./scripts/up.ps1 -AutoApprove -Location eastus2
#>
param(
    # Skip Terraform's approval prompt. AUTO_APPROVE=1 does the same.
    [switch]$AutoApprove,
    [string]$Location = ($env:LOCATION ?? 'westus3'),
    # Defaults to the signed-in Azure CLI user.
    [string]$PublisherEmail = $env:PUBLISHER_EMAIL,
    # Defaults to this machine's public IPv4 address.
    [string]$OperatorIp = $env:OPERATOR_IP
)

. "$PSScriptRoot/common.ps1"
Assert-Tool az, terraform, docker

$account = az account show --output json | Out-String | ConvertFrom-Json
if (-not $PublisherEmail) { $PublisherEmail = $account.user.name }
if (-not $OperatorIp) { $OperatorIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim() }

Write-Host "Subscription: $($account.name) ($($account.id)), region $Location"
Write-Host "PostgreSQL firewall will allow this machine: $OperatorIp"

# Saved for later applies and for down.ps1; gitignored.
[ordered]@{
    subscription_id = $account.id
    location        = $Location
    publisher_email = $PublisherEmail
    operator_ip     = $OperatorIp
} | ConvertTo-Json | Set-Content -Path "$RepoRoot/infra/terraform.tfvars.json" -Encoding utf8NoBOM

Invoke-Terraform init -input=false | Out-Null
if ($AutoApprove -or $env:AUTO_APPROVE -eq '1') {
    Invoke-Terraform apply -input=false -auto-approve
}
else {
    # Interactive: Terraform shows the plan and asks for approval.
    Invoke-Terraform apply
}
Read-TerraformOutput
$database = Get-Output database_name
$dabPrincipal = Get-Output dab_principal_name

Write-Host "`nSeeding PostgreSQL as $(Get-Output postgres_admin)..."
Invoke-Pg -Database postgres -Path "$RepoRoot/sql/azure/dab-principal.sql" -Variables @{
    dab_principal = $dabPrincipal
    dab_object_id = (Get-Output dab_principal_object_id)
}
foreach ($file in '10-schema', '20-synthetic-data', '30-access') {
    Invoke-Pg -Database $database -Path "$RepoRoot/sql/$file.sql"
}
Invoke-Pg -Database $database -Path "$RepoRoot/sql/40-api-login.sql" -Variables @{ api_login = $dabPrincipal }
Invoke-Pg -Database $database -Path "$RepoRoot/sql/50-assertions.sql"

# DAB fails at startup until its role and the views exist; restart it now that they do.
Write-Host "`nRestarting DAB..."
$appId = Get-Output container_app_id
$revision = az resource show --ids $appId --query properties.latestRevisionName --output tsv
az rest --method post --output none `
    --url "https://management.azure.com$appId/revisions/$revision/restart?api-version=2024-03-01"

Write-Host 'Waiting for the API through APIM (new Entra role assignments can take a few minutes)...'
$scenesUrl = "$(Get-Output apim_gateway_url)/api/scenes?`$first=1"
for ($attempt = 1; $attempt -le 60; $attempt++) {
    try {
        $headers = @{ Authorization = "Bearer $(Get-ClientToken catalog)"; 'X-MS-API-ROLE' = 'catalog-viewer' }
        if ((Invoke-WebRequest -Uri $scenesUrl -Headers $headers -SkipHttpErrorCheck).StatusCode -eq 200) {
            Write-Host "`nReady: $(Get-Output apim_gateway_url)/api"
            Write-Host 'Next:  pwsh ./scripts/demo.ps1'
            return
        }
    }
    catch {
        # Tokens and DNS can fail briefly while new resources settle; keep polling.
        Write-Verbose $_
    }
    Start-Sleep -Seconds 10
}

throw ("The API did not answer within 10 minutes. Inspect DAB with:`n" +
    "  az containerapp logs show -g $(Get-Output resource_group_name) -n $(Get-Output container_app_name) --tail 50")
