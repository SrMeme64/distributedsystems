[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [ValidateSet("All", "Api", "Presentation", "Application")]
    [string]$Layer = "All",

    [ValidateSet("app1", "app2", "app3")]
    [string]$Target = "app1",

    [ValidateRange(1, 300)]
    [int]$HoldSeconds = 12,

    [ValidateRange(5, 180)]
    [int]$TransitionTimeoutSeconds = 35,

    [string]$HealthUri = "http://localhost/api/health",

    [string]$ComposeEnvFile = ".env.exam"
)

# PoC 2: failover por capas.
#
# Con -Layer All (valor por defecto) ejecuta, en este orden:
#   1. Api          : detiene un nodo API y comprueba que HAProxy lo retira.
#   2. Presentation : pausa presentation-lb-master y comprueba que Keepalived
#                     mueve el VIP al backup.
#   3. Application  : pausa application-lb-master y comprueba el mismo failover
#                     en la capa de aplicacion.
#
# El cliente ejecuta Monitor-LanHealth.ps1 en paralelo para capturar la traza
# X-Request-Trace y ver el cambio de master a backup y el regreso.
#
# Los HAProxy se PAUSAN, no se detienen: el sidecar Keepalived comparte su
# network namespace y pausar conserva ese namespace para que el VIP pueda
# migrar. Cada fase restaura lo que cambio, incluso con Ctrl+C.

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envFilePath = Join-Path $repositoryRoot $ComposeEnvFile
if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
    throw "No se encontro el archivo de entorno de Compose: $envFilePath"
}

$chaosScript = Join-Path $PSScriptRoot "Invoke-ChaosTest.ps1"
if (-not (Test-Path -LiteralPath $chaosScript -PathType Leaf)) {
    throw "No se encontro el script de caos: $chaosScript"
}

function Invoke-HealthProbe {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $HealthUri -TimeoutSec 4
        [pscustomobject]@{
            Success    = ([int]$response.StatusCode -eq 200)
            StatusCode = [int]$response.StatusCode
            Trace      = [string]$response.Headers["X-Request-Trace"]
            Error      = $null
        }
    } catch {
        [pscustomobject]@{
            Success    = $false
            StatusCode = $null
            Trace      = $null
            Error      = $_.Exception.Message
        }
    }
}

function Get-ContainerPaused {
    param([string]$Service)

    $value = & docker inspect -f "{{.State.Paused}}" "distributed-three-tier-$Service-1" 2>$null
    return ([string]$value).Trim() -eq "true"
}

function Set-MasterRunning {
    # Idempotente: reanuda el master si una ejecucion anterior lo dejo pausado.
    param([string]$MasterService)

    if (Get-ContainerPaused -Service $MasterService) {
        & docker compose --env-file $ComposeEnvFile unpause $MasterService *> $null
        return ($LASTEXITCODE -eq 0)
    }
    return $true
}

function Wait-ForTrace {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedBalancer,
        [Parameter(Mandatory = $true)][datetime]$Deadline,
        [switch]$Quiet
    )

    $observedAt = $null
    $errors = 0
    $lastTrace = $null

    do {
        $probe = Invoke-HealthProbe
        $timestamp = Get-Date

        if ($probe.Success -and $probe.Trace -like "*$ExpectedBalancer*") {
            if (-not $Quiet) {
                "{0} HTTP {1} {2}" -f $timestamp.ToString("HH:mm:ss.fff"), $probe.StatusCode, $probe.Trace
            }
            $observedAt = $timestamp
            $lastTrace = $probe.Trace
            break
        }

        if (-not $probe.Success) {
            $errors++
        }

        if (-not $Quiet) {
            if ($probe.Success) {
                "{0} HTTP {1} esperando {2}; {3}" -f $timestamp.ToString("HH:mm:ss.fff"), $probe.StatusCode, $ExpectedBalancer, $probe.Trace
            } else {
                "{0} ERROR esperando {1}; {2}" -f $timestamp.ToString("HH:mm:ss.fff"), $ExpectedBalancer, $probe.Error
            }
        }

        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $Deadline)

    [pscustomobject]@{
        Found     = ($null -ne $observedAt)
        At        = $observedAt
        Errors    = $errors
        LastTrace = $lastTrace
    }
}

