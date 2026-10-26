[CmdletBinding()]
param(
    [ValidateSet("all", "poc2", "poc3", "poc4", "poc5")]
    [string[]]$Scenarios = @("all"),

    [ValidateRange(5, 300)]
    [int]$HoldSeconds = 15,

    [ValidateRange(0, 120)]
    [int]$StartDelaySeconds = 5,

    [string]$ComposeEnvFile = ".env.exam",

    [string]$EvidenceDirectory = "",

    [switch]$SkipHealthCheck,

    [switch]$NoRepair
)

# Host-side PoC suite. Runs, in order:
#   PoC 2 - one API node (app1) stops and HAProxy removes it from rotation
#   PoC 3 - a random API node stops (Chaos Engineering)
#   PoC 4 - presentation-lb-master failover to presentation-lb-backup
#   PoC 5 - application-lb-master failover to application-lb-backup
#
# Start the client monitor first:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Invoke-ClientPocSuite.ps1 `
#     -HostIPv4 "<IP_DEL_HOST>" -MonitorSeconds 240
# Then run this suite on the host. Every scenario restores what it changed.

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envFilePath = Join-Path $repositoryRoot $ComposeEnvFile
if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
    throw "No se encontro el archivo de entorno de Compose: $envFilePath"
}

if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $repositoryRoot "PoCs\evidencias"
}
if (-not (Test-Path -LiteralPath $EvidenceDirectory)) {
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
}
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $EvidenceDirectory "host-poc-suite-$stamp.txt"

$healthScript = Join-Path $PSScriptRoot "Test-StackHealth.ps1"
$chaosScript = Join-Path $PSScriptRoot "Invoke-ChaosTest.ps1"
$failoverScript = Join-Path $PSScriptRoot "Test-LanFailover.ps1"

function Write-Log {
    param([string]$Message)

    Write-Host $Message
    Add-Content -LiteralPath $logPath -Value $Message -Encoding UTF8
}

function Invoke-ChildPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ScriptArguments = @()
    )

    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $ScriptArguments
    $output = & powershell @arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in @($output)) {
        Write-Log ([string]$line)
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
    }
}

function Invoke-HealthCheck {
    param([int]$TimeoutSeconds = 60)

    $result = Invoke-ChildPowerShell -ScriptPath $healthScript -ScriptArguments @(
        "-ComposeEnvFile", $ComposeEnvFile, "-TimeoutSeconds", "$TimeoutSeconds"
    )
    return $result
}

function Repair-Stack {
    Write-Log "Intentando reparar el stack con docker compose up -d ..."
    Push-Location $repositoryRoot
    try {
        & docker compose --env-file $ComposeEnvFile up -d 2>&1 | ForEach-Object { Write-Log ([string]$_) }
    } finally {
        Pop-Location
    }
}

function Get-HostLanIPv4 {
    $address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notlike "127.*" -and
            $_.IPAddress -notlike "169.254.*" -and
            $_.IPAddress -notlike "172.*" -and
            $_.IPAddress -notlike "192.168.56.*"
        } |
        Select-Object -First 1
    if ($address) { return $address.IPAddress }
    return "<IP_DEL_HOST>"
}

function Get-ScenarioList {
    if ($Scenarios -contains "all") {
        return @("poc2", "poc3", "poc4", "poc5")
    }
    return @("poc2", "poc3", "poc4", "poc5") | Where-Object { $Scenarios -contains $_ }
}

Write-Log "=== Suite de PoC en el host ==="
Write-Log "Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Evidencia: $logPath"
Write-Log ""

