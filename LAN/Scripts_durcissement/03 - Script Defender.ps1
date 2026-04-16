<# 
.SYNOPSIS
  Configure Windows Defender sans menu interactif, via un argument unique.

.PARAMETER Action
  Enable  = Active la protection en temps réel, CFA, PUA et la protection cloud.
  Disable = Désactive la protection en temps réel, le CFA, la PUA et la protection cloud.
  Restore = Revient aux paramètres Windows par défaut raisonnables (sans forcer un reboot).

.NOTES
  - À exécuter en PowerShell Administrateur.
  - Aucun redémarrage n'est déclenché par ce script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Enable','Disable','Restore')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

function Require-Admin {
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    $wp = New-Object Security.Principal.WindowsPrincipal($wi)
    if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ce script doit être exécuté en tant qu'Administrateur."
    }
}

function Write-Info([string]$m){ Write-Host "[INFO] $m" }
function Write-Ok([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Err([string]$m){ Write-Host "[ERR ] $m" -ForegroundColor Red }
function Write-Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Show-Status {
    try {
        $mp = Get-MpComputerStatus
        Write-Host "=== Windows Defender Status ===" -ForegroundColor Cyan
        "{0,-36} : {1}" -f 'AMServiceEnabled',$mp.AMServiceEnabled | Write-Host
        "{0,-36} : {1}" -f 'AntispywareEnabled',$mp.AntispywareEnabled | Write-Host
        "{0,-36} : {1}" -f 'AntivirusEnabled',$mp.AntivirusEnabled | Write-Host
        "{0,-36} : {1}" -f 'RealTimeProtectionEnabled',$mp.RealTimeProtectionEnabled | Write-Host
        "{0,-36} : {1}" -f 'IoavProtectionEnabled',$mp.IoavProtectionEnabled | Write-Host
        "{0,-36} : {1}" -f 'NISEnabled',$mp.NISEnabled | Write-Host
        "{0,-36} : {1}" -f 'IsTamperProtected',$mp.IsTamperProtected | Write-Host
        Write-Host ""
        $pref = Get-MpPreference
        "{0,-36} : {1}" -f 'PUAProtection',$pref.PUAProtection | Write-Host
        "{0,-36} : {1}" -f 'MAPSReporting',$pref.MAPSReporting | Write-Host
        "{0,-36} : {1}" -f 'CloudBlockLevel',$pref.CloudBlockLevel | Write-Host
        "{0,-36} : {1}" -f 'SubmitSamplesConsent',$pref.SubmitSamplesConsent | Write-Host
        "{0,-36} : {1}" -f 'DisableRealtimeMonitoring',$pref.DisableRealtimeMonitoring | Write-Host
        "{0,-36} : {1}" -f 'EnableControlledFolderAccess',$pref.EnableControlledFolderAccess | Write-Host
        Write-Host ""
    } catch {
        Write-Warn "Impossible de lire le statut : $($_.Exception.Message)"
    }
}

function Do-Enable {
    Write-Info "Activation des protections Defender (temps réel, CFA, PUA, cloud)…"
    # Temps réel ON
    Set-MpPreference -DisableRealtimeMonitoring $false
    # Controlled Folder Access ON (si supporté)
    try { Set-MpPreference -EnableControlledFolderAccess Enabled } catch { Write-Warn "CFA non disponible ou non supporté : $($_.Exception.Message)" }
    # PUA ON
    try { Set-MpPreference -PUAProtection Enabled } catch { Write-Warn "PUA non disponible : $($_.Exception.Message)" }
    # Cloud / MAPS : valeur 2 = Advanced (si permis)
    try { Set-MpPreference -MAPSReporting 2 } catch { Write-Warn "MAPS non disponible : $($_.Exception.Message)" }
    # Blocage cloud agressif (facultatif) : High, si exposé
    try { Set-MpPreference -CloudBlockLevel High } catch { }
    # Consentement échantillons : SendSafeSamples (1)
    try { Set-MpPreference -SubmitSamplesConsent 1 } catch { }
    Write-Ok "Protections activées."
}

function Do-Disable {
    Write-Info "Désactivation des protections Defender (temps réel, CFA, PUA, cloud)…"
    # Temps réel OFF
    Set-MpPreference -DisableRealtimeMonitoring $true
    # CFA OFF
    try { Set-MpPreference -EnableControlledFolderAccess Disabled } catch { }
    # PUA OFF
    try { Set-MpPreference -PUAProtection Disabled } catch { }
    # Cloud / MAPS : 0 = Disabled
    try { Set-MpPreference -MAPSReporting 0 } catch { }
    # Cloud block level : 0 = Default/Off (si supporté)
    try { Set-MpPreference -CloudBlockLevel 0 } catch { }
    Write-Ok "Protections désactivées."
}

function Do-Restore {
    Write-Info "Restauration vers des valeurs par défaut raisonnables…"
    # On remet des valeurs proches du comportement par défaut Microsoft sans forcer un reboot.
    # Temps réel ON (par défaut)
    Set-MpPreference -DisableRealtimeMonitoring $false
    # CFA : laissez par défaut (souvent Désactivé sur clients, Activé par politiques d’entreprise)
    try { Set-MpPreference -EnableControlledFolderAccess Disabled } catch { }
    # PUA : Microsoft recommande Enabled ; plusieurs builds l'ont par défaut sur Entreprise
    try { Set-MpPreference -PUAProtection Enabled } catch { }
    # MAPS : 2 (Advanced) est généralement recommandé ; mettez 1 si vous préférez Basic
    try { Set-MpPreference -MAPSReporting 2 } catch { }
    # CloudBlockLevel : par défaut raisonnable (= 0/Default)
    try { Set-MpPreference -CloudBlockLevel 0 } catch { }
    # SubmitSamplesConsent : 1 = SendSafeSamples
    try { Set-MpPreference -SubmitSamplesConsent 1 } catch { }
    Write-Ok "Paramètres restaurés."
}

try {
    Require-Admin
    Show-Status

    switch ($Action) {
        'Enable'  { Do-Enable }
        'Disable' { Do-Disable }
        'Restore' { Do-Restore }
    }

    Write-Host ""
    Show-Status
    Write-Warn "Aucun redémarrage n'est initié par ce script. Certaines modifications peuvent nécessiter un redémarrage manuel pour un effet complet."
    exit 0
}
catch {
    Write-Err ($_ | Out-String)
    exit 1
}
