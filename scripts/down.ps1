#Requires -Version 7.4
<#
.SYNOPSIS
Delete every demo resource, the Entra app registrations, and the APIM soft-delete record.
#>
param(
    # Skip Terraform's approval prompt. AUTO_APPROVE=1 does the same.
    [switch]$AutoApprove
)

. "$PSScriptRoot/common.ps1"
Assert-Tool terraform

if ($AutoApprove -or $env:AUTO_APPROVE -eq '1') {
    Invoke-Terraform destroy -input=false -auto-approve
}
else {
    # Interactive: Terraform shows the plan and asks for approval.
    Invoke-Terraform destroy
}
