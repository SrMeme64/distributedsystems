[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [string]$Path = "/api/products/cheapest",

    [ValidateRange(1, 100000)]
    [int]$Requests = 500,

    [ValidateRange(1, 200)]
    [int]$Concurrency = 20,

    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 10
)

if ($Concurrency -gt $Requests) {
    $Concurrency = $Requests
}

Add-Type -AssemblyName System.Net.Http

$base = $BaseUrl.TrimEnd('/')
if ($Path -notmatch '^/') {
    $Path = "/$Path"
}
$uri = "$base$Path"

$handler = New-Object System.Net.Http.HttpClientHandler
$handler.MaxConnectionsPerServer = $Concurrency
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

$latencies = New-Object 'System.Collections.Generic.List[double]'
$statusCounts = @{}
$failures = 0

try {
    $total = [System.Diagnostics.Stopwatch]::StartNew()

    for ($offset = 0; $offset -lt $Requests; $offset += $Concurrency) {
        $batchSize = [Math]::Min($Concurrency, $Requests - $offset)
        $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
        $timers = New-Object 'System.Collections.Generic.List[System.Diagnostics.Stopwatch]'

        for ($i = 0; $i -lt $batchSize; $i++) {
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            $timers.Add($timer)
            $tasks.Add($client.GetAsync($uri))
        }

        try {
            [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray())
        } catch {
            # Las tareas fallidas se contabilizan en el bucle siguiente.
        }

        for ($i = 0; $i -lt $batchSize; $i++) {
            $timers[$i].Stop()
            $latencies.Add($timers[$i].Elapsed.TotalMilliseconds)

            $task = $tasks[$i]
            if ($task.IsFaulted -or $task.IsCanceled) {
                $failures++
                continue
            }

            $response = $task.Result
            $code = [int]$response.StatusCode
            if ($statusCounts.ContainsKey($code)) {
                $statusCounts[$code]++
            } else {
                $statusCounts[$code] = 1
            }
            $response.Dispose()
        }
    }

    $total.Stop()
} finally {
    $client.Dispose()
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($Values.Count -eq 0) {
        return 0
    }

    $index = [Math]::Ceiling(($Percentile / 100.0) * $Values.Count) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $Values.Count) { $index = $Values.Count - 1 }
    $Values[$index]
}

$sorted = @($latencies | Sort-Object)
$average = if ($sorted.Count -gt 0) { ($sorted | Measure-Object -Average).Average } else { 0 }
$duration = $total.Elapsed.TotalSeconds
$throughput = if ($duration -gt 0) { $Requests / $duration } else { 0 }

"URL:                  $uri"
"Solicitudes:          $Requests"
"Concurrencia:         $Concurrency"
"Duracion total:       {0:N3} s" -f $duration
"Req/s:                {0:N2}" -f $throughput
"Latencia media:       {0:N3} ms" -f $average
"Latencia p50:         {0:N3} ms" -f (Get-Percentile -Values $sorted -Percentile 50)
"Latencia p95:         {0:N3} ms" -f (Get-Percentile -Values $sorted -Percentile 95)
"Latencia p99:         {0:N3} ms" -f (Get-Percentile -Values $sorted -Percentile 99)
"Latencia min:         {0:N3} ms" -f (Get-Percentile -Values $sorted -Percentile 0)
"Latencia max:         {0:N3} ms" -f (Get-Percentile -Values $sorted -Percentile 100)
"Errores:              $failures"
$codes = ($statusCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", "
"Codigos HTTP:         $codes"
