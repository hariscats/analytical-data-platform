#Requires -Version 7.4
<#
.SYNOPSIS
Offline check, no Azure needed: load the SQL into a throwaway PostgreSQL as a
non-superuser admin (as on Azure), prove the database floor, then start the
pinned DAB image against the published views exactly as Container Apps mounts it.
#>

. "$PSScriptRoot/common.ps1"
Assert-Tool docker

$dabImage = (Select-String -Path "$RepoRoot/infra/main.tf" -Pattern '^\s*dab_image\s*=\s*"(.*)"$').Matches[0].Groups[1].Value
$name = "hsi-test-$PID"

function Test-PgReady {
    $PSNativeCommandUseErrorActionPreference = $false
    docker exec "$name-pg" pg_isready -h 127.0.0.1 -U postgres -q
    $LASTEXITCODE -eq 0
}

function Invoke-Seed {
    param([string]$Path, [string]$Command, [string[]]$Variables = @())
    $psqlArgs = @('-h', '127.0.0.1', '-U', 'seed_admin', '-d', 'imagery', '--quiet', '--no-psqlrc')
    foreach ($variable in $Variables) { $psqlArgs += '-v', $variable }
    if ($Command) {
        docker exec -e PGPASSWORD=local-seed "$name-pg" psql @psqlArgs -c $Command
    }
    else {
        Get-Content -Raw -Path $Path | docker exec -i -e PGPASSWORD=local-seed "$name-pg" psql @psqlArgs
    }
}

try {
    docker network create $name | Out-Null
    docker run -d --name "$name-pg" --network $name -e POSTGRES_PASSWORD=local-superuser postgres:17-alpine | Out-Null
    # TCP readiness skips the image's temporary initialisation server.
    while (-not (Test-PgReady)) { Start-Sleep -Seconds 1 }

    "CREATE ROLE seed_admin LOGIN PASSWORD 'local-seed' CREATEROLE;`nCREATE DATABASE imagery OWNER seed_admin;" |
        docker exec -i "$name-pg" psql -U postgres --quiet --no-psqlrc -v ON_ERROR_STOP=1

    Invoke-Seed -Path "$RepoRoot/sql/10-schema.sql"
    Invoke-Seed -Path "$RepoRoot/sql/20-synthetic-data.sql" -Variables 'grid=8', 'bands=16'
    Invoke-Seed -Path "$RepoRoot/sql/30-access.sql"
    Invoke-Seed -Command "CREATE ROLE dab_local LOGIN PASSWORD 'local-dab'"
    Invoke-Seed -Path "$RepoRoot/sql/40-api-login.sql" -Variables 'api_login=dab_local'
    Invoke-Seed -Path "$RepoRoot/sql/50-assertions.sql"

    docker run -d --name "$name-dab" --network $name --platform linux/amd64 --user 1654 `
        -e "DATABASE_CONNECTION_STRING=Host=$name-pg;Port=5432;Database=imagery;Username=dab_local;Password=local-dab;SSL Mode=Disable" `
        -e 'DAB_JWT_ISSUER=https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0' `
        -e 'API_AUDIENCE=00000000-0000-0000-0000-000000000000' `
        -e 'ConfigFileName=/App/config/dab-config' `
        -e 'ASPNETCORE_URLS=http://+:5000' `
        --mount "type=bind,source=$RepoRoot/dab/dab-config.json,target=/App/config/dab-config,readonly" `
        -p '127.0.0.1::5000' `
        $dabImage | Out-Null
    $port = (@(docker port "$name-dab" 5000/tcp)[0] -split ':')[-1]

    # 403 means DAB loaded the config, validated both entities against the views,
    # and refused an anonymous caller.
    $status = 0
    for ($attempt = 1; $attempt -le 60 -and $status -ne 403; $attempt++) {
        try {
            $status = [int](Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/scenes" -SkipHttpErrorCheck).StatusCode
        }
        catch {
            # DAB isn't listening yet, or has exited; the status check below reports it.
            Write-Verbose $_
        }
        if ($status -ne 403) { Start-Sleep -Seconds 2 }
    }
    if ($status -ne 403) {
        $PSNativeCommandUseErrorActionPreference = $false
        docker logs "$name-dab" 2>&1 | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
        throw "DAB did not start against the published views (last HTTP $status)."
    }
    Write-Host 'DAB started against the published views and denies anonymous reads (HTTP 403).'
}
finally {
    $PSNativeCommandUseErrorActionPreference = $false
    docker rm -f "$name-pg" "$name-dab" 2>$null | Out-Null
    docker network rm $name 2>$null | Out-Null
}