if ($StartDelaySeconds -gt 0) {
    $clientIp = Get-HostLanIPv4
    Write-Log "En el CLIENTE, ejecuta ahora (o deja el monitor ya activo):"
    Write-Log "  powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Invoke-ClientPocSuite.ps1 -HostIPv4 `"$clientIp`" -MonitorSeconds 240"
    Write-Log ""
    Write-Log "La suite del host empieza en $StartDelaySeconds s..."
    Start-Sleep -Seconds $StartDelaySeconds
}

if (-not $SkipHealthCheck) {
    Write-Log "--- Preflight: readiness del stack ---"
    $health = Invoke-HealthCheck -TimeoutSeconds 90
    if ($health.ExitCode -ne 0) {
        if ($NoRepair) {
            Write-Log "Preflight fallo y -NoRepair esta activo. Se aborta."
            exit 1
        }
        Repair-Stack
        $health = Invoke-HealthCheck -TimeoutSeconds 120
        if ($health.ExitCode -ne 0) {
            Write-Log "El stack sigue sin estar listo. Se aborta."
            exit 1
        }
    }
    Write-Log "Preflight OK."
    Write-Log ""
}

$results = New-Object 'System.Collections.Generic.List[object]'
$scenarioList = Get-ScenarioList

foreach ($scenario in $scenarioList) {
    $name = ""
    $scriptPath = $null
    $scriptArguments = @()

    switch ($scenario) {
        "poc2" {
            $name = "PoC 2 - failover de app1"
            $scriptPath = $chaosScript
            $scriptArguments = @("-Target", "app1", "-HoldSeconds", "$HoldSeconds", "-ComposeEnvFile", $ComposeEnvFile)
        }
        "poc3" {
            $name = "PoC 3 - Chaos Engineering (nodo aleatorio)"
            $scriptPath = $chaosScript
            $scriptArguments = @("-HoldSeconds", "$HoldSeconds", "-ComposeEnvFile", $ComposeEnvFile)
        }
        "poc4" {
            $name = "PoC 4 - failover presentation-lb-master"
            $scriptPath = $failoverScript
            $scriptArguments = @("-Layer", "Presentation", "-HoldSeconds", "$HoldSeconds", "-ComposeEnvFile", $ComposeEnvFile)
        }
        "poc5" {
            $name = "PoC 5 - failover application-lb-master"
            $scriptPath = $failoverScript
            $scriptArguments = @("-Layer", "Application", "-HoldSeconds", "$HoldSeconds", "-ComposeEnvFile", $ComposeEnvFile)
        }
    }

    Write-Log "================================================================"
    Write-Log "--- $name ---"
    $startedAt = Get-Date
    $run = Invoke-ChildPowerShell -ScriptPath $scriptPath -ScriptArguments $scriptArguments
    $duration = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)

    $detail = ""
    if ($run.Output -match "Nodo seleccionado:\s*(app[123])") {
        $detail = "nodo=$($matches[1])"
    }
    if ($run.Output -match "Failover observado en ([0-9.,]+) s") {
        $detail = ("failover={0}s" -f $matches[1])
    }
    if ($run.Output -match "Resultado:\s*(PASS|FAIL|WARN|SIN CAMBIOS)") {
        $detail = ($detail + " " + $matches[1]).Trim()
    }

    $status = if ($run.ExitCode -eq 0) { "PASS" } else { "FAIL" }
    $results.Add([pscustomobject]@{
        Scenario = $name
        Status   = $status
        Seconds  = $duration
        Detail   = $detail
    })

    Write-Log "Resultado $name : $status ($duration s) $detail"
    Write-Log ""

    if (-not $SkipHealthCheck) {
        $post = Invoke-HealthCheck -TimeoutSeconds 45
        if ($post.ExitCode -ne 0) {
            if (-not $NoRepair) {
                Repair-Stack
                $post = Invoke-HealthCheck -TimeoutSeconds 90
            }
            if ($post.ExitCode -ne 0) {
                Write-Log "El stack no quedo sano tras $name. Se detiene la suite."
                $results.Add([pscustomobject]@{
                    Scenario = "Verificacion posterior a $name"
                    Status   = "FAIL"
                    Seconds  = 0
                    Detail   = "stack no listo"
                })
                break
            }
        }
        Write-Log "Verificacion posterior: OK."
        Write-Log ""
    }
}

Write-Log "================================================================"
Write-Log "Resumen de la suite"
foreach ($result in $results) {
    Write-Log ("  [{0}] {1,-48} {2,6} s  {3}" -f $result.Status, $result.Scenario, $result.Seconds, $result.Detail)
}

$failed = @($results | Where-Object { $_.Status -ne "PASS" })
Write-Log ""
if ($failed.Count -eq 0) {
    Write-Log "Resultado global: PASS"
    exit 0
}

Write-Log "Resultado global: FAIL ($($failed.Count) escenario(s))"
exit 1
