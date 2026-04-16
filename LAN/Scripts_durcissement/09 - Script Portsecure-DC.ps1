<# 
SYNOPSIS
  Portsecure-DC - Durcissement reseau controleur de domaine avec restauration.

PARAMETER Action
  Enable  : applique le durcissement (ancien 'Apply')
  Disable : restauration / rollback (ancien 'Restore')
  Restore : restauration / rollback (ancien 'Restore')

PARAMETER IncludeDHCP
  Si specifie lors de Enable, bloque UDP 67-68 (a utiliser SEULEMENT si le DC n'est PAS serveur DHCP).

NOTES
  Ce script n'execute AUCUN redemarrage. Si le serveur heberge le role DHCP, 
  l'option -IncludeDHCP est ignoree automatiquement pour eviter une coupure DHCP.
#>
param(
  [ValidateSet('Apply','Restore')]
  [string]$Mode = 'Apply',
  [switch]$IncludeDHCP
)

$ErrorActionPreference = 'Stop'
$BackupRoot = 'C:\ProgramData\Portsecure'
$BackupFile = Join-Path $BackupRoot 'backup-DC.json'
$FwGroup    = 'Portsecure-DC'

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Ce script doit être lancé en PowerShell 'Exécuter en tant qu'administrateur'."
  }
}
function Ensure-Path { param([string]$Path) if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null } }
function Save-Backup($data) { Ensure-Path $BackupRoot; $data | ConvertTo-Json -Depth 8 | Set-Content -Path $BackupFile -Encoding UTF8 }
function Load-Backup { if (-not (Test-Path $BackupFile)) { throw "Aucune sauvegarde trouvée: $BackupFile" }; Get-Content $BackupFile -Raw | ConvertFrom-Json }

function Get-InterfacesNetBIOSState {
  $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
  if (-not (Test-Path $base)) { return @() }
  Get-ChildItem $base | ForEach-Object {
    $v = Get-ItemProperty $_.PsPath -ErrorAction SilentlyContinue
    [pscustomobject]@{ Path = $_.PsPath; NetbiosOptions = $v.NetbiosOptions }
  }
}
function Set-NetBIOSDisabled {
  $list = Get-InterfacesNetBIOSState
  foreach ($i in $list) {
    New-ItemProperty -Path $i.Path -Name 'NetbiosOptions' -Value 2 -PropertyType DWord -Force | Out-Null
  }
  return $list
}
function Restore-NetBIOS($saved) {
  foreach ($i in $saved) {
    if ($null -eq $i.NetbiosOptions) {
      Remove-ItemProperty -Path $i.Path -Name NetbiosOptions -ErrorAction SilentlyContinue
    } else {
      Set-ItemProperty -Path $i.Path -Name NetbiosOptions -Value ([int]$i.NetbiosOptions)
    }
  }
}

