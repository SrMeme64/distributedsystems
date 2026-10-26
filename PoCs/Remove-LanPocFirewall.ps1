[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostIPv4,

    [Parameter(Mandatory = $true)]
    [string]$ClientIPv4,

    [Parameter(Mandatory = $true)]
    [string]$InterfaceAlias,

    [switch]$Force
)

# Removes the rule created by Enable-LanPocFirewall.ps1 and any rule left by
# older versions. By default it verifies the exact scope before deleting;
# use -Force if the host/client IP changed and you only want to clean up.

$ruleName = "Distributed Store LAN PoC (TCP 80)"
$legacyPrefix = "Distributed Store HTTP test from "

function ConvertTo-IPv4Address {
    param([string]$Address, [string]$ParameterName)

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$ParameterName debe ser una direccion IPv4 valida: $Address"
    }
    $parsed
}

$null = ConvertTo-IPv4Address -Address $HostIPv4 -ParameterName "HostIPv4"
$null = ConvertTo-IPv4Address -Address $ClientIPv4 -ParameterName "ClientIPv4"

$rules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq $ruleName -or $_.DisplayName -like "$legacyPrefix*" })

if ($rules.Count -eq 0) {
    Write-Output "No existe ninguna regla de la PoC LAN; no hay cambios."
    return
}

$removed = 0
foreach ($rule in $rules) {
    $addressFilter = $rule | Get-NetFirewallAddressFilter
    $portFilter = $rule | Get-NetFirewallPortFilter
    $interfaceFilter = $rule | Get-NetFirewallInterfaceFilter

    $matchesScope = (
        $rule.Direction -eq "Inbound" -and
        $rule.Action -eq "Allow" -and
        $rule.EdgeTraversalPolicy -eq "Block" -and
        $portFilter.Protocol -eq "TCP" -and
        @($portFilter.LocalPort) -contains "80" -and
        @($interfaceFilter.InterfaceAlias) -contains $InterfaceAlias -and
        @($addressFilter.LocalAddress) -contains $HostIPv4 -and
        @($addressFilter.RemoteAddress) -contains $ClientIPv4
    )

    if (-not $matchesScope -and -not $Force) {
        Write-Warning "La regla '$($rule.DisplayName)' no coincide con las IP, interfaz y TCP/80 esperados; no se elimino. Usa -Force para limpiarla."
        continue
    }

    $target = "regla '$($rule.DisplayName)' ($ClientIPv4 -> $HostIPv4 TCP/80, $InterfaceAlias)"
    if ($PSCmdlet.ShouldProcess($target, "Eliminar regla de Windows Firewall")) {
        Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
        Write-Output "Regla eliminada: $($rule.DisplayName)"
        $removed++
    }
}

if ($removed -eq 0) {
    Write-Output "No se elimino ninguna regla."
}
