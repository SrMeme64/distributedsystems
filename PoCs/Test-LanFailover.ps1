[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Presentation", "Application")]
    [string]$Layer,

    [ValidateRange(1, 300)]
    [int]$HoldSeconds = 12,

    [ValidateRange(5, 180)]
    [int]$TransitionTimeoutSeconds = 35,

    [string]$ComposeEnvFile = ".env.exam"
)

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envFilePath = Join-Path $repositoryRoot $ComposeEnvFile
if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
    throw "No se encontro el archivo de entorno de Compose: $envFilePath"
}

if ($Layer -eq "Presentation") {
    $masterService = "presentation-lb-master"
    $backupName = "presentation-lb-backup"
} else {
    $masterService = "application-lb-master"
    $backupName = "application-lb-backup"
}

$masterName = $masterService
$healthUri = "http://localhost/api/health"

function Invoke-HealthProbe {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $healthUri -TimeoutSec 4
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

function Wait-ForTrace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedBalancer,

        [Parameter(Mandatory = $true)]
        [datetime]$Deadline
    )

    do {
        $probe = Invoke-HealthProbe
        $timestamp = Get-Date -Format "HH:mm:ss.fff"

        if ($probe.Success -and $probe.Trace -like "*$ExpectedBalancer*") {
            "{0} HTTP {1} {2}" -f $timestamp, $probe.StatusCode, $probe.Trace
            return
        }

        if ($probe.Success) {
            "{0} HTTP {1} esperando {2}; {3}" -f $timestamp, $probe.StatusCode, $ExpectedBalancer, $probe.Trace
        } else {
            "{0} ERROR esperando {1}; {2}" -f $timestamp, $ExpectedBalancer, $probe.Error
        }

        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $Deadline)

    throw "No se observo HTTP 200 por $ExpectedBalancer antes del timeout."
}

$location = Get-Location
$masterPaused = $false

try {
    Set-Location $repositoryRoot

    $baseline = Invoke-HealthProbe
    if (-not $baseline.Success -or $baseline.Trace -notlike "*$masterName*") {
        throw "Precondicion fallida: API no respondio por $masterName. Trace: $($baseline.Trace); error: $($baseline.Error)"
    }
    "Estado inicial: HTTP $($baseline.StatusCode) $($baseline.Trace)"

    $action = "Pausar $masterService durante la PoC y comprobar failover/failback"
    if (-not $PSCmdlet.ShouldProcess($masterService, $action)) {
        return
    }

    & docker compose --env-file $ComposeEnvFile pause $masterService
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo pausar $masterService."
    }
    $masterPaused = $true
    $pauseStarted = Get-Date

    Wait-ForTrace -ExpectedBalancer $backupName -Deadline $pauseStarted.AddSeconds($TransitionTimeoutSeconds)

    $holdDeadline = $pauseStarted.AddSeconds($HoldSeconds)
    while ((Get-Date) -lt $holdDeadline) {
        $probe = Invoke-HealthProbe
        $timestamp = Get-Date -Format "HH:mm:ss.fff"

        if ($probe.Success) {
            "{0} HTTP {1} {2}" -f $timestamp, $probe.StatusCode, $probe.Trace
        } else {
            "{0} ERROR {1}" -f $timestamp, $probe.Error
        }

        Start-Sleep -Seconds 1
    }

    & docker compose --env-file $ComposeEnvFile unpause $masterService
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo reanudar $masterService; comprueba el estado del contenedor."
    }
    $masterPaused = $false

    Wait-ForTrace -ExpectedBalancer $masterName -Deadline (Get-Date).AddSeconds($TransitionTimeoutSeconds)
} finally {
    if ($masterPaused) {
        & docker compose --env-file $ComposeEnvFile unpause $masterService
        if ($LASTEXITCODE -ne 0) {
            Write-Error "No se pudo reanudar $masterService automaticamente. Restauralo manualmente antes de continuar."
        }
    }

    Set-Location $location
}
