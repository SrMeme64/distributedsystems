[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [ValidateSet("app1", "app2", "app3")]
    [string]$Target,

    [ValidateRange(5, 300)]
    [int]$HoldSeconds = 15,

    [string]$HealthUri = "http://localhost/api/health",

    [string]$ComposeEnvFile = ".env.exam"
)

# PoC 2/3: stop one API node, verify that HAProxy marks it DOWN while the other
# two keep serving, then always restore it and verify that HAProxy marks it UP.
# Run this on the host while the client runs Monitor-LanHealth.ps1 or
# Invoke-ClientPocSuite.ps1. The finally block restores the node even on Ctrl+C.

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envFilePath = Join-Path $repositoryRoot $ComposeEnvFile
if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
    throw "No se encontro el archivo de entorno de Compose: $envFilePath"
}

if (-not $Target) {
    $Target = Get-Random -InputObject @("app1", "app2", "app3")
}

function Get-ServiceStatus {
    param([string]$Service)

    $lines = & docker compose --env-file $ComposeEnvFile ps -a --format "{{.Service}}|{{.Status}}" 2>$null
    $lines | Where-Object { $_ -like "$Service|*" } | Select-Object -First 1
}

function Wait-ForServiceUp {
    param(
        [string]$Service,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $status = Get-ServiceStatus -Service $Service
        if ($status -and $status -match "\|Up") {
            return $status
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    return (Get-ServiceStatus -Service $Service)
}

function Get-HaproxyEvent {
    param(
        [string]$Pattern,
        [int]$Tail = 400
    )

    & docker logs --tail $Tail distributed-three-tier-application-lb-master-1 2>&1 |
        Select-String -Pattern $Pattern |
        Select-Object -Last 1
}

function Invoke-HealthProbe {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $HealthUri -TimeoutSec 4
        [pscustomobject]@{
            Success = ([int]$response.StatusCode -eq 200)
            StatusCode = [int]$response.StatusCode
            Trace = [string]$response.Headers["X-Request-Trace"]
            Error = $null
        }
    } catch {
        [pscustomobject]@{
            Success = $false
            StatusCode = $null
            Trace = $null
            Error = $_.Exception.Message
        }
    }
}

Write-Host "Nodo seleccionado: $Target"
Write-Host "Inicio: $((Get-Date).ToString('HH:mm:ss'))  (mantener caido $HoldSeconds s)"

$stopped = $false
$stoppedAt = $null
$downEvent = $null
$downAt = $null
$upEvent = $null
$upAt = $null
$probesWhileDown = 0
$okWhileDown = 0
$errorsWhileDown = 0
$finalTrace = $null
$restoreOk = $false
$exitCode = 0

Push-Location $repositoryRoot
try {
    $status = Wait-ForServiceUp -Service $Target -TimeoutSeconds 20
    if (-not $status -or $status -notmatch "\|Up") {
        throw "Precondicion fallida: $Target no esta Up ($status)."
    }
    Write-Host "Estado inicial: $status"

    if ($PSCmdlet.ShouldProcess($Target, "Detener $HoldSeconds s y volver a iniciar")) {
        & docker compose --env-file $ComposeEnvFile stop $Target *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose stop $Target fallo (exit $LASTEXITCODE)"
        }
        $stopped = $true
        $stoppedAt = Get-Date
        Write-Host "Detenido: $($stoppedAt.ToString('HH:mm:ss.fff'))  $Target"

        $holdDeadline = $stoppedAt.AddSeconds($HoldSeconds)
        $downPattern = "application_nodes/$Target is DOWN"

        while ((Get-Date) -lt $holdDeadline) {
            if (-not $downEvent) {
                $downEvent = Get-HaproxyEvent -Pattern $downPattern
                if ($downEvent) {
                    $downAt = Get-Date
                    Write-Host "HAProxy: $($downEvent.Line.Trim())"
                }
            }

            $probe = Invoke-HealthProbe
            $probesWhileDown++
            if ($probe.Success) {
                $okWhileDown++
                $finalTrace = $probe.Trace
                if ($probe.Trace -like "*$Target*") {
                    Write-Warning "Una respuesta aun pasa por $Target (convergencia en curso): $($probe.Trace)"
                }
            } else {
                $errorsWhileDown++
            }

            Start-Sleep -Seconds 1
        }

        if (-not $downEvent) {
            Write-Warning "HAProxy no marco $Target como DOWN en $HoldSeconds s. Usa -HoldSeconds 12 o mas para ver la transicion."
        }
    }
} catch {
    $exitCode = 1
    Write-Host "Resultado: FAIL - $($_.Exception.Message)"
} finally {
    if ($stopped) {
        # Always restore, even on Ctrl+C or an error in the try block.
        Write-Host "Restaurando: $((Get-Date).ToString('HH:mm:ss.fff'))  $Target"

        # up -d --no-deps starts only this container. `docker compose start`
        # also re-runs the one-shot init services (db-bootstrap, mongo-init,
        # catalog-init), which is slow and unnecessary for a chaos test.
        & docker compose --env-file $ComposeEnvFile up -d --no-deps $Target *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "up -d --no-deps fallo (exit $LASTEXITCODE); probando docker start"
            & docker start "distributed-three-tier-$Target-1" *> $null
        }

        $status = Wait-ForServiceUp -Service $Target -TimeoutSeconds 30
        if ($status -and $status -match "\|Up") {
            Write-Host "Estado: $status"
        } else {
            $exitCode = 1
            Write-Warning "No se pudo recuperar $Target ($status)."
        }

        # HAProxy needs two successful checks (rise 2, 2 s interval).
        $upPattern = "application_nodes/$Target is UP"
        $deadline = (Get-Date).AddSeconds(30)
        while (-not $upEvent -and (Get-Date) -lt $deadline) {
            $upEvent = Get-HaproxyEvent -Pattern $upPattern
            if (-not $upEvent) {
                Start-Sleep -Seconds 2
            }
        }
        if ($upEvent) {
            $upAt = Get-Date
            Write-Host "HAProxy: $($upEvent.Line.Trim())"
        } else {
            $exitCode = 1
            Write-Warning "HAProxy aun no reporta $Target como UP; revisa docker logs distributed-three-tier-application-lb-master-1"
        }

        if ($status -and $status -match "\|Up" -and $upEvent) {
            $restoreOk = $true
        }

        # Confirm that the restored node is back in the round robin.
        $seen = $false
        for ($i = 1; $i -le 12; $i++) {
            $probe = Invoke-HealthProbe
            if ($probe.Success) {
                $finalTrace = $probe.Trace
                if ($probe.Trace -like "*$Target*") {
                    $seen = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 700
        }
        if (-not $seen) {
            Write-Warning "No se observo $Target en la traza tras la recuperacion. Ultima traza: $finalTrace"
        }
    } else {
        Write-Host "Sin cambios: no se detuvo $Target"
    }

    Pop-Location
}

Write-Host ""
Write-Host "Resumen $Target :"
if ($downEvent -and $stoppedAt) {
    Write-Host ("  DOWN observado: {0:N2} s" -f ($downAt - $stoppedAt).TotalSeconds)
} else {
    Write-Host "  DOWN observado: no (ventana demasiado corta)"
}
if ($upEvent -and $stoppedAt) {
    Write-Host ("  UP observado tras restaurar: {0:N2} s" -f ($upAt - $stoppedAt).TotalSeconds)
} else {
    Write-Host "  UP observado tras restaurar: no"
}
Write-Host ("  Probes durante la caida: {0} ({1} OK, {2} errores)" -f $probesWhileDown, $okWhileDown, $errorsWhileDown)
Write-Host "  Traza final: $finalTrace"
if (-not $stopped) {
    Write-Host "  Resultado: SIN CAMBIOS (-WhatIf)"
} elseif ($exitCode -ne 0) {
    Write-Host "  Resultado: FAIL"
} elseif (-not $downEvent) {
    Write-Host "  Resultado: WARN (nodo restaurado, pero no se observo el DOWN)"
} elseif ($okWhileDown -eq 0) {
    Write-Host "  Resultado: WARN (nodo restaurado, pero no hubo respuestas 200 durante la caida)"
} else {
    Write-Host "  Resultado: PASS"
}

exit $exitCode
