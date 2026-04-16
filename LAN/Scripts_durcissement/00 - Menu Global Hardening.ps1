# -*- coding: utf-8 -*-
# =============================================================================
# 00 - Menu Global Hardening.ps1
# =============================================================================
#   - Exécuter en tant qu'Administrateur (élévation automatique si nécessaire).
#   - Conserver tous les scripts .ps1 dans le même dossier que ce menu.
#   - Ce script peut aussi être lancé en mode non interactif avec -Preset/-Action.
# =============================================================================

[CmdletBinding()]
param(
  [ValidateSet('Light','Medium','Heavy')][string]$Preset,
  [ValidateSet('Enable','Disable','Default')][string]$Action
)

# --- Stop on terminating errors inside our functions
$ErrorActionPreference = 'Stop'

#region ======= Admin check & elevation =======
function Test-Admin {
  $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pri = New-Object Security.Principal.WindowsPrincipal($id)
  return $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
  Write-Host "Élévation requise — relance en Administrateur..." -ForegroundColor Yellow
  $psi = New-Object System.Diagnostics.ProcessStartInfo "powershell.exe"
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" " + ($PSBoundParameters.GetEnumerator() | ForEach-Object { "-$($_.Key) `"$($_.Value)`"" }) -join ' '
  $psi.Verb      = "runas"
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
  } catch {
    Write-Error "Élévation refusée."; exit 1
  }
  exit $p.ExitCode
}
#endregion

#region ======= Helpers =======
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function New-LogPath {
  param([string]$ScriptLeaf)
  $dateDir = Get-Date -Format 'yyyyMMdd'
  $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
  $logsDir = Join-Path $BaseDir 'Logs'
  $dayDir  = Join-Path $logsDir $dateDir
  if (-not (Test-Path $dayDir)) { New-Item -Path $dayDir -ItemType Directory -Force | Out-Null }
  $safeName = ($ScriptLeaf -replace '[\\/:*?"<>|]', '_')
  $logFile  = Join-Path $dayDir ("{0} - {1}.log" -f $stamp, $safeName)
  [pscustomobject]@{ LogFile = $logFile; DayDir = $dayDir }
}

function Ensure-RegistryKey {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -Path $Path)) {
    New-Item -Path $Path -ItemType Key -Force | Out-Null
  }
}

function Run-PSFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [string[]]$Args = @()
  )
  if (-not (Test-Path -Path $Path)) {
    Write-Warning ("Introuvable: {0}" -f $Path)
    return 1
  }
  $leaf = Split-Path -Leaf $Path
  $log  = (New-LogPath -ScriptLeaf $leaf).LogFile

  $exe = (Get-Command powershell.exe).Source
  $quotedArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$Path`"") + $Args
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $exe
  $psi.Arguments              = ($quotedArgs -join ' ')
  $psi.UseShellExecute        = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow         = $true

  $p = [System.Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  if ($p.ExitCode -ne 0) {
    ($stdout + "`r`n" + $stderr) | Out-File -FilePath $log -Encoding UTF8
    Write-Warning ("{0} a retourné le code {1}. Voir le journal: {2}" -f $leaf, $p.ExitCode, $log)
  }
  return $p.ExitCode
}

function Run-PSFileWithInput {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter()][string[]]$Inputs
  )
  if (-not (Test-Path -Path $Path)) {
    Write-Warning ("Introuvable: {0}" -f $Path)
    return 1
  }
  $leaf = Split-Path -Leaf $Path
  $log  = (New-LogPath -ScriptLeaf $leaf).LogFile

  $exe = (Get-Command powershell.exe).Source
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $exe
  $psi.Arguments              = "-NoProfile -ExecutionPolicy Bypass -File `"$Path`""
  $psi.UseShellExecute        = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow         = $true

  $p = [System.Diagnostics.Process]::Start($psi)
  if ($Inputs -and $Inputs.Count) {
    $text = ($Inputs -join "`r`n") + "`r`n"
    $p.StandardInput.WriteLine($text)
  }
  $p.StandardInput.Close()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  if ($p.ExitCode -ne 0) {
    ($stdout + "`r`n" + $stderr) | Out-File -FilePath $log -Encoding UTF8
    Write-Warning ("{0} a retourné le code {1}. Voir le journal: {2}" -f $leaf, $p.ExitCode, $log)
  }
  return $p.ExitCode
}

function Press-AnyKey {
  param([string]$Message = "Appuyez sur une touche pour continuer...")
  try {
    if ($Host.Name -match 'ConsoleHost' -and $Host.UI -and $Host.UI.RawUI) {
      Write-Host $Message -ForegroundColor DarkGray
      [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } else {
      throw "NonConsoleHost"
    }
  } catch {
    [void](Read-Host ($Message + " (Entrée)"))
  }
}
#endregion

#region ======= Script paths =======
$ScriptPaths = @{
  EVTLOG = Join-Path $BaseDir "13 - Script EventLogSizing.ps1"
  EP      = Join-Path $BaseDir "01 - Script Antiexploit-DC.ps1"
  CFA     = Join-Path $BaseDir "02 - Script AntiRansomware-DC.ps1"
  DEF     = Join-Path $BaseDir "03 - Script Defender.ps1"
  UAC     = Join-Path $BaseDir "04 - Script Toggle-UAC.ps1"
  NB      = Join-Path $BaseDir "05 - Script NetbiosManager.ps1"
  IGMP    = Join-Path $BaseDir "06 - Script IGMP-SourceRouting.ps1"
  SMB     = Join-Path $BaseDir "07 - Script SMB.ps1"
  PROXY   = Join-Path $BaseDir "08 - Script Proxy.ps1"
  PORT    = Join-Path $BaseDir "09 - Script Portsecure-DC.ps1"
  CD      = Join-Path $BaseDir "10 - Script CrashDump.ps1"
  NTLM    = Join-Path $BaseDir "11 - Script ManageNTLM.ps1"
  KRB     = Join-Path $BaseDir "12 - Script KerberosArmour.ps1"
  # Variantes/CLI optionnelles
  DEFCLI  = Join-Path $BaseDir "03-Defender-CLI.ps1"
  IGMPCLI = Join-Path $BaseDir "06-IGMP-SourceRouting-CLI.ps1"
  IGMPNOMENU = Join-Path $BaseDir "06-IGMP-SourceRouting-NoMenu.ps1"
  CRASHCLI  = Join-Path $BaseDir "10-CrashDump-CLI.ps1"
  CRASHCOMP = Join-Path $BaseDir "10 - Script CrashDump-Compat.ps1"
  PORTCLI   = Join-Path $BaseDir "09 - Script Portsecure-DC.ActionFixed4.ps1"
  NTLMCLI1  = Join-Path $BaseDir "11-ManageNTLM-CLI.ps1"
  NTLMCLI2  = Join-Path $BaseDir "11 - Script ManageNTLM.ps1"
}
foreach ($k in $ScriptPaths.Keys) {
  if (-not (Test-Path $ScriptPaths[$k])) {
    # Information uniquement
    Write-Host ("(Info) Script manquant: {0}" -f $ScriptPaths[$k]) -ForegroundColor DarkGray
  }
}
#endregion

#region ======= Actions par composant =======
# EP
function EP-Activer    { Run-PSFile -Path $ScriptPaths.EP  -Args @('-Mode','Enable')  } 
function EP-Desactiver { Run-PSFile -Path $ScriptPaths.EP  -Args @('-Mode','Disable') } 
function EP-Defaut     { Run-PSFile -Path $ScriptPaths.EP  -Args @('-Mode','Default') } 

# Defender - CFA (02)
function CFA-Activer    { Run-PSFile -Path $ScriptPaths.CFA -Args @('-Enable')  }
function CFA-Desactiver { Run-PSFile -Path $ScriptPaths.CFA -Args @('-Disable') }
function CFA-Defaut     { Run-PSFile -Path $ScriptPaths.CFA -Args @('-Disable') }

# NetBIOS (05) — scripts interactifs attendent des choix numériques
function NB-Activer     { Run-PSFileWithInput -Path $ScriptPaths.NB -Inputs @('5','0') } # Activer NetBIOS
function NB-Desactiver  { Run-PSFileWithInput -Path $ScriptPaths.NB -Inputs @('3','0') } # Désactiver NetBIOS
function NB-Defaut      { Run-PSFileWithInput -Path $ScriptPaths.NB -Inputs @('5','0') }

# UAC — Correction: ne pas tenter de créer une clé existante (évite UnauthorizedAccess)
function UAC-Activer {
  $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  Ensure-RegistryKey -Path $path
  Set-ItemProperty -Path $path -Name 'EnableLUA' -Type DWord -Value 1
  Set-ItemProperty -Path $path -Name 'ConsentPromptBehaviorAdmin' -Type DWord -Value 5
  Write-Host "UAC activé (EnableLUA=1, ConsentPromptBehaviorAdmin=5)." -ForegroundColor Cyan
  Write-Warning 'Un redémarrage est probablement nécessaire pour appliquer les modifications.'
}
function UAC-Desactiver {
  $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  Ensure-RegistryKey -Path $path
  Set-ItemProperty -Path $path -Name 'EnableLUA' -Type DWord -Value 0
  Set-ItemProperty -Path $path -Name 'ConsentPromptBehaviorAdmin' -Type DWord -Value 0
  Write-Host "UAC désactivé (EnableLUA=0, ConsentPromptBehaviorAdmin=0)." -ForegroundColor Yellow
  Write-Warning 'Un redémarrage est probablement nécessaire pour appliquer les modifications.'
}
function UAC-Defaut {
  $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  Ensure-RegistryKey -Path $path
  Set-ItemProperty -Path $path -Name 'EnableLUA' -Type DWord -Value 1
  Set-ItemProperty -Path $path -Name 'ConsentPromptBehaviorAdmin' -Type DWord -Value 5
  Write-Host "UAC : valeurs par défaut appliquées (EnableLUA=1, ConsentPromptBehaviorAdmin=5)." -ForegroundColor Cyan
  Write-Warning 'Un redémarrage est probablement nécessaire pour appliquer les modifications.'
}

# Microsoft Defender (fallback si 03-Defender-CLI absent)
function DEF-Activer {
  if (Test-Path $ScriptPaths.DEFCLI) {
    Run-PSFile -Path $ScriptPaths.DEFCLI -Args @('-Action','Enable')
  } else {
    try {
      Set-MpPreference -DisableRealtimeMonitoring $false
      try { Set-MpPreference -EnableControlledFolderAccess Enabled } catch {}
      try { Set-MpPreference -PUAProtection Enabled } catch {}
      try { Set-MpPreference -MAPSReporting 2 } catch {}
      try { Set-MpPreference -CloudBlockLevel 2 } catch {}
      try { Set-MpPreference -SubmitSamplesConsent 1 } catch {}
      Write-Host "Windows Defender : protection activée (strict)." -ForegroundColor Cyan
    } catch {
      Write-Host $_ -ForegroundColor Yellow
    }
  }
  Write-Warning 'Un redémarrage est probablement nécessaire pour appliquer les modifications.'
}
function DEF-Desactiver {
  if (Test-Path $ScriptPaths.DEFCLI) {
    Run-PSFile -Path $ScriptPaths.DEFCLI -Args @('-Action','Disable')
  } else {
    try {
      Set-MpPreference -DisableRealtimeMonitoring $true
      try { Set-MpPreference -EnableControlledFolderAccess Disabled } catch {}
      try { Set-MpPreference -PUAProtection Disabled } catch {}
      try { Set-MpPreference -MAPSReporting 0 } catch {}
      try { Set-MpPreference -CloudBlockLevel 0 } catch {}
      Write-Host "Windows Defender : protections désactivées." -ForegroundColor Yellow
    } catch {
      Write-Host $_ -ForegroundColor Yellow
    }
  }
  Write-Warning 'Un redémarrage est probablement nécessaire pour appliquer les modifications.'
}
function DEF-Defaut {
  if (Test-Path $ScriptPaths.DEFCLI) {
    Run-PSFile -Path $ScriptPaths.DEFCLI -Args @('-Action','Restore')
  } else {
    try {
      # Valeurs proches du défaut Windows
      Set-MpPreference -DisableRealtimeMonitoring $false
      try { Set-MpPreference -EnableControlledFolderAccess Disabled } catch {}
      try { Set-MpPreference -PUAProtection AuditMode } catch {}
      try { Set-MpPreference -MAPSReporting 1 } catch {}
      try { Set-MpPreference -CloudBlockLevel 1 } catch {}
    } catch {}
  }
  Write-Warning 'Un redémarrage est probablement nécessaire pour appliquer les modifications.'
}

# IGMP & Source Routing
function IGMP-Activer {
  if (Test-Path $ScriptPaths.IGMPCLI) {
    Run-PSFile -Path $ScriptPaths.IGMPCLI -Args @('-Action','Enable')
  } elseif (Test-Path $ScriptPaths.IGMPNOMENU) {
    Run-PSFile -Path $ScriptPaths.IGMPNOMENU -Args @('-Action','Enable')
  } else {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    Ensure-RegistryKey -Path $p
    New-ItemProperty -Path $p -Name 'IGMPLevel' -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $p -Name 'DisableIPSourceRouting' -PropertyType DWord -Value 2 -Force | Out-Null
  }
}
function IGMP-Desactiver {
  if (Test-Path $ScriptPaths.IGMPCLI) {
    Run-PSFile -Path $ScriptPaths.IGMPCLI -Args @('-Action','Disable')
  } elseif (Test-Path $ScriptPaths.IGMPNOMENU) {
    Run-PSFile -Path $ScriptPaths.IGMPNOMENU -Args @('-Action','Disable')
  } else {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    Ensure-RegistryKey -Path $p
    # Désactiver la restriction (valeurs permissives)
    New-ItemProperty -Path $p -Name 'IGMPLevel' -PropertyType DWord -Value 2 -Force | Out-Null
    New-ItemProperty -Path $p -Name 'DisableIPSourceRouting' -PropertyType DWord -Value 0 -Force | Out-Null
  }
}
function IGMP-Defaut {
  if (Test-Path $ScriptPaths.IGMPCLI) {
    Run-PSFile -Path $ScriptPaths.IGMPCLI -Args @('-Action','Restore')
  } elseif (Test-Path $ScriptPaths.IGMPNOMENU) {
    Run-PSFile -Path $ScriptPaths.IGMPNOMENU -Args @('-Action','Restore')
  } else {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    if (Test-Path $p) {
      foreach ($n in 'IGMPLevel','DisableIPSourceRouting') {
        try { Remove-ItemProperty -Path $p -Name $n -ErrorAction Stop } catch {}
      }
    }
  }
}

# SMBv1 (native implementation to avoid interactive blocking)
function SMB-Activer {
  try {
    try { Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force } catch {}
    foreach ($feat in 'SMB1Protocol','SMB1Protocol-Client','SMB1Protocol-Server') {
      try { Enable-WindowsOptionalFeature -Online -FeatureName $feat -NoRestart -ErrorAction Stop | Out-Null } catch {}
    }
    return 0
  } catch {
    Write-Warning $_
    return 1
  }
}
function SMB-Desactiver {
  try {
    try { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force } catch {}
    foreach ($feat in 'SMB1Protocol','SMB1Protocol-Client','SMB1Protocol-Server') {
      try { Disable-WindowsOptionalFeature -Online -FeatureName $feat -NoRestart -ErrorAction Stop | Out-Null } catch {}
    }
    return 0
  } catch {
    Write-Warning $_
    return 1
  }
}
function SMB-Defaut {
  # Windows Server modernes : SMBv1 désactivé par défaut
  return (SMB-Desactiver)
}

# Proxy
#function PROXY-Activer    { Run-PSFile -Path $ScriptPaths.PROXY -Args @('-Action','Enable')  }
function PROXY-Activer    { Run-PSFile -Path $ScriptPaths.PROXY -Args @('Enable')  }
function PROXY-Desactiver { Run-PSFile -Path $ScriptPaths.PROXY -Args @('-Mode','Disable') }
function PROXY-Defaut     { Run-PSFile -Path $ScriptPaths.PROXY -Args @('Restore') }

# Portsecure
function PORT-Activer {
  if (Test-Path $ScriptPaths.PORTCLI) {
    Run-PSFile -Path $ScriptPaths.PORTCLI -Args @('-Action','Enable')
  } else {
    Run-PSFile -Path $ScriptPaths.PORT -Args @('-Mode','Apply')
  }
  Write-Warning 'Un redémarrage est probablement nécessaire pour appliquer les modifications.'
}
function PORT-Desactiver {
  if (Test-Path $ScriptPaths.PORTCLI) {
    Run-PSFile -Path $ScriptPaths.PORTCLI -Args @('-Action','Disable')
  } else {
    Run-PSFile -Path $ScriptPaths.PORT -Args @('-Mode','Disable')
  }
  Write-Warning 'Un redémarrage est probablement nécessaire pour appliquer les modifications.'
}
function PORT-Defaut {
  if (Test-Path $ScriptPaths.PORTCLI) {
    Run-PSFile -Path $ScriptPaths.PORTCLI -Args @('-Action','Restore')
  } else {
    Run-PSFile -Path $ScriptPaths.PORT -Args @('-Mode','Restore')
  }
  Write-Warning 'Un redémarrage est probablement nécessaire pour appliquer les modifications.'
}

# CrashDump — wrapper centralisé
function Step-CrashDump-Enable {
  if (Test-Path $ScriptPaths.CRASHCOMP) { Run-PSFile -Path $ScriptPaths.CRASHCOMP -Args @('-Action','Enable') }
  elseif (Test-Path $ScriptPaths.CRASHCLI) { Run-PSFile -Path $ScriptPaths.CRASHCLI -Args @('-Action','Enable') }
  elseif (Test-Path $ScriptPaths.CD) { Run-PSFileWithInput -Path $ScriptPaths.CD -Inputs @('2','0') }
  else { Write-Warning 'Script CrashDump introuvable.' }
}
function Step-CrashDump-Disable {
  if (Test-Path $ScriptPaths.CRASHCOMP) { Run-PSFile -Path $ScriptPaths.CRASHCOMP -Args @('-Action','Disable') }
  elseif (Test-Path $ScriptPaths.CRASHCLI) { Run-PSFile -Path $ScriptPaths.CRASHCLI -Args @('-Action','Disable') }
  elseif (Test-Path $ScriptPaths.CD) { Run-PSFileWithInput -Path $ScriptPaths.CD -Inputs @('3','0') }
  else { Write-Warning 'Script CrashDump introuvable.' }
}
function Step-CrashDump-Default {
  if (Test-Path $ScriptPaths.CRASHCOMP) { Run-PSFile -Path $ScriptPaths.CRASHCOMP -Args @('-Action','Restore') }
  elseif (Test-Path $ScriptPaths.CRASHCLI) { Run-PSFile -Path $ScriptPaths.CRASHCLI -Args @('-Action','Restore') }
  elseif (Test-Path $ScriptPaths.CD) { Run-PSFileWithInput -Path $ScriptPaths.CD -Inputs @('4','0') }
  else { Write-Warning 'Script CrashDump introuvable.' }
}

# NTLM — wrapper centralisé (corrige l’erreur « NTLM-Activer non reconnu »)
function Step-NTLM-Enable {
  if (Test-Path $ScriptPaths.NTLMCLI1) { Run-PSFile -Path $ScriptPaths.NTLMCLI1 -Args @('-Action','Enable') }
  elseif (Test-Path $ScriptPaths.NTLMCLI2) { Run-PSFile -Path $ScriptPaths.NTLMCLI2 -Args @('-Action','Enable') }
  elseif (Test-Path $ScriptPaths.NTLM)    { Run-PSFileWithInput -Path $ScriptPaths.NTLM -Inputs @('2','0') } # 2=Enable dans l'ancien menu
  else {
    $BaseKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
    Ensure-RegistryKey -Path $BaseKey
    New-ItemProperty -Path $BaseKey -Name 'RestrictReceivingNTLMTraffic' -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $BaseKey -Name 'RestrictSendingNTLMTraffic'  -PropertyType DWord -Value 0 -Force | Out-Null
  }
  Write-Warning 'Un redémarrage est probablement nécessaire pour appliquer les modifications.'
}
function Step-NTLM-Disable {
  if (Test-Path $ScriptPaths.NTLMCLI1) { Run-PSFile -Path $ScriptPaths.NTLMCLI1 -Args @('-Action','Disable') }
  elseif (Test-Path $ScriptPaths.NTLMCLI2) { Run-PSFile -Path $ScriptPaths.NTLMCLI2 -Args @('-Action','Disable') }
  elseif (Test-Path $ScriptPaths.NTLM)    { Run-PSFileWithInput -Path $ScriptPaths.NTLM -Inputs @('3','0') } # 3=Disable
  else {
    $BaseKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
    Ensure-RegistryKey -Path $BaseKey
    New-ItemProperty -Path $BaseKey -Name 'RestrictReceivingNTLMTraffic' -PropertyType DWord -Value 2 -Force | Out-Null
    New-ItemProperty -Path $BaseKey -Name 'RestrictSendingNTLMTraffic'  -PropertyType DWord -Value 2 -Force | Out-Null
  }
  Write-Warning 'Un redémarrage est probablement nécessaire pour appliquer les modifications.'
}
function Step-NTLM-Default {
  if (Test-Path $ScriptPaths.NTLMCLI1) { Run-PSFile -Path $ScriptPaths.NTLMCLI1 -Args @('-Action','Restore') }
  elseif (Test-Path $ScriptPaths.NTLMCLI2) { Run-PSFile -Path $ScriptPaths.NTLMCLI2 -Args @('-Action','Restore') }
  else {
    $BaseKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
    $LsaKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    Ensure-RegistryKey -Path $BaseKey
    New-ItemProperty -Path $BaseKey -Name 'RestrictReceivingNTLMTraffic' -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $BaseKey -Name 'RestrictSendingNTLMTraffic'  -PropertyType DWord -Value 0 -Force | Out-Null
    try { Remove-ItemProperty -Path $BaseKey -Name 'ClientAllowedNTLMServers' -ErrorAction Stop } catch {}
    try { Remove-ItemProperty -Path $LsaKey  -Name 'LmCompatibilityLevel'   -ErrorAction Stop } catch {}
  }
}

# Kerberos Armour/FAST — wrappers centralisés (corrige « KRB-Activer non reconnu »)
function Step-KRB-Enable {
  if (Test-Path $ScriptPaths.KRB) {
    # Script interactif historique : 2 = Enable, 0 = Quit
    Run-PSFileWithInput -Path $ScriptPaths.KRB -Inputs @('2','0')
  } else {
    $KdcParams = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\KDC\Parameters'
    Ensure-RegistryKey -Path $KdcParams
    New-ItemProperty -Path $KdcParams -Name 'EnableCbacAndArmor' -PropertyType DWord -Value 1 -Force | Out-Null
    # Optionnel : niveau (0=None,1=Supported,2=Required) — laisser non défini par défaut
    # New-ItemProperty -Path $KdcParams -Name 'CbacAndArmorLevel' -PropertyType DWord -Value 1 -Force | Out-Null
  }
}
function Step-KRB-Disable {
  if (Test-Path $ScriptPaths.KRB) {
    Run-PSFileWithInput -Path $ScriptPaths.KRB -Inputs @('3','0') # 3=Disable
  } else {
    $KdcParams = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\KDC\Parameters'
    if (Test-Path $KdcParams) {
      try { Remove-ItemProperty -Path $KdcParams -Name 'EnableCbacAndArmor' -ErrorAction Stop } catch {}
      try { Remove-ItemProperty -Path $KdcParams -Name 'CbacAndArmorLevel' -ErrorAction Stop } catch {}
    }
  }
}
function Step-KRB-Default {
  Step-KRB-Disable
}
function Step-KRB-Status {
  $KdcParams = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\KDC\Parameters'
  $en = $null; $lv = $null
  if (Test-Path $KdcParams) {
    try { $en = (Get-ItemProperty -Path $KdcParams -Name 'EnableCbacAndArmor' -ErrorAction Stop).EnableCbacAndArmor } catch {}
    try { $lv = (Get-ItemProperty -Path $KdcParams -Name 'CbacAndArmorLevel'  -ErrorAction Stop).CbacAndArmorLevel } catch {}
  }
  Write-Host '--- Kerberos Armoring (KDC) status ---' -ForegroundColor DarkCyan
  Write-Host ("  Path : {0}" -f $KdcParams)
  Write-Host ("  EnableCbacAndArmor = {0}" -f ($(if ($null -eq $en) {'(not set)'} else {$en})))
  Write-Host ("  CbacAndArmorLevel  = {0}" -f ($(if ($null -eq $lv) {'(not set)'} else {$lv})))
}

# Alias conviviaux (conservent vos intitulés historiques)
function NTLM-Activer     { Step-NTLM-Enable }
function NTLM-Desactiver  { Step-NTLM-Disable }
function NTLM-Defaut      { Step-NTLM-Default }
function KRB-Activer      { Step-KRB-Enable }
function KRB-Desactiver   { Step-KRB-Disable }
function KRB-Defaut       { Step-KRB-Default }
function KRB-Status       { Step-KRB-Status }
#endregion


#region ======= Menu 4 : Hardening manuel (boucle + retour + couleur dynamique) =======
function Menu-4-Hardening {
  # Hashtable pour suivre l'état courant (Enable/Restore) de chaque option
  $statusMap = @{}
  foreach ($i in 1..11) { $statusMap["$i"] = "None" }

  while ($true) {
    Clear-Host
    Write-Host "=== Menu 4 — Hardening manuel ===" -ForegroundColor Cyan
    Write-Host ""

    $labels = @(
      "1  - Modification Anti-Exploit"
      "2  - Modification Anti-Reansomware"
      "3  - Modification Defender"
      "4  - Modification UAC"
      "5  - Modification NetBIOS"
      "6  - Modification IGMP et Source Routing"
      "7  - Modification SMB"
      "8  - Modification Proxy"
      "9  - Modification Securisation des Ports"
      "10 - Modification Crash Dump"
      "11 - Modification NTLM"
    )

    for ($i=0; $i -lt $labels.Count; $i++) {
      $idx = ($i+1).ToString()
      $label = $labels[$i]
      switch ($statusMap[$idx]) {
        "Enable"   { Write-Host $label -ForegroundColor Green }
        "Restore"  { Write-Host $label -ForegroundColor White }
        default    { Write-Host $label }
      }
    }
    Write-Host "0  - Retour au menu principal"
    Write-Host ""

    $map = @{
      '1'  = @{ Label="Modification Anti-Exploit";            Enable={ EP-Activer };                 Restore={ EP-Desactiver } }
      '2'  = @{ Label="Modification Anti-Reansomware";        Enable={ CFA-Activer };                Restore={ CFA-Desactiver } }
      '3'  = @{ Label="Modification Defender";                Enable={ DEF-Activer };                Restore={ DEF-Desactiver } }
      '4'  = @{ Label="Modification UAC";                     Enable={ UAC-Activer };                Restore={ UAC-Desactiver } }
      '5'  = @{ Label="Modification NetBIOS";                 Enable={ NB-Activer };                 Restore={ NB-Desactiver } }
      '6'  = @{ Label="Modification IGMP et Source Routing";  Enable={ IGMP-Activer };               Restore={ IGMP-Desactiver } }
      '7'  = @{ Label="Modification SMB";                     Enable={ SMB-Activer };                Restore={ SMB-Desactiver } }
      '8'  = @{ Label="Modification Proxy";                   Enable={ PROXY-Activer };              Restore={ PROXY-Desactiver } }
      '9'  = @{ Label="Modification Securisation des Ports";  Enable={ PORT-Activer };               Restore={ PORT-Desactiver } }
      '10' = @{ Label="Modification Crash Dump";              Enable={ Step-CrashDump-Enable };      Restore={ Step-CrashDump-Disable } }
      '11' = @{ Label="Modification NTLM";                    Enable={ NTLM-Activer };               Restore={ NTLM-Desactiver } }
    }

    # 1) Sélection
    $selection = $null
    do {
      $selection = Read-Host "Afin d'activer le hardening, sélectionnez la modification à prendre en compte (1-11) ou 0 pour Retour"
      if ($selection -in @('0','r','R','retour','Retour')) { break }
      if ($map.ContainsKey($selection)) { break }
      Write-Host "Choix invalide. Entrez 1-11 pour une modification ou 0 pour Retour." -ForegroundColor Yellow
    } while ($true)

    if ($selection -in @('0','r','R','retour','Retour')) {
      break
    }

    # 2) Action (1/2)
    $action = $null
    do {
      $action = Read-Host "Que voulez-vous faire : 1 pour l'activation ou 2 pour la restauration au niveau Windows"
      if ($action -in @('1','2')) { break }
      Write-Host "Choix invalide. Entrez 1 (activation) ou 2 (restauration)." -ForegroundColor Yellow
    } while ($true)

    $entry = $map[$selection]
    try {
      if ($action -eq '1') {
        & $entry.Enable
        $statusMap[$selection] = "Enable"
        Write-Host "[" -NoNewline
        Write-Host $entry.Label -ForegroundColor Green -NoNewline
        Write-Host "] Statut: Activation effectuée."
      } else {
        & $entry.Restore
        $statusMap[$selection] = "Restore"
        Write-Host "[" -NoNewline
        Write-Host $entry.Label -ForegroundColor White -NoNewline
        Write-Host "] Statut: Restauration effectuée."
      }
    } catch {
      Write-Host ("Erreur lors de l'exécution de '{0}': {1}" -f $entry.Label, $_.Exception.Message) -ForegroundColor Red
    }

    # Pause
    if ($Host.Name -match 'ConsoleHost') {
      Write-Host "Appuyez sur une touche pour continuer..." -ForegroundColor Cyan
      try { [void][System.Console]::ReadKey($true) } catch { Read-Host 'Appuyez sur Entrée pour continuer...' | Out-Null }
    } else {
      Read-Host 'Appuyez sur Entrée pour continuer...' | Out-Null
    }
  }
}
#endregion

#region ======= Exécuteurs de presets =======
function Invoke-Step {
  param([string]$Label,[scriptblock]$Action)
  Write-Host ('  - {0} ...' -f $Label) -ForegroundColor DarkGray
  $hadError = $false
  $rc = $null
  try {
    $rc = & $Action
  } catch {
    $hadError = $true
    $global:_lastError = $_
  }
  # Suppress emitting return value
  $null = $rc
  if (-not $hadError) {
    if ($null -ne $rc) {
      if ($rc -is [int]) { if ($rc -ne 0) { $hadError = $true } }
      elseif ($rc -is [bool]) { if (-not $rc) { $hadError = $true } }
    }
  }
  if ($hadError) {
    Write-Host "    → Le paramétrage a généré une erreur." -ForegroundColor Red
    Write-Host "      Consultez les journaux dans le dossier Logs\<date> pour le détail." -ForegroundColor DarkGray
  } else {
    Write-Host "    → Le paramétrage a été effectué avec succès." -ForegroundColor Green
  }
}


function Apply-Preset {
  param(
    [ValidateSet('Light','Medium','Heavy')][string]$Preset,
    [ValidateSet('Enable','Disable','Default')][string]$Action
  )

  Write-Host ""
  Write-Host ("== {0} - {1} ==" -f $Preset, $Action) -ForegroundColor Cyan

  switch ($Preset) {
    'Light' {
      # Remarque : sur Light, "Enable (hardening)" => désactiver NetBIOS (mapping intentionnel)
      $steps = @(
        @{label='Exploit Protection'; onEnable={EP-Activer}; onDisable={EP-Desactiver}; onDefault={EP-Defaut}},
        @{label='Defender - CFA';     onEnable={CFA-Activer}; onDisable={CFA-Desactiver}; onDefault={CFA-Defaut}},
        @{label='NetBIOS';            onEnable={NB-Desactiver}; onDisable={NB-Activer};  onDefault={NB-Defaut}}, # swapped for Light
        @{label='SMBv1';              onEnable={SMB-Activer}; onDisable={SMB-Desactiver}; onDefault={SMB-Defaut}}
      )
    }
    'Medium' {
      $steps = @(
        @{label='Exploit Protection'; onEnable={EP-Activer}; onDisable={EP-Desactiver}; onDefault={EP-Defaut}},
        @{label='Defender - CFA';     onEnable={CFA-Activer}; onDisable={CFA-Desactiver}; onDefault={CFA-Defaut}},
        @{label='NetBIOS';            onEnable={NB-Activer};  onDisable={NB-Desactiver}; onDefault={NB-Defaut}},
        @{label='IGMP & Source Routing'; onEnable={IGMP-Activer}; onDisable={IGMP-Desactiver}; onDefault={IGMP-Defaut}},
        @{label='SMBv1';              onEnable={SMB-Activer}; onDisable={SMB-Desactiver}; onDefault={SMB-Defaut}},
        @{label='Proxy auto';         onEnable={PROXY-Activer}; onDisable={PROXY-Desactiver}; onDefault={PROXY-Defaut}},
        @{label='Portsecure-DC';      onEnable={PORT-Activer}; onDisable={PORT-Desactiver}; onDefault={PORT-Defaut}}
      )
    }
    'Heavy' {
      $steps = @(
        @{label='Exploit Protection'; onEnable={EP-Activer}; onDisable={EP-Desactiver}; onDefault={EP-Defaut}},
        @{label='Defender - CFA';     onEnable={CFA-Activer}; onDisable={CFA-Desactiver}; onDefault={CFA-Defaut}},
        @{label='Microsoft Defender (AV)'; onEnable={DEF-Activer}; onDisable={DEF-Desactiver}; onDefault={DEF-Defaut}},
        @{label='UAC';                onEnable={UAC-Activer}; onDisable={UAC-Desactiver}; onDefault={UAC-Defaut}},
        @{label='NetBIOS';            onEnable={NB-Activer};  onDisable={NB-Desactiver};  onDefault={NB-Defaut}},
        @{label='IGMP & Source Routing'; onEnable={IGMP-Activer}; onDisable={IGMP-Desactiver}; onDefault={IGMP-Defaut}},
        @{label='SMBv1';              onEnable={SMB-Activer}; onDisable={SMB-Desactiver}; onDefault={SMB-Defaut}},
        @{label='Proxy auto';         onEnable={PROXY-Activer}; onDisable={PROXY-Desactiver}; onDefault={PROXY-Defaut}},
        @{label='Portsecure-DC';      onEnable={PORT-Activer}; onDisable={PORT-Desactiver}; onDefault={PORT-Defaut}},
        @{label='CrashDump';          onEnable={ Step-CrashDump-Enable }; onDisable={ Step-CrashDump-Disable }; onDefault={ Step-CrashDump-Default }},
        @{label='NTLM';               onEnable={ Step-NTLM-Enable      }; onDisable={ Step-NTLM-Disable      }; onDefault={ Step-NTLM-Default      }}
#        @{label='Kerberos FAST';      onEnable={ KRB-Activer           }; onDisable={ KRB-Desactiver         }; onDefault={ KRB-Defaut              }}
      )
    }
  }

  $errors = 0
  switch ($Action) {
    'Enable'  { foreach ($s in $steps) { $prev = $global:_lastError; $global:_lastError = $null; Invoke-Step -Label $s.label -Action $s.onEnable;  if ($global:_lastError) { $errors++ } } }
    'Disable' { foreach ($s in $steps) { $prev = $global:_lastError; $global:_lastError = $null; Invoke-Step -Label $s.label -Action $s.onDisable; if ($global:_lastError) { $errors++ } } }
    'Default' { foreach ($s in $steps) { $prev = $global:_lastError; $global:_lastError = $null; Invoke-Step -Label $s.label -Action $s.onDefault; if ($global:_lastError) { $errors++ } } }
  }
  if ($errors -gt 0) {
    Write-Host ""
    Write-Host ("Résultat global: {0} étape(s) ont généré une erreur." -f $errors) -ForegroundColor Red
  } else {
    Write-Host ""
    Write-Host "Résultat global: Le paramétrage a été effectué avec succès." -ForegroundColor Green
  }
}
#endregion

#region ======= Menu principal =======
function Main-Menu {
  do {
    Clear-Host
    Write-Host "=== Menu de durcissement Windows ===" -ForegroundColor Cyan
    Write-Host "1) Light"
    Write-Host "2) Medium"
    Write-Host "3) Heavy"
    Write-Host "4) Manuel"
    Write-Host "5) Modification de la taille des journaux d\'évènements"
    Write-Host "6) Kerberos Armoring (DC)"
    Write-Host "7) Reboot" -ForegroundColor Red
    Write-Host "8) Quit"
    $choice = Read-Host "Votre choix"

    switch ($choice) {      '4' {
        Menu-4-Hardening
      }

      '1' {
        $act = Read-Host "Light: 1=Activation, 2=Restauration"
        Write-Host "Ceci active ou restaure Anti-Exploit, Anti-Ransomware, Netbios et SMBv1" 
        switch ($act) {
          '1' { Apply-Preset -Preset Light -Action Enable  }
          #'2' { Apply-Preset -Preset Light -Action Disable }
          '2' { Apply-Preset -Preset Light -Action Default }
          default { Write-Host "Choix invalide." -ForegroundColor Yellow; Start-Sleep 1 }
        }
        Press-AnyKey
      }
      '2' {
        $act = Read-Host "Medium: 1=Activation, 2=Restauration"
        Write-Host "Ceci active ou restaure Anti-Exploit, Anti-Ransomware, Netbios, IGMP, Source Routing, SMBv1, Configuration du proxy et la Securisation de ports"
        switch ($act) {
          '1' { Apply-Preset -Preset Medium -Action Enable  }
 #         '2' { Apply-Preset -Preset Medium -Action Disable }
          '2' { Apply-Preset -Preset Medium -Action Default }
          default { Write-Host "Choix invalide." -ForegroundColor Yellow; Start-Sleep 1 }
        }
        Press-AnyKey
      }
      '3' {
        $act = Read-Host "Heavy: 1=Activation, 2=Restauration"
        Write-Host "Ceci active ou restaure Anti-Exploit, Anti-Ransomware, Netbios, IGMP, Source Routing, SMBv1, Configuration du proxy, Securisation de ports, le Crash Dump et le NTLM"
        switch ($act) {
          '1' { Apply-Preset -Preset Heavy -Action Enable  }
          #'2' { Apply-Preset -Preset Heavy -Action Disable }
          '2' { Apply-Preset -Preset Heavy -Action Default }
          default { Write-Host "Choix invalide." -ForegroundColor Yellow; Start-Sleep 1 }
        }
        Press-AnyKey
      }
      '5' {
        $evt = Join-Path $PSScriptRoot '13 - Script EventLogSizing.ps1'
        if (-not (Test-Path -Path $evt)) {
          Write-Host "(Info) Script manquant: $evt" -ForegroundColor DarkGray
        } else {
          & $evt
        }
        Press-AnyKey
      }
      '6' {
        $kerb = Join-Path $PSScriptRoot '12 - Script KerberosArmour.ps1'
        if (-not (Test-Path -Path $kerb)) {
          Write-Host "(Info) Script manquant: $kerb" -ForegroundColor DarkGray
        } else {
          & $kerb
        }
        Press-AnyKey
      }
      '7' {
        $ans = Read-Host "Redémarrer maintenant ? (O/N)"
        if ($ans -match '^[OoYy]') { Restart-Computer -Force }
      }
      '8' { return }
      default { Write-Host "Choix invalide." -ForegroundColor Yellow; Start-Sleep 1 }
    }
  } while ($true)

  Write-Host "Au revoir." -ForegroundColor Green
}
#endregion

# --- Exécution ---
if ($PSBoundParameters.ContainsKey('Preset') -and $PSBoundParameters.ContainsKey('Action')) {
  Apply-Preset -Preset $Preset -Action $Action
} else {
  Main-Menu
}
