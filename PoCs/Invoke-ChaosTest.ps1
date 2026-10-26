[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [ValidateSet("app1", "app2", "app3")]
    [string]$Target,

    [ValidateRange(5, 300)]
    [int]$HoldSeconds = 15,

    [string]$ComposeEnvFile = ".env.exam"
)

# PoC 3: stops one API node for HoldSeconds and always restores it.
# Run this on the host while the client runs Monitor-LanHealth.ps1.
# The finally block restores the node even if you press Ctrl+C.

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

    $lines = & docker compose --env-file $ComposeEnvFile ps --format "{{.Service}}|{{.Status}}" 2>$null
    $lines | Where-Object { $_ -like "$Service|*" } | Select-Object -First 1
}

Write-Host "Nodo seleccionado: $Target"
Write-Host "Inicio: $((Get-Date).ToString('HH:mm:ss'))  (mantener caido $HoldSeconds s)"

$stopped = $false
Push-Location $repositoryRoot
try {
    if ($PSCmdlet.ShouldProcess($Target, "Detener $HoldSeconds s y volver a iniciar")) {
        & docker compose --env-file $ComposeEnvFile stop $Target | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose stop $Target fallo (exit $LASTEXITCODE)"
        }
        $stopped = $true
        Write-Host "Detenido: $((Get-Date).ToString('HH:mm:ss'))  $Target"

        Start-Sleep -Seconds $HoldSeconds
    }
}
finally {
    if ($stopped) {
        # Always restore, even on Ctrl+C or an error in the try block.
        Write-Host "Restaurando: $((Get-Date).ToString('HH:mm:ss'))  $Target"

        # up -d --no-deps starts only this container. `docker compose start`
        # also re-runs the one-shot init services (db-bootstrap, mongo-init,
        # catalog-init), which is slow and unnecessary for a chaos test.
        & docker compose --env-file $ComposeEnvFile up -d --no-deps $Target | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "up -d --no-deps fallo (exit $LASTEXITCODE); probando docker start"
            & docker start "distributed-three-tier-$Target-1" | Out-Host
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "docker start tambien fallo (exit $LASTEXITCODE)"
            }
        }

        # HAProxy needs two successful checks (rise 2, 2 s interval).
        $deadline = (Get-Date).AddSeconds(25)
        $upLog = $null
        while (-not $upLog -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $upLog = & docker logs --tail 200 distributed-three-tier-application-lb-master-1 2>&1 |
                Select-String -Pattern "application_nodes/$Target is UP" |
                Select-Object -Last 1
        }

        $status = Get-ServiceStatus -Service $Target
        if ($status) {
            Write-Host "Estado: $status"
        } else {
            Write-Warning "No se pudo leer el estado de $Target"
        }

        if ($upLog) {
            Write-Host "HAProxy: $($upLog.Line.Trim())"
        } else {
            Write-Warning "HAProxy aun no reporta $Target como UP; revisa docker logs distributed-three-tier-application-lb-master-1"
        }
    } else {
        Write-Host "Sin cambios: no se detuvo $Target"
    }

    Pop-Location
}
