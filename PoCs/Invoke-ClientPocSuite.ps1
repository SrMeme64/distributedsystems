[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostIPv4,

    [ValidateRange(30, 900)]
    [int]$MonitorSeconds = 240,

    [ValidateRange(0, 120)]
    [int]$StartDelaySeconds = 10,

    [ValidateRange(1, 100000)]
    [int]$Requests = 500,

    [ValidateRange(1, 200)]
    [int]$Concurrency = 20,

    [ValidateRange(100, 60000)]
    [int]$IntervalMilliseconds = 500,

    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 4,

    [ValidateRange(50, 100)]
    [double]$MinimumAvailability = 95,

    [string]$EvidenceDirectory = "",

    [switch]$SkipLoad,

    [switch]$SkipMonitor
)

# Client-side PoC suite. Run it from the second laptop, not from the host.
#
#   1. Preflight: TCP/80, /api/health, /api/products/cheapest.
#   2. PoC 1: cache clear + cold/warm load test (Invoke-LoadTest.ps1).
#   3. Monitor: polls /api/health for MonitorSeconds and records every trace.
#      While it runs, execute Invoke-HostPocSuite.ps1 on the host. The monitor
#      detects the presentation/application failovers and the API node chaos.
#
# Evidence: CSV with every sample and a TXT summary in PoCs/evidencias.

$parsedAddress = $null
if (-not [System.Net.IPAddress]::TryParse($HostIPv4, [ref]$parsedAddress) -or
    $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "HostIPv4 debe ser una direccion IPv4 valida: $HostIPv4"
}

$baseUrl = "http://$HostIPv4"
$healthUri = "$baseUrl/api/health"
$catalogUri = "$baseUrl/api/products/cheapest"
$cacheClearUri = "$baseUrl/api/cache/clear"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$loadScript = Join-Path $PSScriptRoot "Invoke-LoadTest.ps1"
if (-not (Test-Path -LiteralPath $loadScript -PathType Leaf)) {
    throw "No se encontro $loadScript"
}

if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $repositoryRoot "PoCs\evidencias"
}
if (-not (Test-Path -LiteralPath $EvidenceDirectory)) {
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $EvidenceDirectory "client-poc-suite-$stamp.txt"
$csvPath = Join-Path $EvidenceDirectory "client-monitor-$stamp.csv"

function Write-Log {
    param([string]$Message)

    Write-Host $Message
    Add-Content -LiteralPath $logPath -Value $Message -Encoding UTF8
}

function Test-TcpPort {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMilliseconds = 3000
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

function Get-ClientLanIPv4 {
    $address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notlike "127.*" -and
            $_.IPAddress -notlike "169.254.*" -and
            $_.IPAddress -notlike "192.168.56.*"
        } |
        Select-Object -First 1
    if ($address) { return $address.IPAddress }
    return "<IP_CLIENTE>"
}

function Get-LoadMetric {
    param(
        [string]$Text,
        [string]$Name
    )

    $match = [regex]::Match($Text, "(?m)^" + [regex]::Escape($Name) + ":\s*([0-9.,]+)")
    if (-not $match.Success) {
        return $null
    }
    return [double]($match.Groups[1].Value -replace ",", ".")
}

function Invoke-LoadTest {
    param(
        [int]$RequestCount,
        [int]$ConcurrencyLevel,
        [string]$Label
    )

    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $loadScript,
        "-BaseUrl", $baseUrl,
        "-Requests", "$RequestCount",
        "-Concurrency", "$ConcurrencyLevel"
    )
    $output = & powershell @arguments 2>&1
    $exitCode = $LASTEXITCODE

    Write-Log "--- Carga $Label (${RequestCount} solicitudes, concurrencia $ConcurrencyLevel) ---"
    foreach ($line in @($output)) {
        Write-Log ([string]$line)
    }

    $text = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
    [pscustomobject]@{
        ExitCode = $exitCode
        Throughput = Get-LoadMetric -Text $text -Name "Req/s"
        AverageMs = Get-LoadMetric -Text $text -Name "Latencia media"
        Errors = Get-LoadMetric -Text $text -Name "Errores"
    }
}

function Invoke-HealthSample {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $healthUri -TimeoutSec $TimeoutSeconds
        $timer.Stop()
        [pscustomobject]@{
            Success = ([int]$response.StatusCode -eq 200)
            Status = [int]$response.StatusCode
            Trace = [string]$response.Headers["X-Request-Trace"]
            LatencyMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 1)
            Error = ""
        }
    } catch {
        $timer.Stop()
        [pscustomobject]@{
            Success = $false
            Status = $null
            Trace = ""
            LatencyMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 1)
            Error = $_.Exception.Message
        }
    }
}