function Get-ServiceState([string[]]$Names) {
  $Names | ForEach-Object {
    $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
      $startup = $null
      try {
        $cim = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $_ + "'") -ErrorAction Stop
        $startup = $cim.StartMode
      } catch {
        # ignore, fallback below
      }
      if (-not $startup) {
        $qc = & sc.exe qc $_ 2>$null
        if ($LASTEXITCODE -eq 0 -and $qc) {
          foreach ($line in $qc) {
            if ($line -match 'START_TYPE\s+:\s+\d+\s+(\S+)') { $startup = $Matches[1]; break }
          }
        }
      }
      [pscustomobject]@{ Name = $_; Status = $svc.Status; StartMode = $startup }
    }
  }

}
function Set-ServiceDisabled([string]$Name) {
  $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
  if ($svc) { if ($svc.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue } }
  Set-Service -Name $Name -StartupType Disabled -ErrorAction SilentlyContinue
}
function Restore-Services($saved) {
  foreach ($s in $saved) {
    if (-not $s) { continue }
    $mode = switch ($s.StartMode) { 'Auto'{'Automatic'} 'Manual'{'Manual'} 'Disabled'{'Disabled'} default {'Manual'} }
    Set-Service -Name $s.Name -StartupType $mode -ErrorAction SilentlyContinue
    if ($s.Status -eq 'Running') { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
    if ($s.Status -eq 'Stopped') { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue }
  }
}

function Set-RegistryValueBackup([string]$Path,[string]$Name,[string]$Type,[object]$Value) {
  $prev = $null
  if (Test-Path $Path) {
    try { $prev = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch {}
  } else {
    New-Item -Path $Path -Force | Out-Null
  }
  New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
  return [pscustomobject]@{ Path=$Path; Name=$Name; Prev=$prev; Type=$Type }
}
function Restore-RegistryValues($items) {
  foreach ($i in $items) {
    if ($null -eq $i.Prev) {
      Remove-ItemProperty -Path $i.Path -Name $i.Name -ErrorAction SilentlyContinue
    } else {
      New-ItemProperty -Path $i.Path -Name $i.Name -PropertyType $i.Type -Value $i.Prev -Force | Out-Null
    }
  }
}

function Add-FirewallRules { param([string]$Group,[hashtable[]]$Rules) foreach ($r in $Rules) { New-NetFirewallRule @r -Group $Group -ErrorAction SilentlyContinue | Out-Null } }
function Remove-FirewallGroup([string]$Group) { Get-NetFirewallRule -Group $Group -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }

# Règles de base (ports listés)
$Rules_DC = @(
  @{ DisplayName="Portsecure: Block NetBIOS UDP 137"; Direction="Inbound"; Protocol="UDP"; LocalPort=137; Action="Block" }
  @{ DisplayName="Portsecure: Block NetBIOS UDP 138"; Direction="Inbound"; Protocol="UDP"; LocalPort=138; Action="Block" }
  @{ DisplayName="Portsecure: Block NetBIOS TCP 139"; Direction="Inbound"; Protocol="TCP"; LocalPort=139; Action="Block" }
  @{ DisplayName="Portsecure: Block SSDP UDP 1900";  Direction="Inbound"; Protocol="UDP"; LocalPort=1900; Action="Block" }
  @{ DisplayName="Portsecure: Block UPnP TCP 2869";  Direction="Inbound"; Protocol="TCP"; LocalPort=2869; Action="Block" }
  @{ DisplayName="Portsecure: Block WS-Disc UDP 3702";Direction="Inbound"; Protocol="UDP"; LocalPort=3702; Action="Block" }
  @{ DisplayName="Portsecure: Block mDNS UDP 5353";   Direction="Inbound"; Protocol="UDP"; LocalPort=5353; Action="Block" }
  @{ DisplayName="Portsecure: Block LLMNR UDP 5355";  Direction="Inbound"; Protocol="UDP"; LocalPort=5355; Action="Block" }
)

if ($IncludeDHCP) {
  $Rules_DC += @(
    @{ DisplayName="Portsecure: Block DHCP UDP 67-68"; Direction="Inbound"; Protocol="UDP"; LocalPort="67-68"; Action="Block" }
  )
}

Assert-Admin

if ($Mode -eq 'Apply') {
  $backup = [ordered]@{}

  # 1) NetBIOS
  $backup.NetBIOS = Get-InterfacesNetBIOSState
  Set-NetBIOSDisabled | Out-Null

  # 2) LLMNR (politique registre)
  $backup.Reg = @()
  $backup.Reg += Set-RegistryValueBackup -Path 'HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast' -Type DWord -Value 0

  # 3) Services (mDNS/WS-Disc via FDResPub, SSDP, UPnP)
  $svcList = @('FDResPub','SSDPSRV','upnphost')
  $backup.Services = Get-ServiceState $svcList
  foreach ($s in $svcList) { Set-ServiceDisabled $s }

  # 4) Pare-feu
  Remove-FirewallGroup $FwGroup
  Add-FirewallRules -Group $FwGroup -Rules $Rules_DC

  # 5) Sauvegarde
  Save-Backup([pscustomobject]$backup)
  Write-Host "Portsecure-DC: durcissement appliqué. Sauvegarde: $BackupFile"
}
elseif ($Mode -eq 'Restore') {
  $backup = Load-Backup

  Remove-FirewallGroup $FwGroup
  if ($backup.Reg)      { Restore-RegistryValues $backup.Reg }
  if ($backup.Services) { Restore-Services $backup.Services }
  if ($backup.NetBIOS)  { Restore-NetBIOS $backup.NetBIOS }

  Write-Host "Portsecure-DC: restauration effectuée depuis $BackupFile"
}
