[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostIPv4,

    [Parameter(Mandatory = $true)]
    [string]$ClientIPv4,

    [Parameter(Mandatory = $true)]
    [string]$InterfaceAlias
)

$ruleName = "Distributed Store HTTP test from $ClientIPv4"
$rules = @(Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)
if ($rules.Count -eq 0) {
    Write-Output "No existe la regla '$ruleName'; no hay cambios."
    return
}
if ($rules.Count -ne 1) {
    throw "Se esperaba una sola regla '$ruleName'; encontrados: $($rules.Count). No se elimino ninguna."
}

$rule = $rules[0]
$addressFilter = $rule | Get-NetFirewallAddressFilter
$portFilter = $rule | Get-NetFirewallPortFilter
$interfaceFilter = $rule | Get-NetFirewallInterfaceFilter

$localAddresses = @($addressFilter.LocalAddress)
$remoteAddresses = @($addressFilter.RemoteAddress)
$localPorts = @($portFilter.LocalPort)
$interfaces = @($interfaceFilter.InterfaceAlias)

if ($rule.Direction -ne "Inbound" -or
    $rule.Action -ne "Allow" -or
    $rule.EdgeTraversalPolicy -ne "Block" -or
    $portFilter.Protocol -ne "TCP" -or
    $localAddresses -notcontains $HostIPv4 -or
    $remoteAddresses -notcontains $ClientIPv4 -or
    $localPorts -notcontains "80" -or
    $interfaces -notcontains $InterfaceAlias) {
    throw "La regla '$ruleName' no coincide exactamente con las IP, interfaz y TCP/80 esperados; no se elimino."
}

$target = "regla '$ruleName' ($ClientIPv4 -> $HostIPv4 TCP/80, $InterfaceAlias)"
if ($PSCmdlet.ShouldProcess($target, "Eliminar regla de Windows Firewall")) {
    Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
    Write-Output "Regla eliminada: $ruleName"
}
