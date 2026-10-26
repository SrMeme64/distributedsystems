[CmdletBinding()]
param(
    [string]$ComposeEnvFile = ".env.exam",

    [ValidateRange(0, 900)]
    [int]$TimeoutSeconds = 120,

    [ValidateRange(1, 30)]
    [int]$PollSeconds = 3,

    [switch]$Json
)

# Read-only readiness check for the whole stack.
# Exit code 0 = ready, 1 = not ready.
# Used by Start-Stack.ps1 and by the PoC suites before injecting faults.

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envFilePath = Join-Path $repositoryRoot $ComposeEnvFile
if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
    throw "No se encontro el archivo de entorno de Compose: $envFilePath"
}

$expectedServices = @(
    "presentation-lb-master",
    "presentation-lb-backup",
    "presentation-entry",
    "presentation-keepalived-master",
    "presentation-keepalived-backup",
    "web1",
    "web2",
    "web3",
    "application-lb-master",
    "application-lb-backup",
    "application-keepalived-master",
    "application-keepalived-backup",
    "app1",
    "app2",
    "app3",
    "proxysql",
    "mongo1",
    "mongo2",
    "mongo3",
    "redis-master",
    "redis-replica1",
    "redis-replica2",
    "redis-sentinel1",
    "redis-sentinel2",
    "redis-sentinel3",
    "galera1",
    "galera2",
    "galera3",
    "nagios"
)

$servicesWithHealthcheck = @(
    "proxysql",
    "mongo1",
    "mongo2",
    "mongo3",
    "redis-master",
    "redis-replica1",
    "redis-replica2",
    "redis-sentinel1",
    "redis-sentinel2",
    "redis-sentinel3",
    "galera1",
    "galera2",
    "galera3"
)

function Get-ComposeEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $pattern = "^\s*" + [regex]::Escape($Key) + "=(.*)$"
    $line = Get-Content -LiteralPath $Path |
        Where-Object { $_ -match $pattern } |
        Select-Object -Last 1
    if (-not $line) {
        return $null
    }

    $value = [regex]::Match($line, $pattern).Groups[1].Value.Trim()
    return $value.Trim('"').Trim("'")
}

function Test-TcpPort {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMilliseconds = 2500
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-HttpProbe {
    param([string]$Uri)

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 6
        [pscustomobject]@{
            Success    = ([int]$response.StatusCode -eq 200)
            StatusCode = [int]$response.StatusCode
            Content    = [string]$response.Content
            Trace      = [string]$response.Headers["X-Request-Trace"]
            Error      = $null
        }
    } catch {
        [pscustomobject]@{
            Success    = $false
            StatusCode = $null
            Content    = $null
            Trace      = $null
            Error      = $_.Exception.Message
        }
    }
}

function New-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    [pscustomobject]@{
        Name   = $Name
        Passed = $Passed
        Detail = $Detail
    }
}

