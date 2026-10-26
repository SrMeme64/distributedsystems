[CmdletBinding()]
param(
    [string]$ComposeEnvFile = ".env.exam",

    [switch]$Build,

    [switch]$NoWait,

    [ValidateRange(30, 900)]
    [int]$TimeoutSeconds = 300,

    [string]$LogPath = ""
)

# Starts the whole stack after a reboot or a Docker Desktop restart.
#
# 1. Waits for the Docker daemon, starting Docker Desktop if necessary.
# 2. Runs `docker compose up -d` so every service and one-shot init job exists.
# 3. Waits for the readiness checks in PoCs/Test-StackHealth.ps1.
#
# Exit code 0 = stack ready. Use it from a Startup shortcut or a scheduled task.

$repositoryRoot = $PSScriptRoot
$envFilePath = Join-Path $repositoryRoot $ComposeEnvFile
$healthScript = Join-Path $repositoryRoot "PoCs\Test-StackHealth.ps1"

if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
    throw "No se encontro el archivo de entorno de Compose: $envFilePath"
}
if (-not (Test-Path -LiteralPath $healthScript -PathType Leaf)) {
    throw "No se encontro el script de verificacion: $healthScript"
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

function Start-DockerDesktop {
    Write-Log "El daemon de Docker no responde; intentando iniciar Docker Desktop."

    & docker desktop start *> $null
    if ($LASTEXITCODE -ne 0) {
        $desktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        if (Test-Path -LiteralPath $desktopExe) {
            Write-Log "Usando $desktopExe"
            Start-Process -FilePath $desktopExe | Out-Null
        } else {
            Write-Log "No se encontro Docker Desktop.exe; inicia Docker Desktop manualmente."
            return $false
        }
    }

    $deadline = (Get-Date).AddSeconds(180)
    do {
        if (Test-DockerDaemon) {
            Write-Log "Docker daemon disponible."
            return $true
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    Write-Log "Docker no respondio en 180 s."
    return $false
}

Push-Location $repositoryRoot
try {
    Write-Log "=== Inicio del stack ($ComposeEnvFile) ==="

    if (-not (Test-DockerDaemon)) {
        if (-not (Start-DockerDesktop)) {
            Write-Log "ERROR: no se pudo iniciar el daemon de Docker."
            exit 1
        }
    } else {
        Write-Log "Docker daemon disponible."
    }

    $composeArguments = @("compose", "--env-file", $ComposeEnvFile, "up", "-d")
    if ($Build) {
        $composeArguments += "--build"
    }

    Write-Log ("Ejecutando: docker " + ($composeArguments -join " "))
    & docker @composeArguments 2>&1 | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: docker compose up fallo (exit $LASTEXITCODE)."
        exit 1
    }

    if ($NoWait) {
        Write-Log "Stack lanzado (-NoWait)."
        exit 0
    }

    Write-Log "Esperando readiness (hasta $TimeoutSeconds s)..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File $healthScript `
        -ComposeEnvFile $ComposeEnvFile -TimeoutSeconds $TimeoutSeconds 2>&1 |
        ForEach-Object {
            Write-Host $_
            if ($LogPath) {
                Add-Content -LiteralPath $LogPath -Value $_ -Encoding UTF8
            }
        }
    $healthExit = $LASTEXITCODE

    if ($healthExit -eq 0) {
        Write-Log "=== Stack listo para la demo ==="
    } else {
        Write-Log "=== Stack NO listo (exit $healthExit) ==="
    }

    exit $healthExit
} finally {
    Pop-Location
}
