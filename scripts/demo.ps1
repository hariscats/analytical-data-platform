#Requires -Version 7.4
<#
.SYNOPSIS
End-to-end walk-through: selective, bounded reads and authorization at every layer.
Every step asserts its outcome; the script stops on the first surprise.
#>

. "$PSScriptRoot/common.ps1"
Assert-Tool az, terraform, docker

Read-TerraformOutput
$gateway = Get-Output apim_gateway_url
$api = "$gateway/api"
$dab = "$(Get-Output dab_url)/api"
$analystA = Get-ClientToken analyst-a
$catalog = Get-ClientToken catalog

function Write-Step([string]$Text) { Write-Host "`n== $Text" }
function Write-Pass([string]$Text) { Write-Host "   ok: $Text" }

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    Write-Pass $Message
}

function Assert-Status($Response, [int[]]$Expected) {
    if ($Response.Status -notin $Expected) {
        throw "FAILED: expected HTTP $($Expected -join ' or '), got $($Response.Status): $($Response.Body)"
    }
    Write-Pass "HTTP $($Response.Status)"
}

# One request; returns Status, raw Body, and parsed Json (when the body is JSON).
function Invoke-Api {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Token,
        [string]$Role,
        [System.Collections.IDictionary]$Query = @{},
        [string]$Method = 'GET',
        [string]$Body
    )
    $headers = @{}
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    if ($Role) { $headers['X-MS-API-ROLE'] = $Role }
    if ($Query.Count) {
        $Url += '?' + (@(foreach ($key in $Query.Keys) { "$key=$([uri]::EscapeDataString($Query[$key]))" }) -join '&')
    }
    $request = @{ Uri = $Url; Method = $Method; Headers = $headers; SkipHttpErrorCheck = $true }
    if ($Body) { $request.Body = $Body; $request.ContentType = 'application/json' }
    $response = Invoke-WebRequest @request
    $json = $null
    if ($response.Content -and "$($response.Headers['Content-Type'])" -match 'json') {
        $json = $response.Content | ConvertFrom-Json
    }
    [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $response.Content; Json = $json }
}

# The leading comma keeps an empty or one-row result an array instead of $null or a scalar.
function Get-Row($Response) { , @($Response.Json.value) }
function Test-Field($Row, [string]$Name) { $Row.PSObject.Properties.Name -contains $Name }
function Format-Row($Row) { $Row | ConvertTo-Json -Compress }
function Format-Utc($Value) {
    if ($Value -is [datetime]) { $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } else { "$Value" }
}

Write-Step '1. No token: APIM rejects the call'
Assert-Status (Invoke-Api "$api/scenes") 401

Write-Step '2. analyst-a reads the catalog with explicit fields and sort order'
$response = Invoke-Api "$api/scenes" -Token $analystA -Role mission-a-analyst -Query ([ordered]@{
        '$select'  = 'scene_id,mission_id,acquired_at,cloud_cover_pct'
        '$orderby' = 'acquired_at asc,scene_id asc'
    })
Assert-Status $response 200
$scenes = Get-Row $response
foreach ($scene in $scenes) {
    Write-Host ('   {0}  mission {1}  {2}  cloud {3}%' -f $scene.scene_id, $scene.mission_id, (Format-Utc $scene.acquired_at), $scene.cloud_cover_pct)
}
Assert-That ($scenes.Count -gt 0 -and -not ($scenes | Where-Object mission_id -ne 'A')) 'DAB row policy returned Mission A only'
Assert-That ('A-0004' -notin $scenes.scene_id) 'embargoed A-0004 absent (PostgreSQL RLS)'

