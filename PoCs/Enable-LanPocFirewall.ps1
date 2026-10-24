[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostIPv4,

    [Parameter(Mandatory = $true)]
    [string]$ClientIPv4,

    [Parameter(Mandatory = $true)]
    [string]$InterfaceAlias,

    [switch]$AllowPublicProfile
)

function ConvertTo-IPv4Address {
    param([string]$Address, [string]$ParameterName)

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$ParameterName debe ser una direccion IPv4 valida: $Address"
    }
    $parsed
}

$hostAddress = ConvertTo-IPv4Address -Address $HostIPv4 -ParameterName "HostIPv4"
$clientAddress = ConvertTo-IPv4Address -Address $ClientIPv4 -ParameterName "ClientIPv4"
if ($hostAddress.Equals($clientAddress)) {
    throw "HostIPv4 y ClientIPv4 deben ser direcciones distintas."
}

$interfaceAddress = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $InterfaceAlias -ErrorAction Stop |
    Where-Object { $_.IPAddress -eq $hostAddress.IPAddressToString }
if (-not $interfaceAddress) {
    throw "$HostIPv4 no esta asignada a la interfaz '$InterfaceAlias' de este host."
}

$profiles = @(Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias -ErrorAction Stop)
if ($profiles.Count -ne 1) {
    throw "Se esperaba exactamente un perfil de red para '$InterfaceAlias'; encontrados: $($profiles.Count)."
}
$networkCategory = $profiles[0].NetworkCategory
if ($networkCategory -eq "Public" -and -not $AllowPublicProfile) {
    throw "La interfaz usa perfil Public. Solo en una LAN privada y confiable, vuelve a ejecutar con -AllowPublicProfile."
}
if ($networkCategory -notin @("Public", "Private", "DomainAuthenticated")) {
    throw "Perfil de red no reconocido para '$InterfaceAlias': $networkCategory"
}

$ruleName = "Distributed Store HTTP test from $ClientIPv4"
$existingRules = @(Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)
if ($existingRules.Count -gt 1) {
    throw "Se esperaba como máximo una regla '$ruleName'; encontradas: $($existingRules.Count)."
}
if ($existingRules.Count -eq 1) {
    $existing = $existingRules[0]
    $addressFilter = $existing | Get-NetFirewallAddressFilter
    $portFilter = $existing | Get-NetFirewallPortFilter
    $interfaceFilter = $existing | Get-NetFirewallInterfaceFilter
    $matchesScope = (
        $existing.Enabled -eq "True" -and
        $existing.Direction -eq "Inbound" -and
        $existing.Action -eq "Allow" -and
        $existing.EdgeTraversalPolicy -eq "Block" -and
        [string]$existing.Profile -eq [string]$networkCategory -and
        $addressFilter.LocalAddress -contains $HostIPv4 -and
        $addressFilter.RemoteAddress -contains $ClientIPv4 -and
        $portFilter.Protocol -eq "TCP" -and
        $portFilter.LocalPort -contains "80" -and
        $interfaceFilter.InterfaceAlias -contains $InterfaceAlias
    )
    if (-not $matchesScope) {
        throw "Ya existe '$ruleName', pero su alcance no coincide con las IP, interfaz, perfil y puerto esperados. No se modifico."
    }

    Write-Output "La regla '$ruleName' ya existe y coincide con el alcance esperado; no se hicieron cambios."
    $existing | Format-List DisplayName, Enabled, Profile, Direction, Action
    $addressFilter | Format-List LocalAddress, RemoteAddress
    $portFilter | Format-List Protocol, LocalPort
    return
}

$description = "PoC LAN temporal: solo TCP/80 desde $ClientIPv4 hacia $HostIPv4 por $InterfaceAlias."
$target = "TCP/80 en $HostIPv4 desde $ClientIPv4 por $InterfaceAlias (perfil $networkCategory)"
if ($PSCmdlet.ShouldProcess($target, "Crear excepcion entrante de Windows Firewall")) {
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Description $description `
        -Group "Distributed Store LAN PoC" `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Protocol TCP `
        -LocalPort 80 `
        -LocalAddress $HostIPv4 `
        -RemoteAddress $ClientIPv4 `
        -InterfaceAlias $InterfaceAlias `
        -Profile ([string]$networkCategory) `
        -EdgeTraversalPolicy Block `
        -ErrorAction Stop | Out-Null

    Get-NetFirewallRule -DisplayName $ruleName |
        Format-List DisplayName, Enabled, Profile, Direction, Action
    Get-NetFirewallRule -DisplayName $ruleName |
        Get-NetFirewallAddressFilter |
        Format-List LocalAddress, RemoteAddress
    Get-NetFirewallRule -DisplayName $ruleName |
        Get-NetFirewallPortFilter |
        Format-List Protocol, LocalPort
}