function Get-LayerTransition {
    param(
        [object[]]$Samples,
        [string]$Layer
    )

    $backupToken = "$Layer-backup"
    $masterToken = "$Layer-master"

    $firstBackup = $Samples | Where-Object { $_.Trace -like "*$backupToken*" } | Select-Object -First 1
    if (-not $firstBackup) {
        return $null
    }

    $lastMasterBefore = $Samples |
        Where-Object { $_.ElapsedSeconds -le $firstBackup.ElapsedSeconds -and $_.Trace -like "*$masterToken*" } |
        Select-Object -Last 1
    $firstMasterAfter = $Samples |
        Where-Object { $_.ElapsedSeconds -gt $firstBackup.ElapsedSeconds -and $_.Trace -like "*$masterToken*" } |
        Select-Object -First 1

    $failoverSeconds = $null
    if ($lastMasterBefore) {
        $failoverSeconds = [Math]::Round($firstBackup.ElapsedSeconds - $lastMasterBefore.ElapsedSeconds, 2)
    }
    $failbackSeconds = $null
    if ($firstMasterAfter) {
        $failbackSeconds = [Math]::Round($firstMasterAfter.ElapsedSeconds - $firstBackup.ElapsedSeconds, 2)
    }

    [pscustomobject]@{
        Layer = $Layer
        BackupAt = $firstBackup.ElapsedSeconds
        FailoverSeconds = $failoverSeconds
        FailbackSeconds = $failbackSeconds
    }
}

Write-Log "=== Suite de PoC en el cliente ==="
Write-Log "Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Host: $baseUrl"
Write-Log "Evidencia: $logPath"
Write-Log ""

Write-Log "--- Preflight: conectividad cliente -> host ---"
if (-not (Test-TcpPort -TargetHost $HostIPv4 -Port 80)) {
    Write-Log "ERROR: TCP/80 no responde en $HostIPv4."
    Write-Log "En el HOST, con PowerShell como administrador:"
    Write-Log "  .\PoCs\Enable-LanPocFirewall.ps1 -HostIPv4 `"$HostIPv4`" -ClientIPv4 `"$(Get-ClientLanIPv4)`" -InterfaceAlias `"Wi-Fi`" -AllowPublicProfile"
    Write-Log "Comprueba tambien que el stack este arriba y que la IP del host sea correcta."
    exit 1
}
Write-Log "TCP/80: OK"

try {
    $health = Invoke-HealthSample
    if (-not $health.Success) {
        throw "GET /api/health devolvio $($health.Status) $($health.Error)"
    }
    Write-Log "GET /api/health: HTTP 200 $($health.Trace)"
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}

try {
    $catalog = Invoke-WebRequest -UseBasicParsing -Uri $catalogUri -TimeoutSec $TimeoutSeconds
    Write-Log "GET /api/products/cheapest: HTTP $([int]$catalog.StatusCode), $($catalog.Content.Length) bytes"
} catch {
    Write-Log "ERROR: GET /api/products/cheapest fallo: $($_.Exception.Message)"
    exit 1
}

Write-Log ""

if (-not $SkipLoad) {
    Write-Log "--- PoC 1: cache fria vs caliente ---"
    try {
        $clear = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $cacheClearUri -TimeoutSec 10
        Write-Log "POST /api/cache/clear: HTTP $([int]$clear.StatusCode)"
    } catch {
        Write-Log "AVISO: no se pudo vaciar la cache: $($_.Exception.Message)"
    }

    $cold = Invoke-LoadTest -RequestCount 1 -ConcurrencyLevel 1 -Label "fria"
    $warm = Invoke-LoadTest -RequestCount $Requests -ConcurrencyLevel $Concurrency -Label "caliente"

    Write-Log ""
    Write-Log "Comparacion de carga:"
    Write-Log ("  Fria    : {0} req/s, {1} ms de media" -f $cold.Throughput, $cold.AverageMs)
    Write-Log ("  Caliente: {0} req/s, {1} ms de media" -f $warm.Throughput, $warm.AverageMs)
    if ($null -ne $cold.AverageMs -and $null -ne $warm.AverageMs -and $warm.AverageMs -lt $cold.AverageMs) {
        Write-Log "  La cache caliente responde mas rapido que la fria (comportamiento esperado)."
    } else {
        Write-Log "  AVISO: la cache caliente no fue mas rapida; revisa Redis o el estado del stack."
    }
    if ($warm.Errors -and $warm.Errors -gt 0) {
        Write-Log "  AVISO: la prueba de carga caliente registro $($warm.Errors) errores."
    }
    Write-Log ""
}

if ($SkipMonitor) {
    Write-Log "Monitor omitido (-SkipMonitor)."
    Write-Log "Resultado: PASS (solo preflight/carga)."
    exit 0
}

