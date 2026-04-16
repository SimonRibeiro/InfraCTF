<# 
.SYNOPSIS
  Gérer NTLM sans menu interactif (Enable / Disable / Restore).

.DESCRIPTION
  -Action Enable  : Autorise NTLM entrant/sortant (RestrictReceivingNTLMTraffic = 0,
                    RestrictSendingNTLMTraffic  = 0)
  -Action Disable : Bloque NTLM entrant/sortant (RestrictReceivingNTLMTraffic = 2,
                    RestrictSendingNTLMTraffic  = 2)
  -Action Restore : Revient aux valeurs par défaut :
                    - RestrictReceiving/Sending = 0
                    - Supprime ClientAllowedNTLMServers
                    - Supprime LmCompatibilityLevel

  Aucun redémarrage n'est initié par ce script. Selon l'environnement,
  un redémarrage peut être nécessaire pour un effet complet.

.NOTES
  - À exécuter en Administrateur.
  - Compatible Windows PowerShell 5.1 et PowerShell 7+.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Enable','Disable','Restore')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$BaseKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
$LsaKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'

# --- Admin check ---
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Registry helpers ---
function Get-RegDword($Path,$Name,$Default=$null) {
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name }
    catch { return $Default }
}
function Get-RegMulti($Path,$Name) {
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name }
    catch { return @() }
}
function Set-DWord($Path,$Name,$Value) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}
function Set-Multi($Path,$Name,$Value) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -PropertyType MultiString -Value $Value -Force | Out-Null
}

# --- Backup (best effort) ---
function Backup-NTLMRegistry {
    try {
        $ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $dir = Split-Path -Parent $PSCommandPath
        if (-not $dir) { $dir = $env:TEMP }
        $dst = Join-Path $dir "NTLM-backup-$ts.reg"
        & reg.exe export "HKLM\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0" $dst /y | Out-Null
        & reg.exe export "HKLM\SYSTEM\CurrentControlSet\Control\Lsa"        ($dst + ".lsa.reg") /y | Out-Null
        Write-Host "✅ Sauvegardes: $dst et $($dst).lsa.reg"
    } catch {
        Write-Host "⚠️  Sauvegarde registre échouée: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- Mappings for status display ---
$RecvMap = @{
    0 = 'Autoriser tout (incoming)'
    1 = 'Refuser comptes de domaine (incoming)'
    2 = 'Refuser tous (incoming)'
}
$SendMap = @{
    0 = 'Autoriser tout (outgoing)'
    1 = 'Audit uniquement (outgoing)'
    2 = 'Refuser tous (outgoing)'
}
$LmMap = @{
    0 = 'Envoyer LM & NTLM (v1)'
    1 = 'LM & NTLM, NTLMv2 si négocié'
    2 = 'NTLM (v1) uniquement'
    3 = 'NTLMv2 uniquement'
    4 = 'NTLMv2 uniquement, refuser LM'
    5 = 'NTLMv2 uniquement, refuser LM & NTLMv1'
}

function Show-NTLMStatus {
    $recv = Get-RegDword $BaseKey 'RestrictReceivingNTLMTraffic' 0
    $send = Get-RegDword $BaseKey 'RestrictSendingNTLMTraffic'  0
    $lm   = Get-RegDword $LsaKey  'LmCompatibilityLevel' $null
    $ex   = Get-RegMulti $BaseKey 'ClientAllowedNTLMServers'

    $recvDesc = if ($RecvMap.ContainsKey($recv)) { $RecvMap[$recv] } else { "Inconnu ($recv)" }
    $sendDesc = if ($SendMap.ContainsKey($send)) { $SendMap[$send] } else { "Inconnu ($send)" }
    $lmDesc   = if ($lm -ne $null -and $LmMap.ContainsKey($lm)) { $LmMap[$lm] }
                elseif ($lm -ne $null) { "Inconnu ($lm)" } else { "(non défini, valeur par défaut système)" }

    Write-Host ""
    Write-Host "=== STATUT NTLM LOCAL ===" -ForegroundColor Cyan
    Write-Host ("Trafic NTLM entrant  : {0}" -f $recvDesc)
    Write-Host ("Trafic NTLM sortant  : {0}" -f $sendDesc)
    Write-Host ("Compatibilité LM/NTLM: {0}" -f $lmDesc)
    if ($ex -and $ex.Count -gt 0) {
        Write-Host "Exceptions sortantes :" -ForegroundColor Cyan
        $ex | ForEach-Object { Write-Host " - $_" }
    } else {
        Write-Host "Exceptions sortantes : (aucune)"
    }
    $allowed = ($recv -eq 0) -and ($send -ne 2)
    $global  = if ($allowed) { 'NTLM globalement PERMIS' } else { 'NTLM globalement BLOQUÉ (au moins en partie)' }
    $color   = $(if ($allowed) { 'Green' } else { 'Yellow' })
    Write-Host ("Synthèse: {0}" -f $global) -ForegroundColor $color
    Write-Host ""
}

function Enable-NTLM {
    Backup-NTLMRegistry
    Set-DWord $BaseKey 'RestrictReceivingNTLMTraffic' 0
    Set-DWord $BaseKey 'RestrictSendingNTLMTraffic'  0
    Write-Host "✅ NTLM activé (entrant et sortant autorisés)."
}

function Disable-NTLM {
    Backup-NTLMRegistry
    Set-DWord $BaseKey 'RestrictReceivingNTLMTraffic' 2
    Set-DWord $BaseKey 'RestrictSendingNTLMTraffic'  2
    Write-Host "✅ NTLM désactivé (entrant et sortant refusés)."
    Write-Host "ℹ️  Les exceptions sortantes (ClientAllowedNTLMServers) s’appliquent si configurées."
}

function Reset-Defaults {
    Backup-NTLMRegistry
    Set-DWord $BaseKey 'RestrictReceivingNTLMTraffic' 0
    Set-DWord $BaseKey 'RestrictSendingNTLMTraffic'  0
    try { Remove-ItemProperty -Path $BaseKey -Name 'ClientAllowedNTLMServers' -ErrorAction Stop } catch {}
    try { Remove-ItemProperty -Path $LsaKey  -Name 'LmCompatibilityLevel'   -ErrorAction Stop } catch {}
    Write-Host "✅ Valeurs réinitialisées (comportement par défaut du système)."
}

try {
    if (-not (Test-IsAdmin)) { throw "Exécuter ce script en tant qu'Administrateur." }
    Show-NTLMStatus
    switch ($Action) {
        'Enable'  { Enable-NTLM }
        'Disable' { Disable-NTLM }
        'Restore' { Reset-Defaults }
    }
    Write-Host ""
    Show-NTLMStatus
    Write-Host "Note: aucun redémarrage n'est lancé par ce script, mais il peut être nécessaire pour un effet complet." -ForegroundColor Yellow
    exit 0
}
catch {
    Write-Host ("Erreur: {0}" -f ($_.Exception.Message)) -ForegroundColor Red
    exit 1
}
