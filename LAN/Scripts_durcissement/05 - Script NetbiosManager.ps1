<#
.SYNOPSIS
    Gestion complète de NetBIOS over TCP/IP (menu interactif) avec fallback registre et option reboot.

.DESCRIPTION
    - Affiche l'état NetBIOS pour les interfaces IP actives
    - Désactive NetBIOS (interface choisie ou toutes)
    - Restaure l'état par défaut (DHCP) (interface choisie ou toutes)
    - En cas d'échec WMI (SetTcpipNetbios), bascule sur écriture registre + redémarrage d'interface
    - Vérifie/active le binding ms_netbt avant modification
    - Propose un redémarrage de la machine

.NOTES
    - À exécuter en tant qu'Administrateur.
    - Valeurs NetBIOS: 0 = Par défaut (DHCP), 1 = Activé, 2 = Désactivé.
#>

#region Helpers
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NetbiosStateText {
    param([int]$Option)
    switch ($Option) {
        0 { "Par défaut (DHCP)" }
        1 { "Activé" }
        2 { "Désactivé" }
        default { "Inconnu ($Option)" }
    }
}

function Get-IpEnabledConfigs {
    $args = @{ ClassName = 'Win32_NetworkAdapterConfiguration'; Filter = "IPEnabled=TRUE" }
    Get-CimInstance @args | Sort-Object InterfaceIndex
}

function Ensure-NetbtBinding {
    param([int]$InterfaceIndex)
    try {
        $b = Get-NetAdapterBinding -InterfaceIndex $InterfaceIndex -ComponentID ms_netbt -ErrorAction Stop
        if (-not $b.Enabled) {
            Write-Host ("   • Binding ms_netbt désactivé sur IfIndex {0} → activation..." -f $InterfaceIndex) -ForegroundColor Cyan
            Enable-NetAdapterBinding -InterfaceIndex $InterfaceIndex -ComponentID ms_netbt -ErrorAction Stop
        }
        return $true
    } catch {
        Write-Host ("   • Impossible de lire/activer ms_netbt sur IfIndex {0} : {1}" -f $InterfaceIndex, $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}

function Invoke-NetbiosWmi {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][int]$TcpipNetbiosOptions
    )
    try {
        return Invoke-CimMethod -InputObject $Config -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = $TcpipNetbiosOptions }
    } catch {
        return [pscustomobject]@{ ReturnValue = 1000; Error = $_.Exception.Message }
    }
}

function Set-NetbiosRegistry {
    param(
        [Parameter(Mandatory)][string]$SettingID,
        [Parameter(Mandatory)][int]$TcpipNetbiosOptions
    )
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_$SettingID"
    if (-not (Test-Path $regPath)) {
        throw "Clé registre introuvable: $regPath"
    }
    Set-ItemProperty -Path $regPath -Name NetbiosOptions -Type DWord -Value $TcpipNetbiosOptions -ErrorAction Stop
    return $regPath
}

function Restart-Adapter {
    param([int]$InterfaceIndex)
    try {
        Disable-NetAdapter -InterfaceIndex $InterfaceIndex -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 2
        Enable-NetAdapter  -InterfaceIndex $InterfaceIndex -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        Write-Host ("   • Impossible de redémarrer l’interface IfIndex {0} : {1}" -f $InterfaceIndex, $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}

function Apply-NetbiosToConfig {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][int]$Option
    )

    $ifx  = $Config.InterfaceIndex
    $desc = $Config.Description
    $stateTxt = Get-NetbiosStateText -Option $Option

    Write-Host (" - {0} (Idx {1})" -f $desc, $ifx) -ForegroundColor White

    [void](Ensure-NetbtBinding -InterfaceIndex $ifx)

    $res = Invoke-NetbiosWmi -Config $Config -TcpipNetbiosOptions $Option
    if ($res.ReturnValue -eq 0) {
        Write-Host ("   → OK via WMI → {0}" -f $stateTxt) -ForegroundColor Green
        return
    }
    if ($res.ReturnValue -eq 1) {
        Write-Host ("   → OK via WMI → {0} (redémarrage requis)" -f $stateTxt) -ForegroundColor Yellow
        return
    }

    Write-Host ("   → WMI échec (code {0}) → bascule registre..." -f $res.ReturnValue) -ForegroundColor Yellow

    try {
        $reg = Set-NetbiosRegistry -SettingID $Config.SettingID -TcpipNetbiosOptions $Option
        Write-Host ("   → Registre mis à jour : {0} (NetbiosOptions={1})" -f $reg, $Option) -ForegroundColor Green
    } catch {
        Write-Host ("   → Échec registre : {0}" -f $_.Exception.Message) -ForegroundColor Red
        return
    }

    if (Restart-Adapter -InterfaceIndex $ifx) {
        Write-Host "   → Interface redémarrée." -ForegroundColor Yellow
    } else {
        Write-Host "   → Redémarrage du poste peut être nécessaire." -ForegroundColor Yellow
    }
}

function Set-NetbiosForConfigs {
    param(
        [Parameter(Mandatory)][int]$TcpipNetbiosOptions,
        [Parameter(Mandatory)][object[]]$Configs
    )
    foreach ($cfg in $Configs) {
        Apply-NetbiosToConfig -Config $cfg -Option $TcpipNetbiosOptions
    }
}

