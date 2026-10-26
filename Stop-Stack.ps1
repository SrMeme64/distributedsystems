[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [string]$ComposeEnvFile = ".env.exam",

    [ValidateRange(30, 900)]
    [int]$TimeoutSeconds = 300,

    [switch]$StopDockerDesktop,

    [string]$LogPath = ""
)

# Graceful shutdown of the whole stack.
#
# `docker compose stop` sends SIGTERM and respects stop_grace_period (60 s for
# each Galera node), so MariaDB closes cleanly. It does NOT remove containers:
# on the next boot `restart: always` brings them back automatically.
#
# Do not use `docker compose down` before shutting the laptop down unless you
# plan to run Start-Stack.ps1 next time: `down` removes the containers and
# `restart: always` cannot recreate them.

$repositoryRoot = $PSScriptRoot
$envFilePath = Join-Path $repositoryRoot $ComposeEnvFile

if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
    throw "No se encontro el archivo de entorno de Compose: $envFilePath"
}

function Write-Log {
    param([string]$Message)

    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    if ($LogPath) {
        $logDirectory = Split-Path -Parent $LogPath
        if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
}

function Test-DockerDaemon {
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-RunningServices {
    $lines = & docker compose --env-file $ComposeEnvFile ps --format "{{.Service}}|{{.Status}}" 2>$null
    return @($lines | Where-Object { $_ -match "\|Up" } | ForEach-Object { ($_ -split "\|")[0] })
}

Push-Location $repositoryRoot
try {
    Write-Log "=== Apagado ordenado del stack ($ComposeEnvFile) ==="

    if (-not (Test-DockerDaemon)) {
        Write-Log "Docker no esta en ejecucion: los contenedores ya estan detenidos."
        exit 0
    }

    $running = Get-RunningServices
    if ($running.Count -eq 0) {
        Write-Log "No hay servicios en ejecucion; no hay cambios."
    } else {
        Write-Log ("Servicios en ejecucion: {0}" -f ($running -join ", "))
        $target = "detener $($running.Count) servicio(s) con SIGTERM y stop_grace_period"
        if ($PSCmdlet.ShouldProcess("stack ($ComposeEnvFile)", $target)) {
            Write-Log "Ejecutando: docker compose --env-file $ComposeEnvFile stop"
            & docker compose --env-file $ComposeEnvFile stop 2>&1 |
                ForEach-Object { Write-Log ([string]$_) }
            if ($LASTEXITCODE -ne 0) {
                Write-Log "ERROR: docker compose stop fallo (exit $LASTEXITCODE)."
                exit 1
            }
        } else {
            Write-Log "Sin cambios (-WhatIf)."
            exit 0
        }
    }

    Write-Log "Comprobando que no quede ningun servicio en ejecucion..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $stillRunning = Get-RunningServices
        if ($stillRunning.Count -eq 0) {
            break
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    if ($stillRunning.Count -gt 0) {
        Write-Log ("ERROR: siguen en ejecucion: {0}" -f ($stillRunning -join ", "))
        exit 1
    }

    Write-Log "Todos los servicios de larga duracion estan detenidos."
    Write-Log "Los datos de Galera y MongoDB siguen en sus volumenes; Redis se reconstruye al arrancar."

    if ($StopDockerDesktop) {
        if ($PSCmdlet.ShouldProcess("Docker Desktop", "Detener Docker Desktop")) {
            Write-Log "Deteniendo Docker Desktop..."
            & docker desktop stop 2>&1 | ForEach-Object { Write-Log ([string]$_) }
            if ($LASTEXITCODE -ne 0) {
                Write-Log "AVISO: docker desktop stop devolvio exit $LASTEXITCODE."
            }
        }
    }

    Write-Log ""
    Write-Log "Siguiente paso: ya puedes apagar Windows con normalidad."
    Write-Log "Para volver a arrancar: .\Start-Stack.ps1 (o inicia sesion y espera el arranque automatico)."
    Write-Log "=== Apagado completado ==="
    exit 0
} finally {
    Pop-Location
}