$samples = New-Object 'System.Collections.Generic.List[object]'
$clientIp = Get-ClientLanIPv4

Write-Log "--- PoC 2-5: monitor continuo ---"
Write-Log "Ventana: $MonitorSeconds s, una muestra cada $IntervalMilliseconds ms."
Write-Log "En el HOST, ejecuta ahora:"
Write-Log "  powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Invoke-HostPocSuite.ps1 -HoldSeconds 15"
Write-Log ""

if ($StartDelaySeconds -gt 0) {
    Write-Log "El monitor empieza en $StartDelaySeconds s..."
    Start-Sleep -Seconds $StartDelaySeconds
}

$monitorStarted = Get-Date
$nextSampleAt = 0.0
while ($true) {
    $elapsed = ((Get-Date) - $monitorStarted).TotalSeconds
    if ($elapsed -ge $MonitorSeconds) {
        break
    }

    if ($elapsed -lt $nextSampleAt) {
        Start-Sleep -Milliseconds ([Math]::Max(1, [int](($nextSampleAt - $elapsed) * 1000)))
        continue
    }

    $sample = Invoke-HealthSample
    $elapsed = ((Get-Date) - $monitorStarted).TotalSeconds
    $record = [pscustomobject]@{
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        ElapsedSeconds = [Math]::Round($elapsed, 2)
        Status = $sample.Status
        Trace = $sample.Trace
        LatencyMs = $sample.LatencyMs
        Error = $sample.Error
    }
    $samples.Add($record)

    if ($sample.Success) {
        Write-Host ("{0} HTTP {1} {2}" -f (Get-Date).ToString("HH:mm:ss.fff"), $sample.Status, $sample.Trace)
    } else {
        Write-Host ("{0} ERROR {1}" -f (Get-Date).ToString("HH:mm:ss.fff"), $sample.Error)
    }

    $nextSampleAt = $elapsed + ($IntervalMilliseconds / 1000.0)
}

$monitorEnded = Get-Date
$samples | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$total = $samples.Count
$ok = @($samples | Where-Object { $_.Status -eq 200 }).Count
$errors = $total - $ok
$availability = if ($total -gt 0) { [Math]::Round(($ok / $total) * 100, 1) } else { 0 }

$presentation = Get-LayerTransition -Samples $samples -Layer "presentation-lb"
$application = Get-LayerTransition -Samples $samples -Layer "application-lb"
$appNodes = @($samples | ForEach-Object {
    if ($_.Trace -match "\b(app[123])\b") { $matches[1] }
} | Sort-Object -Unique)

$errorMessages = @($samples | Where-Object { $_.Error } | Group-Object Error | Sort-Object Count -Descending)

Write-Log ""
Write-Log "================================================================"
Write-Log "Resumen del monitor"
Write-Log ("  Ventana: {0:N1} s, {1} muestras" -f ($monitorEnded - $monitorStarted).TotalSeconds, $total)
Write-Log ("  HTTP 200: {0}, errores: {1}, disponibilidad: {2:N1} %" -f $ok, $errors, $availability)
Write-Log ("  Nodos API observados: {0}" -f ($(if ($appNodes.Count -gt 0) { $appNodes -join ", " } else { "ninguno" })))

foreach ($item in @(
    @{ Layer = "presentation-lb"; Value = $presentation },
    @{ Layer = "application-lb"; Value = $application }
)) {
    if ($null -eq $item.Value) {
        Write-Log ("  Failover {0}: NO OBSERVADO (ejecuta la suite del host durante la ventana)" -f $item.Layer)
        continue
    }
    $failoverText = if ($null -ne $item.Value.FailoverSeconds) { "{0:N2} s" -f $item.Value.FailoverSeconds } else { "n/d" }
    $failbackText = if ($null -ne $item.Value.FailbackSeconds) { "{0:N2} s" -f $item.Value.FailbackSeconds } else { "NO OBSERVADO" }
    Write-Log ("  Failover {0}: SI (deteccion {1}), failback {2}" -f $item.Layer, $failoverText, $failbackText)
}

if ($errorMessages.Count -gt 0) {
    Write-Log "  Errores mas frecuentes:"
    foreach ($group in $errorMessages) {
        Write-Log ("    {0} x {1}" -f $group.Count, $group.Name)
    }
}

Write-Log "  CSV: $csvPath"

$passed = ($availability -ge $MinimumAvailability)
Write-Log ""
if ($passed) {
    Write-Log ("Resultado: PASS (disponibilidad {0:N1} % >= {1:N1} %)" -f $availability, $MinimumAvailability)
    exit 0
}

Write-Log ("Resultado: FAIL (disponibilidad {0:N1} % < {1:N1} %)" -f $availability, $MinimumAvailability)
exit 1