function New-PhaseResult {
    param(
        [string]$Phase,
        [string]$Status,
        [string]$Detail
    )

    [pscustomobject]@{
        Phase  = $Phase
        Status = $Status
        Detail = $Detail
    }
}

function Invoke-ApiPhase {
    Write-Host ""
    Write-Host "--- Fase 1/3: failover de nodo API ($Target) ---"

    $null = Set-MasterRunning -MasterService "presentation-lb-master"
    $null = Set-MasterRunning -MasterService "application-lb-master"

    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $chaosScript,
        "-Target", $Target,
        "-HoldSeconds", "$HoldSeconds",
        "-ComposeEnvFile", $ComposeEnvFile
    )
    if ($WhatIfPreference) {
        $arguments += "-WhatIf"
    }

    $output = & powershell @arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in @($output)) {
        Write-Host ([string]$line)
    }

    $text = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
    $down = "no observado"
    if ($text -match "DOWN observado:\s*([0-9.,]+)\s*s") {
        $down = "$($matches[1]) s"
    }

    if ($WhatIfPreference) {
        return New-PhaseResult -Phase "API $Target" -Status "SIN CAMBIOS" -Detail "WhatIf"
    }
    if ($exitCode -eq 0) {
        return New-PhaseResult -Phase "API $Target" -Status "PASS" -Detail "DOWN $down"
    }
    return New-PhaseResult -Phase "API $Target" -Status "FAIL" -Detail "el script de caos devolvio exit $exitCode"
}

