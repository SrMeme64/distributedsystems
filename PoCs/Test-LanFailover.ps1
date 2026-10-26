[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Presentation", "Application")]
    [string]$Layer,

    [ValidateRange(1, 300)]
    [int]$HoldSeconds = 12,

    [ValidateRange(5, 180)]
    [int]$TransitionTimeoutSeconds = 35,

    [string]$HealthUri = "http://localhost/api/health",

    [string]$ComposeEnvFile = ".env.exam"
)

# PoC 4/5: pause the selected HAProxy master and verify that Keepalived moves
# the VIP to the backup, then unpause it and verify the failback.
#
# The master container is paused (not stopped) because the Keepalived sidecar
# shares its network namespace. Pausing freezes HAProxy but keeps the namespace
# and the VIP alive, so the sidecar can still demote itself and the backup can
# take over.

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envFilePath = Join-Path $repositoryRoot $ComposeEnvFile
if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
    throw "No se encontro el archivo de entorno de Compose: $envFilePath"
}

if ($Layer -eq "Presentation") {
    $masterService = "presentation-lb-master"
    $backupService = "presentation-lb-backup"
} else {
    $masterService = "application-lb-master"
    $backupService = "application-lb-backup"
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
    # Idempotent: unpause the master if a previous run left it paused.
    if (Get-ContainerPaused -Service $masterService) {
        & docker compose --env-file $ComposeEnvFile unpause $masterService *> $null
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
        Found    = ($null -ne $observedAt)
        At       = $observedAt
        Errors   = $errors
        LastTrace = $lastTrace
    }
}

$masterPaused = $false
$failover = $null
$failback = $null
$exitCode = 0

try {
    Push-Location $repositoryRoot

    if (-not (Set-MasterRunning)) {
        throw "No se pudo reanudar $masterService antes de la prueba."
    }

    $baselineDeadline = (Get-Date).AddSeconds($TransitionTimeoutSeconds)
    $baseline = Wait-ForTrace -ExpectedBalancer $masterService -Deadline $baselineDeadline -Quiet
    if (-not $baseline.Found) {
        throw "Precondicion fallida: la API no responde por $masterService en $TransitionTimeoutSeconds s. Ultima traza: $($baseline.LastTrace)"
    }
    "Estado inicial: HTTP 200 $($baseline.LastTrace)"

    $action = "Pausar $masterService durante la PoC y comprobar failover/failback"
    if (-not $PSCmdlet.ShouldProcess($masterService, $action)) {
        return
    }

    $pauseStarted = Get-Date
    & docker compose --env-file $ComposeEnvFile pause $masterService *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo pausar $masterService (exit $LASTEXITCODE)."
    }
    $masterPaused = $true
    "Master pausado: $($pauseStarted.ToString('HH:mm:ss.fff'))  $masterService"

    $failover = Wait-ForTrace -ExpectedBalancer $backupService -Deadline $pauseStarted.AddSeconds($TransitionTimeoutSeconds)
    if (-not $failover.Found) {
        throw "No se observo HTTP 200 por $backupService antes del timeout ($TransitionTimeoutSeconds s)."
    }

    $failoverSeconds = [Math]::Round(($failover.At - $pauseStarted).TotalSeconds, 2)
    "Failover observado en {0:N2} s con {1} error(es) de convergencia." -f $failoverSeconds, $failover.Errors

    $holdDeadline = $pauseStarted.AddSeconds($HoldSeconds)
    while ((Get-Date) -lt $holdDeadline) {
        $probe = Invoke-HealthProbe
        $timestamp = Get-Date
        if ($probe.Success) {
            "{0} HTTP {1} {2}" -f $timestamp.ToString("HH:mm:ss.fff"), $probe.StatusCode, $probe.Trace
        } else {
            "{0} ERROR {1}" -f $timestamp.ToString("HH:mm:ss.fff"), $probe.Error
        }
        Start-Sleep -Seconds 1
    }

    $unpauseStarted = Get-Date
    & docker compose --env-file $ComposeEnvFile unpause $masterService *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo reanudar $masterService (exit $LASTEXITCODE); revisa el contenedor."
    }
    $masterPaused = $false
    "Master reanudado: $($unpauseStarted.ToString('HH:mm:ss.fff'))  $masterService"

    $failback = Wait-ForTrace -ExpectedBalancer $masterService -Deadline $unpauseStarted.AddSeconds($TransitionTimeoutSeconds)
    if (-not $failback.Found) {
        throw "No se observo el failback a $masterService antes del timeout ($TransitionTimeoutSeconds s)."
    }

    $failbackSeconds = [Math]::Round(($failback.At - $unpauseStarted).TotalSeconds, 2)
    "Failback observado en {0:N2} s con {1} error(es) de convergencia." -f $failbackSeconds, $failback.Errors

    ""
    "Resumen $Layer :"
    "  Failover $masterService -> $backupService : {0:N2} s ({1} errores)" -f $failoverSeconds, $failover.Errors
    "  Failback $backupService -> $masterService : {0:N2} s ({1} errores)" -f $failbackSeconds, $failback.Errors
    "  Resultado: PASS"
} catch {
    $exitCode = 1
    ""
    "Resultado: FAIL - $($_.Exception.Message)"
} finally {
    if ($masterPaused) {
        & docker compose --env-file $ComposeEnvFile unpause $masterService *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "No se pudo reanudar $masterService automaticamente. Restauralo con: docker compose --env-file $ComposeEnvFile unpause $masterService"
        } else {
            $restore = Wait-ForTrace -ExpectedBalancer $masterService -Deadline (Get-Date).AddSeconds(15) -Quiet
            if ($restore.Found) {
                "Restaurado: $masterService vuelve a recibir trafico."
            } else {
                Write-Warning "Se reanudo $masterService, pero la traza aun no lo confirma. Revisa docker logs distributed-three-tier-$masterService-1"
            }
        }
    }

    Pop-Location
}

exit $exitCode