function Select-OneConfig {
    param([Parameter(Mandatory)][object[]]$Configs)
    Write-Host ""
    Write-Host "Interfaces IP actives :" -ForegroundColor Cyan
    $i = 1
    foreach ($c in $Configs) {
        $state = Get-NetbiosStateText -Option ($c.TcpipNetbiosOptions)
        Write-Host ("[{0}] {1}  -  IfIndex:{2}  -  NetBIOS:{3}" -f $i, $c.Description, $c.InterfaceIndex, $state)
        $i++
    }
    Write-Host ""
    do {
        $choice = Read-Host "Entrez le numéro de l’interface (Entrée pour annuler)"
        if ([string]::IsNullOrWhiteSpace($choice)) { return $null }
        $ok = $choice -as [int]
    } until ($ok -and $ok -ge 1 -and $ok -le $Configs.Count)
    return $Configs[$choice - 1]
}
#endregion

#region Actions
function Show-NetbiosStatus {
    $cfgs = Get-IpEnabledConfigs
    if (-not $cfgs) { Write-Host "Aucune interface IP active trouvée." -ForegroundColor Yellow; return }
    Write-Host ""
    Write-Host "État NetBIOS over TCP/IP :" -ForegroundColor Cyan
    foreach ($c in $cfgs) {
        $state = Get-NetbiosStateText -Option ($c.TcpipNetbiosOptions)
        Write-Host (" - {0} (IfIndex:{1}) → {2}" -f $c.Description, $c.InterfaceIndex, $state)
    }
}

function Disable-Netbios {
    param([switch]$All)
    $cfgs = Get-IpEnabledConfigs
    if (-not $cfgs) { Write-Host "Aucune interface IP active trouvée." -ForegroundColor Yellow; return }

    if ($All) {
        Write-Host "Désactivation de NetBIOS sur TOUTES les interfaces actives..." -ForegroundColor Cyan
        Set-NetbiosForConfigs -TcpipNetbiosOptions 2 -Configs $cfgs
    } else {
        $one = Select-OneConfig -Configs $cfgs
        if ($one) {
            Write-Host ("Désactivation de NetBIOS sur « {0} »..." -f $one.Description) -ForegroundColor Cyan
            Set-NetbiosForConfigs -TcpipNetbiosOptions 2 -Configs @($one)
        } else {
            Write-Host "Opération annulée." -ForegroundColor Yellow
        }
    }
}

function Restore-NetbiosDefault {
    param([switch]$All)
    $cfgs = Get-IpEnabledConfigs
    if (-not $cfgs) { Write-Host "Aucune interface IP active trouvée." -ForegroundColor Yellow; return }

    if ($All) {
        Write-Host "Restauration de l’état PAR DÉFAUT (DHCP) sur TOUTES les interfaces actives..." -ForegroundColor Cyan
        Set-NetbiosForConfigs -TcpipNetbiosOptions 0 -Configs $cfgs
    } else {
        $one = Select-OneConfig -Configs $cfgs
        if ($one) {
            Write-Host ("Restauration de l’état PAR DÉFAUT (DHCP) sur « {0} »..." -f $one.Description) -ForegroundColor Cyan
            Set-NetbiosForConfigs -TcpipNetbiosOptions 0 -Configs @($one)
        } else {
            Write-Host "Opération annulée." -ForegroundColor Yellow
        }
    }
}

function Reboot-System {
    $answer = Read-Host "Voulez-vous redémarrer le poste maintenant ? (O/N)"
    if ($answer -match '^[Oo]$') {
        Write-Host "Redémarrage en cours..." -ForegroundColor Cyan
        Restart-Computer -Force
    } else {
        Write-Host "Redémarrage annulé." -ForegroundColor Yellow
    }
}
#endregion

#region Menu
if (-not (Test-Admin)) {
    Write-Host "⚠️  Ce script doit être exécuté en tant qu’Administrateur." -ForegroundColor Red
    return
}

$exit = $false
do {
    Write-Host ""
    Write-Host "========== NetBIOS over TCP/IP ==========" -ForegroundColor White
    Write-Host "[1] Afficher l’état"
    Write-Host "[2] Désactiver NetBIOS (interface spécifique)"
    Write-Host "[3] Désactiver NetBIOS (toutes interfaces)"
    Write-Host "[4] Restaurer l’état par défaut (interface spécifique)"
    Write-Host "[5] Restaurer l’état par défaut (toutes interfaces)"
    Write-Host "[6] Redémarrer le poste"
    Write-Host "[0] Quitter"
    $choice = Read-Host "Votre choix"

    switch ($choice) {
        '1' { Show-NetbiosStatus }
        '2' { Disable-Netbios }
        '3' { Disable-Netbios -All }
        '4' { Restore-NetbiosDefault }
        '5' { Restore-NetbiosDefault -All }
        '6' { Reboot-System }
        '0' { $exit = $true }
        default { Write-Host "Choix invalide." -ForegroundColor Yellow }
    }
} until ($exit)

Write-Host "Fin du script." -ForegroundColor DarkGray
#endregion