function Invoke-LbPhase {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Presentation", "Application")]
        [string]$LayerName
    )

    if ($LayerName -eq "Presentation") {
        $masterService = "presentation-lb-master"
        $backupService = "presentation-lb-backup"
    } else {
        $masterService = "application-lb-master"
        $backupService = "application-lb-backup"
    }

    Write-Host ""
    Write-Host "--- Failover de $masterService -> $backupService ---"

    $masterPaused = $false
    try {
        if (-not (Set-MasterRunning -MasterService $masterService)) {
            return New-PhaseResult -Phase $masterService -Status "FAIL" -Detail "no se pudo reanudar el master antes de la prueba"
        }

        $baselineDeadline = (Get-Date).AddSeconds($TransitionTimeoutSeconds)
        $baseline = Wait-ForTrace -ExpectedBalancer $masterService -Deadline $baselineDeadline -Quiet
        if (-not $baseline.Found) {
            return New-PhaseResult -Phase $masterService -Status "FAIL" -Detail "la API no responde por el master; ultima traza: $($baseline.LastTrace)"
        }
        Write-Host "Estado inicial: HTTP 200 $($baseline.LastTrace)"

        $action = "Pausar $masterService durante la PoC y comprobar failover/failback"
        if (-not $PSCmdlet.ShouldProcess($masterService, $action)) {
            return New-PhaseResult -Phase $masterService -Status "SIN CAMBIOS" -Detail "WhatIf"
        }

        $pauseStarted = Get-Date
        & docker compose --env-file $ComposeEnvFile pause $masterService *> $null
        if ($LASTEXITCODE -ne 0) {
            return New-PhaseResult -Phase $masterService -Status "FAIL" -Detail "no se pudo pausar (exit $LASTEXITCODE)"
        }
        $masterPaused = $true
        Write-Host "Master pausado: $($pauseStarted.ToString('HH:mm:ss.fff'))  $masterService"

        $failover = Wait-ForTrace -ExpectedBalancer $backupService -Deadline $pauseStarted.AddSeconds($TransitionTimeoutSeconds)
        if (-not $failover.Found) {
            return New-PhaseResult -Phase $masterService -Status "FAIL" -Detail "no se observo el backup antes del timeout"
        }
        $failoverSeconds = [Math]::Round(($failover.At - $pauseStarted).TotalSeconds, 2)
        Write-Host ("Failover observado en {0:N2} s con {1} error(es) de convergencia." -f $failoverSeconds, $failover.Errors)

        $holdDeadline = $pauseStarted.AddSeconds($HoldSeconds)
        while ((Get-Date) -lt $holdDeadline) {
            $probe = Invoke-HealthProbe
            if ($probe.Success) {
                "{0} HTTP {1} {2}" -f (Get-Date).ToString("HH:mm:ss.fff"), $probe.StatusCode, $probe.Trace
            } else {
                "{0} ERROR {1}" -f (Get-Date).ToString("HH:mm:ss.fff"), $probe.Error
            }
            Start-Sleep -Seconds 1
        }

        $unpauseStarted = Get-Date
        & docker compose --env-file $ComposeEnvFile unpause $masterService *> $null
        if ($LASTEXITCODE -ne 0) {
            return New-PhaseResult -Phase $masterService -Status "FAIL" -Detail "no se pudo reanudar el master"
        }
        $masterPaused = $false
        Write-Host "Master reanudado: $($unpauseStarted.ToString('HH:mm:ss.fff'))  $masterService"

        $failback = Wait-ForTrace -ExpectedBalancer $masterService -Deadline $unpauseStarted.AddSeconds($TransitionTimeoutSeconds)
        if (-not $failback.Found) {
            return New-PhaseResult -Phase $masterService -Status "FAIL" -Detail "no se observo el failback antes del timeout"
        }
        $failbackSeconds = [Math]::Round(($failback.At - $unpauseStarted).TotalSeconds, 2)
        Write-Host ("Failback observado en {0:N2} s con {1} error(es) de convergencia." -f $failbackSeconds, $failback.Errors)

        return New-PhaseResult -Phase $masterService -Status "PASS" -Detail ("failover {0:N2} s, failback {1:N2} s" -f $failoverSeconds, $failbackSeconds)
    } catch {
        return New-PhaseResult -Phase $masterService -Status "FAIL" -Detail $_.Exception.Message
    } finally {
        if ($masterPaused) {
            & docker compose --env-file $ComposeEnvFile unpause $masterService *> $null
            if ($LASTEXITCODE -eq 0) {
                $restore = Wait-ForTrace -ExpectedBalancer $masterService -Deadline (Get-Date).AddSeconds(15) -Quiet
                if ($restore.Found) {
                    Write-Host "Restaurado: $masterService vuelve a recibir trafico."
                } else {
                    Write-Warning "Se reanudo $masterService, pero la traza aun no lo confirma."
                }
            } else {
                Write-Warning "No se pudo reanudar $masterService. Usa: docker compose --env-file $ComposeEnvFile unpause $masterService"
            }
        }
    }
}

$phases = switch ($Layer) {
    "All" { @("Api", "Presentation", "Application") }
    default { @($Layer) }
}

Push-Location $repositoryRoot
try {
    Write-Host "=== PoC 2: failover por capas ==="
    Write-Host "Fases: $($phases -join ', ')"
    Write-Host "Duracion de cada falla: $HoldSeconds s"

    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($phase in $phases) {
        switch ($phase) {
            "Api" { $results.Add((Invoke-ApiPhase)) }
            "Presentation" { $results.Add((Invoke-LbPhase -LayerName "Presentation")) }
            "Application" { $results.Add((Invoke-LbPhase -LayerName "Application")) }
        }
    }

    Write-Host ""
    Write-Host "=================================================================="
    Write-Host "Resumen PoC 2"
    foreach ($result in $results) {
        Write-Host ("  [{0}] {1,-32} {2}" -f $result.Status, $result.Phase, $result.Detail)
    }

    $failed = @($results | Where-Object { $_.Status -eq "FAIL" })
    $changed = @($results | Where-Object { $_.Status -ne "SIN CAMBIOS" })
    Write-Host ""
    if ($failed.Count -gt 0) {
        Write-Host "Resultado global: FAIL ($($failed.Count) fase(s))"
        exit 1
    }
    if ($changed.Count -eq 0) {
        Write-Host "Resultado global: SIN CAMBIOS (-WhatIf)"
        exit 0
    }
    Write-Host "Resultado global: PASS"
    exit 0
} finally {
    Pop-Location
}
