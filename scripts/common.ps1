#Requires -Version 7.4
# Shared helpers for up.ps1, demo.ps1, down.ps1, and test-local.ps1. Dot-source, don't run.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# terraform, az, and docker throw when they exit non-zero, like `set -e` in bash.
$PSNativeCommandUseErrorActionPreference = $true

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Terraform {
    terraform "-chdir=$RepoRoot/infra" @args
}

function Assert-Tool([string[]]$Name) {
    foreach ($tool in $Name) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Missing required tool: $tool"
        }
    }
}

# Read every Terraform output once; sensitive values included.
function Read-TerraformOutput {
    $script:Outputs = Invoke-Terraform output -json | Out-String | ConvertFrom-Json
}

function Get-Output([string]$Name) {
    $script:Outputs.$Name.value
}

# Client-credentials token for a demo client: analyst-a, analyst-b, or catalog.
function Get-ClientToken([string]$Client) {
    $credential = $script:Outputs.clients.value.$Client
    $response = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$(Get-Output tenant_id)/oauth2/v2.0/token" `
        -Body @{
            client_id     = $credential.client_id
            client_secret = $credential.client_secret
            scope         = (Get-Output api_scope)
            grant_type    = 'client_credentials'
        }
    $response.access_token
}

# psql in a throwaway container, signed in as the operator with a Microsoft Entra token.
function Invoke-Pg {
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Variables = @{}
    )
    if (-not (Get-Variable -Name PgToken -Scope Script -ErrorAction SilentlyContinue)) {
        $script:PgToken = az account get-access-token --resource-type oss-rdbms --query accessToken --output tsv
    }
    $psqlArgs = @(foreach ($name in $Variables.Keys) { '-v'; "$name=$($Variables[$name])" })
    Get-Content -Raw -Path $Path | docker run --rm -i `
        -e "PGHOST=$(Get-Output postgres_host)" `
        -e "PGUSER=$(Get-Output postgres_admin)" `
        -e "PGPASSWORD=$script:PgToken" `
        -e "PGDATABASE=$Database" `
        -e PGSSLMODE=require `
        postgres:17-alpine psql --quiet --no-psqlrc @psqlArgs
}
