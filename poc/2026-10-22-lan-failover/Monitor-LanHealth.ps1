[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostIPv4,

    [ValidateRange(1, 10000)]
    [int]$RequestCount = 60,

    [ValidateRange(0, 60000)]
    [int]$IntervalMilliseconds = 500,

    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 4
)

$parsedAddress = $null
if (-not [System.Net.IPAddress]::TryParse($HostIPv4, [ref]$parsedAddress) -or
    $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "HostIPv4 debe ser una direccion IPv4 valida: $HostIPv4"
}

$uri = "http://$HostIPv4/api/health"

for ($request = 1; $request -le $RequestCount; $request++) {
    $timestamp = Get-Date -Format "HH:mm:ss.fff"

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec $TimeoutSeconds
        $trace = $response.Headers["X-Request-Trace"]
        "{0} HTTP {1} {2}" -f $timestamp, [int]$response.StatusCode, $trace
    } catch {
        "{0} ERROR {1}" -f $timestamp, $_.Exception.Message
    }

    if ($request -lt $RequestCount -and $IntervalMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
}
