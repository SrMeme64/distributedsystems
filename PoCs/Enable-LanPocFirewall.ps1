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

# Creates or updates a single, narrowly scoped inbound rule for TCP/80.
# Idempotent: re-running with a new host or client IP updates the existing rule
# instead of failing or leaving a stale duplicate behind.

$ruleName = "Distributed Store LAN PoC (TCP 80)"
$ruleGroup = "Distributed Store LAN PoC"
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

function Get-RuleScope {
    param([Parameter(Mandatory = $true)]$Rule)

    $addressFilter = $Rule | Get-NetFirewallAddressFilter
    $portFilter = $Rule | Get-NetFirewallPortFilter
    $interfaceFilter = $Rule | Get-NetFirewallInterfaceFilter

    [pscustomobject]@{
        Enabled        = [string]$Rule.Enabled
        Direction      = [string]$Rule.Direction
        Action         = [string]$Rule.Action
        Profile        = [string]$Rule.Profile
        EdgeTraversal  = [string]$Rule.EdgeTraversalPolicy
        LocalAddress   = @($addressFilter.LocalAddress)
        RemoteAddress  = @($addressFilter.RemoteAddress)
        Protocol       = [string]$portFilter.Protocol
        LocalPort      = @($portFilter.LocalPort)
        InterfaceAlias = @($interfaceFilter.InterfaceAlias)
    }
}

function Test-RuleScope {
    param(
        [Parameter(Mandatory = $true)]$Scope,
        [string]$ExpectedHost,
        [string]$ExpectedClient,
        [string]$ExpectedInterface,
        [string]$ExpectedProfile
    )

    return (
        $Scope.Enabled -eq "True" -and
        $Scope.Direction -eq "Inbound" -and
        $Scope.Action -eq "Allow" -and
        $Scope.EdgeTraversal -eq "Block" -and
        $Scope.Profile -eq $ExpectedProfile -and
        $Scope.LocalAddress -contains $ExpectedHost -and
        $Scope.RemoteAddress -contains $ExpectedClient -and
        $Scope.Protocol -eq "TCP" -and
        $Scope.LocalPort -contains "80" -and
        $Scope.InterfaceAlias -contains $ExpectedInterface
    )
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
$networkCategory = [string]$profiles[0].NetworkCategory
if ($networkCategory -eq "Public" -and -not $AllowPublicProfile) {
    throw "La interfaz usa perfil Public. Solo en una LAN privada y confiable, vuelve a ejecutar con -AllowPublicProfile."
}
if ($networkCategory -notin @("Public", "Private", "DomainAuthenticated")) {
    throw "Perfil de red no reconocido para '$InterfaceAlias': $networkCategory"
}

$stableRules = @(Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)
if ($stableRules.Count -gt 1) {
    throw "Se esperaba como maximo una regla '$ruleName'; encontradas: $($stableRules.Count). Elimina los duplicados manualmente."
}

$target = "TCP/80 en $HostIPv4 desde $ClientIPv4 por $InterfaceAlias (perfil $networkCategory)"

if ($stableRules.Count -eq 1) {
    $rule = $stableRules[0]
    $scope = Get-RuleScope -Rule $rule
    $matches = Test-RuleScope -Scope $scope -ExpectedHost $HostIPv4 -ExpectedClient $ClientIPv4 -ExpectedInterface $InterfaceAlias -ExpectedProfile $networkCategory

    if ($matches) {
        Write-Output "La regla '$ruleName' ya existe y coincide con el alcance esperado; no se hicieron cambios."
    } elseif ($PSCmdlet.ShouldProcess($target, "Actualizar el alcance de la regla existente")) {
        $rule | Set-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -Profile $networkCategory -EdgeTraversalPolicy Block -ErrorAction Stop
        $rule | Set-NetFirewallAddressFilter -LocalAddress $HostIPv4 -RemoteAddress $ClientIPv4 -ErrorAction Stop
        $rule | Set-NetFirewallInterfaceFilter -InterfaceAlias $InterfaceAlias -ErrorAction Stop
        $rule | Set-NetFirewallPortFilter -Protocol TCP -LocalPort 80 -ErrorAction Stop
        Write-Output "Regla actualizada: $ruleName -> $target"
    }
} elseif ($PSCmdlet.ShouldProcess($target, "Crear excepcion entrante de Windows Firewall")) {
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Description "PoC LAN temporal: solo TCP/80 desde $ClientIPv4 hacia $HostIPv4 por $InterfaceAlias." `
        -Group $ruleGroup `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Protocol TCP `
        -LocalPort 80 `
        -LocalAddress $HostIPv4 `
        -RemoteAddress $ClientIPv4 `
        -InterfaceAlias $InterfaceAlias `
        -Profile $networkCategory `
        -EdgeTraversalPolicy Block `
        -ErrorAction Stop | Out-Null
    Write-Output "Regla creada: $ruleName -> $target"
}

# Remove rules left by older versions of this script (display name included
# the client IP, so a client IP change used to leave a stale rule behind).
$legacyRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "$legacyPrefix*" })
foreach ($legacy in $legacyRules) {
    if ($PSCmdlet.ShouldProcess($legacy.DisplayName, "Eliminar regla obsoleta de la PoC")) {
        Remove-NetFirewallRule -Name $legacy.Name -ErrorAction Stop
        Write-Output "Regla obsoleta eliminada: $($legacy.DisplayName)"
    }
}

Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
    Format-List DisplayName, Enabled, Profile, Direction, Action
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
    Get-NetFirewallAddressFilter |
    Format-List LocalAddress, RemoteAddress
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
    Get-NetFirewallPortFilter |
    Format-List Protocol, LocalPort