Write-Step '3. catalog reads both missions, without coordinates'
$response = Invoke-Api "$api/scenes" -Token $catalog -Role catalog-viewer -Query @{ '$orderby' = 'scene_id asc' }
Assert-Status $response 200
$scenes = Get-Row $response
Write-Host "   fields: $(($scenes[0].PSObject.Properties.Name | Sort-Object) -join ', ')"
Assert-That ((@($scenes.mission_id | Sort-Object -Unique) -join ',') -eq 'A,B') 'both missions visible: catalog-viewer has no DAB row policy'
Assert-That (-not ($scenes | Where-Object { Test-Field $_ center_lat })) 'coordinates omitted (DAB field permissions)'
Assert-That ('A-0004' -notin $scenes.scene_id -and 'B-0004' -notin $scenes.scene_id) `
    'embargoed scenes still absent: PostgreSQL RLS applies whatever DAB allows'

Write-Step '4. catalog selects a coordinate: DAB denies the field'
Assert-Status (Invoke-Api "$api/scenes" -Token $catalog -Role catalog-viewer -Query @{ '$select' = 'scene_id,center_lat' }) 403

Write-Step '5. catalog reads spectra: DAB denies the entity'
Assert-Status (Invoke-Api "$api/spectra" -Token $catalog -Role catalog-viewer -Query @{ '$filter' = "scene_id eq 'A-0001'" }) 403

Write-Step '6. analyst-a pages through a bounded spectral window of one scene'
$response = Invoke-Api "$api/spectra" -Token $analystA -Role mission-a-analyst -Query ([ordered]@{
        '$select'  = 'pixel_row,pixel_col,wavelength_nm,reflectance'
        '$filter'  = "scene_id eq 'A-0002' and wavelength_nm ge 650 and wavelength_nm le 900"
        '$orderby' = 'pixel_row asc,pixel_col asc,wavelength_nm asc'
        '$first'   = '200'
    })
Assert-Status $response 200
$page1 = Get-Row $response
Write-Host "   page 1: $($page1.Count) rows, first $(Format-Row $page1[0]), last $(Format-Row $page1[-1])"
$nextLink = if (Test-Field $response.Json nextLink) { $response.Json.nextLink }
Assert-That ($page1.Count -eq 200 -and $nextLink) 'page bounded at 200 rows with a nextLink'
Assert-That (-not ($page1 | Where-Object { $_.wavelength_nm -lt 650 -or $_.wavelength_nm -gt 900 })) 'filter applied'
$response = Invoke-Api "$gateway$nextLink" -Token $analystA -Role mission-a-analyst
Assert-Status $response 200
$page2 = Get-Row $response
Write-Host "   page 2: $($page2.Count) rows, first $(Format-Row $page2[0])"
$last = $page1[-1]
$next = $page2[0]
$continues = $next.pixel_row -gt $last.pixel_row -or ($next.pixel_row -eq $last.pixel_row -and (
        $next.pixel_col -gt $last.pixel_col -or ($next.pixel_col -eq $last.pixel_col -and $next.wavelength_nm -gt $last.wavelength_nm)))
Assert-That $continues 'page 2 continues exactly after page 1 in the declared sort order'

Write-Step '7. Unsupported query shapes: APIM rejects them before DAB'
Assert-Status (Invoke-Api "$api/spectra" -Token $analystA -Role mission-a-analyst -Query @{ '$first' = '10' }) 400
Assert-Status (Invoke-Api "$api/spectra" -Token $analystA -Role mission-a-analyst -Query @{
        '$filter' = "scene_id eq 'A-0001' or scene_id eq 'A-0002'"
    }) 400
Assert-Status (Invoke-Api "$api/scenes" -Token $analystA -Role mission-a-analyst -Query @{ '$first' = '5000' }) 400
Assert-Status (Invoke-Api "$api/scenes" -Token $analystA -Role mission-a-analyst -Query @{ '$count' = 'true' }) 400

Write-Step '8. analyst-a asks for a Mission B scene: the DAB policy becomes a SQL predicate'
$response = Invoke-Api "$api/scenes" -Token $analystA -Role mission-a-analyst -Query @{ '$filter' = "scene_id eq 'B-0001'" }
Assert-Status $response 200
Assert-That ((Get-Row $response).Count -eq 0) "no rows: mission_id = 'A' was added to the query"

Write-Step '9. Role spoofing and APIM bypass'
Assert-Status (Invoke-Api "$api/scenes" -Token $analystA -Role mission-b-analyst) 403
Write-Pass "APIM: mission-b-analyst is not in analyst-a's token"
Assert-Status (Invoke-Api "$dab/scenes" -Token $analystA -Role mission-b-analyst) 403
Write-Pass 'DAB directly: same answer without APIM'
Assert-Status (Invoke-Api "$dab/scenes") 403
Write-Pass 'DAB directly without a token: anonymous has no permissions'
$response = Invoke-Api "$dab/scenes" -Token $analystA -Role mission-a-analyst
Assert-Status $response 200
$scenes = Get-Row $response
Assert-That (-not ($scenes | Where-Object mission_id -ne 'A')) 'DAB directly with a valid token still applies the row policy'

Write-Step '10. Writes are not part of the contract'
$write = '{"scene_id":"A-0009"}'
Assert-Status (Invoke-Api "$api/scenes" -Token $analystA -Role mission-a-analyst -Method POST -Body $write) 404, 405
Write-Pass 'APIM declares GET operations only'
Assert-Status (Invoke-Api "$dab/scenes" -Token $analystA -Role mission-a-analyst -Method POST -Body $write) 403
Write-Pass 'DAB grants read only'

Write-Step "11. PostgreSQL floor, checked as the API's database role"
Invoke-Pg -Database (Get-Output database_name) -Path "$RepoRoot/sql/50-assertions.sql"

Write-Host "`nAll checks passed."
