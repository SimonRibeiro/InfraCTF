<#
.SYNOPSIS
  Configure IGMP et IP Source Routing sans menu interactif ni reboot.

.PARAMETER Action
  Status  = Affiche l’état actuel
  Enable  = Applique le durcissement (IGMP désactivé, Source Routing désactivé)
  Disable = Annule le durcissement (IGMP v2, Source Routing activé)
  Restore = Restaure les valeurs par défaut
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Status','Enable','Disable','Restore')]
    [string]$Action
)

$TcpipRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
$IfRoot    = Join-Path $TcpipRoot 'Interfaces'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RegistryValue($Path,$Name) {
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Set-RegistryDword($Path,$Name,$Value) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Remove-RegistryValue($Path,$Name) {
    try {
        if (Test-Path $Path) {
            Remove-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
            return $true
        }
    } catch {}
    return $false
}

function Get-InterfaceFriendlyName($Guid) {
    try {
        $nic = Get-NetAdapter -InterfaceGuid $Guid -ErrorAction SilentlyContinue
        if ($nic) { return $nic.Name }
    } catch {}
    return $null
}

function Show-Status {
    Write-Host '=== GLOBAL STATUS ===' -ForegroundColor Cyan

    $igmp = Get-RegistryValue $TcpipRoot 'IGMPLevel'
    $srcR = Get-RegistryValue $TcpipRoot 'DisableIPSourceRouting'

    $igmpText = if ($igmp -eq $null) { 'not set (system default)' }
                elseif ($igmp -eq 0) { '0 (IGMP disabled)' }
                elseif ($igmp -eq 1) { '1 (IGMP v1)' }
                elseif ($igmp -eq 2) { '2 (IGMP v2)' }
                else { "$igmp (custom value)" }

    $srcText  = if ($srcR -eq $null) { 'not set (system default)' }
                elseif ($srcR -eq 0) { '0 (enabled)' }
                elseif ($srcR -eq 1) { '1 (disabled except local)' }
                elseif ($srcR -eq 2) { '2 (fully disabled)' }
                else { "$srcR (custom value)" }

    Write-Host ("IGMPLevel              : {0}" -f $igmpText)
    Write-Host ("DisableIPSourceRouting : {0}" -f $srcText)
    Write-Host ''

    Write-Host '=== PER-INTERFACE OVERRIDES ===' -ForegroundColor Cyan
    if (Test-Path $IfRoot) {
        $ifs = Get-ChildItem -Path $IfRoot -ErrorAction SilentlyContinue
        $found = $false
        foreach ($i in $ifs) {
            $ig = Get-RegistryValue $i.PSPath 'IGMPLevel'
            $sr = Get-RegistryValue $i.PSPath 'DisableIPSourceRouting'
            if ($ig -ne $null -or $sr -ne $null) {
                $found = $true
                $guid = Split-Path $i.Name -Leaf
                $name = Get-InterfaceFriendlyName $guid
                if (-not $name) { $name = $guid }
                $igDesc = if ($ig -eq $null) { 'not set' } else { $ig }
                $srDesc = if ($sr -eq $null) { 'not set' } else { $sr }
                Write-Host ("- {0} : IGMPLevel={1} ; DisableIPSourceRouting={2}" -f $name, $igDesc, $srDesc)
            }
        }
        if (-not $found) { Write-Host '(no per-interface overrides found)' }
    } else {
        Write-Host '(no Interfaces node under expected registry path)'
    }
    Write-Host ''
}

function Disable-IGMP-And-SourceRouting {
    Write-Host 'Disabling IGMP and Source Routing...' -ForegroundColor Yellow
    Set-RegistryDword $TcpipRoot 'IGMPLevel' 0
    Set-RegistryDword $TcpipRoot 'DisableIPSourceRouting' 2
    Write-Host 'Done. A reboot is recommended for changes to take full effect.' -ForegroundColor Green
}

function Reset-To-Defaults {
    Write-Host 'Resetting registry values...' -ForegroundColor Yellow
    $removed1 = Remove-RegistryValue $TcpipRoot 'IGMPLevel'
    $removed2 = Remove-RegistryValue $TcpipRoot 'DisableIPSourceRouting'
    Write-Host (" - Global: IGMPLevel removed: {0}, DisableIPSourceRouting removed: {1}" -f $removed1, $removed2)
    if (Test-Path $IfRoot) {
        $count = 0
        foreach ($i in (Get-ChildItem -Path $IfRoot -ErrorAction SilentlyContinue)) {
            $r1 = Remove-RegistryValue $i.PSPath 'IGMPLevel'
            $r2 = Remove-RegistryValue $i.PSPath 'DisableIPSourceRouting'
            if ($r1 -or $r2) { $count++ }
        }
        Write-Host (" - Interfaces: {0} override(s) removed." -f $count)
    }
    Write-Host 'A reboot may be required for changes to take full effect.' -ForegroundColor Green
}

# --- MAIN ---
if (-not (Test-IsAdmin)) {
    Write-Warning 'Run this script as Administrator.'
    exit 1
}

switch ($Action) {
    'Status'  { Show-Status }
    'Enable'  { Disable-IGMP-And-SourceRouting }
    'Disable' { Write-Host 'Re-enabling IGMP (v2) and allowing Source Routing...' -ForegroundColor Yellow;
                Set-RegistryDword $TcpipRoot 'IGMPLevel' 2;
                Set-RegistryDword $TcpipRoot 'DisableIPSourceRouting' 0;
                Write-Host 'Done. A reboot is recommended for changes to take full effect.' -ForegroundColor Green }
    'Restore' { Reset-To-Defaults }
}