function Get-StackSnapshot {
    $checks = New-Object 'System.Collections.Generic.List[object]'

    # Docker daemon
    & docker info *> $null
    $checks.Add((New-Check -Name "Docker daemon" -Passed ($LASTEXITCODE -eq 0) -Detail $(if ($LASTEXITCODE -eq 0) { "docker info responde" } else { "docker info fallo (exit $LASTEXITCODE)" })))

    # Containers
    $psOutput = & docker compose --env-file $ComposeEnvFile ps -a --format "{{.Service}}|{{.Status}}" 2>$null
    $statusByService = @{}
    foreach ($line in @($psOutput)) {
        $parts = $line -split "\|", 2
        if ($parts.Count -eq 2) {
            $statusByService[$parts[0]] = $parts[1]
        }
    }

    $down = New-Object 'System.Collections.Generic.List[string]'
    $starting = New-Object 'System.Collections.Generic.List[string]'
    foreach ($service in $expectedServices) {
        if (-not $statusByService.ContainsKey($service)) {
            $down.Add("$service (ausente)")
            continue
        }

        $status = [string]$statusByService[$service]
        if ($status -match "unhealthy" -or $status -notmatch "^Up") {
            $down.Add("$service ($status)")
        } elseif ($servicesWithHealthcheck -contains $service -and $status -match "health: starting") {
            $starting.Add("$service ($status)")
        }
    }

    if ($down.Count -eq 0 -and $starting.Count -eq 0) {
        $checks.Add((New-Check -Name "Servicios" -Passed $true -Detail ("{0}/{0} Up" -f $expectedServices.Count)))
    } else {
        $detail = @()
        if ($down.Count -gt 0) { $detail += "caidos: " + ($down -join ", ") }
        if ($starting.Count -gt 0) { $detail += "health starting: " + ($starting -join ", ") }
        $checks.Add((New-Check -Name "Servicios" -Passed $false -Detail ($detail -join "; ")))
    }

    # HTTP health
    $health = Get-HttpProbe -Uri "http://localhost/api/health"
    if ($health.Success) {
        try {
            $body = $health.Content | ConvertFrom-Json
            $dependencies = @()
            foreach ($property in $body.dependencies.PSObject.Properties) {
                $dependencies += "$($property.Name)=$($property.Value)"
            }
            $healthy = ($body.status -eq "ok")
            $detail = "status=$($body.status) " + ($dependencies -join " ")
        } catch {
            $healthy = $false
            $detail = "respuesta no JSON: $($health.Content)"
        }
    } else {
        $healthy = $false
        $detail = if ($health.Error) { $health.Error } else { "HTTP $($health.StatusCode)" }
    }
    $checks.Add((New-Check -Name "API /api/health" -Passed $healthy -Detail $detail))

    # Catalog
    $catalog = Get-HttpProbe -Uri "http://localhost/api/products/cheapest"
    $catalogDetail = if ($catalog.Success) { "HTTP 200, $($catalog.Content.Length) bytes" } else { if ($catalog.Error) { $catalog.Error } else { "HTTP $($catalog.StatusCode)" } }
    $checks.Add((New-Check -Name "API /api/products/cheapest" -Passed $catalog.Success -Detail $catalogDetail))

    # Request trace
    if ($health.Success -and $health.Trace) {
        $traceOk = ($health.Trace -match "presentation-lb-(master|backup)") -and
                   ($health.Trace -match "application-lb-(master|backup)") -and
                   ($health.Trace -match "\bapp[123]\b")
        $checks.Add((New-Check -Name "Traza end-to-end" -Passed $traceOk -Detail $health.Trace))
    } else {
        $checks.Add((New-Check -Name "Traza end-to-end" -Passed $false -Detail "sin cabecera X-Request-Trace"))
    }

    # Galera
    $rootPassword = Get-ComposeEnvValue -Path $envFilePath -Key "MARIADB_ROOT_PASSWORD"
    if ($rootPassword) {
        $galeraOutput = & docker exec -e "MYSQL_PWD=$rootPassword" distributed-three-tier-galera1-1 `
            mariadb -u root -N -B -e "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment');" 2>&1
        $galera = @{}
        foreach ($line in @($galeraOutput)) {
            $parts = $line -split "`t"
            if ($parts.Count -ge 2) {
                $galera[$parts[0]] = $parts[1]
            }
        }
        $galeraOk = ($galera["wsrep_cluster_size"] -eq "3") -and
                    ($galera["wsrep_cluster_status"] -eq "Primary") -and
                    ($galera["wsrep_local_state_comment"] -eq "Synced")
        $galeraDetail = "size=$($galera['wsrep_cluster_size']) status=$($galera['wsrep_cluster_status']) state=$($galera['wsrep_local_state_comment'])"
        $checks.Add((New-Check -Name "Galera" -Passed $galeraOk -Detail $galeraDetail))
    } else {
        $checks.Add((New-Check -Name "Galera" -Passed $false -Detail "MARIADB_ROOT_PASSWORD no encontrada en $ComposeEnvFile"))
    }

    # VIPs
    $vipSpecs = @(
        @{ Layer = "Presentacion"; Master = "presentation-lb-master"; Backup = "presentation-lb-backup"; Vip = "172.30.0.250" },
        @{ Layer = "Aplicacion"; Master = "application-lb-master"; Backup = "application-lb-backup"; Vip = "172.31.0.250" }
    )

    foreach ($spec in $vipSpecs) {
        $onMaster = $false
        $onBackup = $false
        $masterAddresses = & docker exec "distributed-three-tier-$($spec.Master)-1" ip -o -4 addr show 2>$null
        if (($masterAddresses -join "`n") -match [regex]::Escape($spec.Vip)) {
            $onMaster = $true
        }
        $backupAddresses = & docker exec "distributed-three-tier-$($spec.Backup)-1" ip -o -4 addr show 2>$null
        if (($backupAddresses -join "`n") -match [regex]::Escape($spec.Vip)) {
            $onBackup = $true
        }

        if ($onMaster) {
            $checks.Add((New-Check -Name "VIP $($spec.Layer)" -Passed $true -Detail "$($spec.Vip) en $($spec.Master)"))
        } elseif ($onBackup) {
            $checks.Add((New-Check -Name "VIP $($spec.Layer)" -Passed $true -Detail "$($spec.Vip) en $($spec.Backup) (failover activo)"))
        } else {
            $checks.Add((New-Check -Name "VIP $($spec.Layer)" -Passed $false -Detail "$($spec.Vip) no esta en master ni backup"))
        }
    }

    # Nagios
    $nagiosPort = Test-TcpPort -TargetHost "127.0.0.1" -Port 8088
    $checks.Add((New-Check -Name "Nagios 127.0.0.1:8088" -Passed $nagiosPort -Detail $(if ($nagiosPort) { "TCP acepta conexiones" } else { "sin conexion" })))

    return $checks
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$checks = $null
do {
    $checks = Get-StackSnapshot
    $pending = @($checks | Where-Object { -not $_.Passed })
    if ($pending.Count -eq 0) {
        break
    }
    if ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
    }
} while ((Get-Date) -lt $deadline)

if ($Json) {
    $checks | ConvertTo-Json -Depth 4
} else {
    foreach ($check in $checks) {
        $label = if ($check.Passed) { "PASS" } else { "FAIL" }
        "[{0}] {1,-32} {2}" -f $label, $check.Name, $check.Detail
    }

    $failed = @($checks | Where-Object { -not $_.Passed })
    ""
    if ($failed.Count -eq 0) {
        "Resultado: LISTO para la demo ($($checks.Count) comprobaciones)."
    } else {
        "Resultado: NO LISTO ($($failed.Count) de $($checks.Count) comprobaciones fallaron)."
        foreach ($check in $failed) {
            "  - {0}: {1}" -f $check.Name, $check.Detail
        }
    }
}

if (@($checks | Where-Object { -not $_.Passed }).Count -gt 0) {
    exit 1
}
exit 0
