#requires -version 5.1
<# 
.SYNOPSIS
  Configure les Crash Dumps Windows sans menu, avec compatibilité d'arguments.

.DESCRIPTION
  Actions prises en charge :
    - Enable  : CrashDumpEnabled = 7 (Automatique)
    - Disable : CrashDumpEnabled = 0
    - Restore : suppression de CrashDumpEnabled (valeur par défaut Windows)
    - Status  : affiche simplement l'état courant

  Compatibilité :
    - Accepte aussi : 2 => Enable, 3 => Disable, 1 => Status
    - Accepte aussi l'ancien paramètre -Mode : Apply => Enable, Restore => Restore

  Aucun redémarrage n'est lancé par ce script.
#>

[CmdletBinding()]
param(
    [string]$Action,   # Enable|Disable|Restore|Status ou 1|2|3
    [string]$Mode      # Compat: Apply|Restore (ancien script)
)

$ErrorActionPreference = 'Stop'
$CrashKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
$CrashName = 'CrashDumpEnabled'

function Require-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ce script doit être exécuté en tant qu'Administrateur."
    }
}

function Write-Info([string]$m){ Write-Host "[INFO] $m" }
function Write-Ok([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Err([string]$m){ Write-Host "[ERR ] $m" -ForegroundColor Red }
function Write-Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Get-CrashDumpEnabled {
    try { (Get-ItemProperty -Path $CrashKey -Name $CrashName -ErrorAction Stop).$CrashName } catch { $null }
}

function Show-Status {
    $v = Get-CrashDumpEnabled
    $desc = switch ($v) {
        $null { '(non défini - valeurs par défaut Windows)' }
        0     { '0 = Désactivé' }
        1     { '1 = Dump complet' }
        2     { '2 = Dump noyau' }
        3     { '3 = Petit dump (Minidump)' }
        7     { '7 = Dump automatique (recommandé par défaut)' }
        default { "$v = valeur personnalisée" }
    }
    Write-Info "Clé : $CrashKey"
    Write-Host " - $CrashName : $desc"
}

function Ensure-Key { if (-not (Test-Path $CrashKey)) { New-Item -Path $CrashKey -Force | Out-Null } }

function Do-Enable {
    Ensure-Key
    New-ItemProperty -Path $CrashKey -Name $CrashName -PropertyType DWord -Value 7 -Force | Out-Null
    Write-Ok "CrashDumpEnabled=7 (Automatique) appliqué."
}
function Do-Disable {
    Ensure-Key
    New-ItemProperty -Path $CrashKey -Name $CrashName -PropertyType DWord -Value 0 -Force | Out-Null
    Write-Ok "CrashDumpEnabled=0 (Désactivé) appliqué."
}
function Do-Restore {
    if (Test-Path $CrashKey) {
        try { Remove-ItemProperty -Path $CrashKey -Name $CrashName -ErrorAction Stop } catch { }
    }
    Write-Ok "Valeur $CrashName supprimée (Windows appliquera ses valeurs par défaut)."
}

# --- Compatibilité & normalisation de l'action ---
if (-not $Action -and $Mode) {
    if ($Mode -match '^(?i)Apply|Enable$') { $Action = 'Enable' }
    elseif ($Mode -match '^(?i)Restore$')  { $Action = 'Restore' }
}

if (-not $Action) { $Action = 'Status' }

switch -Regex ($Action) {
    '^(?i)(2|enable|apply)$'   { $Action = 'Enable'  }
    '^(?i)(3|disable)$'        { $Action = 'Disable' }
    '^(?i)(restore|default)$'  { $Action = 'Restore' }
    '^(?i)(1|status)$'         { $Action = 'Status'  }
    default { throw "Action non reconnue: '$Action'. Utilisez Enable, Disable, Restore, Status (ou 1/2/3)." }
}

try {
    Require-Admin
    Show-Status
    switch ($Action) {
        'Enable'  { Do-Enable }
        'Disable' { Do-Disable }
        'Restore' { Do-Restore }
        'Status'  { }
    }
    Write-Host ""
    Show-Status
    Write-Warn "Aucun redémarrage n'est lancé par ce script, mais il peut être nécessaire pour un effet complet."
    exit 0
}
catch {
    Write-Err ($_ | Out-String)
    exit 1
}
