# Kerberos-Armoring-Assistant.ps1
# Interactif : activer/forcer FAST côté client, config KDC côté DC, sauvegarde & restauration.

$ErrorActionPreference = 'Stop'

# --- Constantes & chemins ---
$clientReg = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters'
$kdcReg    = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\KDC\Parameters'
$backupDir = Join-Path $env:ProgramData 'KerberosArmoring'
$backupFile= Join-Path $backupDir 'backup.json'

function Ensure-Key($path) { if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null } }

function Get-RegValue($path,$name) {
  try { (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name } catch { $null }
}

function Set-Dword($path,$name,$val) {
  Ensure-Key $path
  New-ItemProperty -Path $path -Name $name -PropertyType DWord -Value $val -Force | Out-Null
}

function Remove-IfExists($path,$name) {
  try { Remove-ItemProperty -Path $path -Name $name -Force -ErrorAction Stop } catch { }
}

function Is-DC {
  # Heuristic: présence du service KDC et du rôle AD DS
  $svc = Get-Service -Name kdc -ErrorAction SilentlyContinue
  $ad = Get-Service -Name NTDS -ErrorAction SilentlyContinue
  return ($svc -and $ad -and $svc.Status -ne $null)
}

function Save-Backup {
  Ensure-Key $clientReg; Ensure-Key $kdcReg
  $obj = [ordered]@{
    Timestamp = (Get-Date).ToString("s")
    Machine   = $env:COMPUTERNAME
    Client    = @{
      Path = $clientReg
      EnableCbacAndArmor = Get-RegValue $clientReg 'EnableCbacAndArmor'
      RequireFast        = Get-RegValue $clientReg 'RequireFast'
    }
    KDC       = @{
      Path = $kdcReg
      EnableCbacAndArmor = Get-RegValue $kdcReg 'EnableCbacAndArmor'
      RequestCompoundId  = Get-RegValue $kdcReg 'RequestCompoundId'
    }
  }
  if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory | Out-Null }
  $obj | ConvertTo-Json | Set-Content -Path $backupFile -Encoding UTF8
  Write-Host "Sauvegarde enregistrée : $backupFile"
}

function Restore-Backup {
  if (-not (Test-Path $backupFile)) { Write-Warning "Aucune sauvegarde trouvée ($backupFile)."; return }
  $obj = Get-Content $backupFile -Raw | ConvertFrom-Json
  # Client
  if ($null -ne $obj.Client.EnableCbacAndArmor) { Set-Dword $clientReg 'EnableCbacAndArmor' $obj.Client.EnableCbacAndArmor }
  else { Remove-IfExists $clientReg 'EnableCbacAndArmor' }
  if ($null -ne $obj.Client.RequireFast) { Set-Dword $clientReg 'RequireFast' $obj.Client.RequireFast }
  else { Remove-IfExists $clientReg 'RequireFast' }
  # KDC
  if ($null -ne $obj.KDC.EnableCbacAndArmor) { Set-Dword $kdcReg 'EnableCbacAndArmor' $obj.KDC.EnableCbacAndArmor }
  else { Remove-IfExists $kdcReg 'EnableCbacAndArmor' }
  if ($null -ne $obj.KDC.RequestCompoundId) { Set-Dword $kdcReg 'RequestCompoundId' $obj.KDC.RequestCompoundId }
  else { Remove-IfExists $kdcReg 'RequestCompoundId' }
  Write-Host "Restauration terminée depuis la sauvegarde."
}

function Show-Current {
  Write-Host "`n--- Etat actuel ---"
  Write-Host "Client: $clientReg"
  "{0,-28} {1}" -f "EnableCbacAndArmor:", (Get-RegValue $clientReg 'EnableCbacAndArmor')
  "{0,-28} {1}" -f "RequireFast:",        (Get-RegValue $clientReg 'RequireFast')
  if (Is-DC) {
    Write-Host "`nKDC (DC): $kdcReg"
    "{0,-28} {1}" -f "EnableCbacAndArmor:", (Get-RegValue $kdcReg 'EnableCbacAndArmor')
    "{0,-28} {1}" -f "RequestCompoundId:",  (Get-RegValue $kdcReg 'RequestCompoundId')
  }
  Write-Host "--------------------`n"
}

function Menu-Client {
  while ($true) {
    Show-Current
    Write-Host "CLIENT — Kerberos Armoring / Claims"
    Write-Host "[1] Activer le support client (EnableCbacAndArmor = 1)"
    Write-Host "[2] Exiger FAST (RequireFast = 1)  ⚠️ échoue si le domaine ne supporte pas l'armoring"
    Write-Host "[3] Activer + Exiger (1 & 2)"
    Write-Host "[4] Revenir au défaut Windows (supprimer valeurs client)"
    Write-Host "[B] Retour"
    $c = Read-Host "Choix"
    switch ($c.ToUpper()) {
      '1' { Set-Dword $clientReg 'EnableCbacAndArmor' 1; Write-Host "OK : client support activé." }
      '2' { Set-Dword $clientReg 'RequireFast' 1; Write-Host "OK : client exige FAST." }
      '3' { Set-Dword $clientReg 'EnableCbacAndArmor' 1; Set-Dword $clientReg 'RequireFast' 1; Write-Host "OK : support + exigence." }
      '4' { Remove-IfExists $clientReg 'EnableCbacAndArmor'; Remove-IfExists $clientReg 'RequireFast'; Write-Host "OK : valeurs client supprimées (Not Configured)." }
      'B' { return }
      default { }
    }
  }
}

function Menu-KDC {
  if (-not (Is-DC)) { Write-Warning "Cette machine ne semble pas être un contrôleur de domaine."; return }
  while ($true) {
    Show-Current
    Write-Host "KDC (DC) — Modes Kerberos Armoring"
    Write-Host "[1] Not supported (0)   – désactive l’armoring"
    Write-Host "[2] Supported (1)       – recommandé pour phase de déploiement"
    Write-Host "[3] Always provide claims (2)  – DFL 2012+ requis"
    Write-Host "[4] Fail unarmored (3)  – DFL 2012+ et clients FAST requis"
    Write-Host "[5] Demander l’auth. composée (RequestCompoundId = 1)"
    Write-Host "[6] Supprimer valeurs KDC (défaut Windows / Not Configured)"
    Write-Host "[B] Retour"
    $c = Read-Host "Choix"
    switch ($c.ToUpper()) {
      '1' { Set-Dword $kdcReg 'EnableCbacAndArmor' 0; Write-Host "KDC : Not supported." }
      '2' { Set-Dword $kdcReg 'EnableCbacAndArmor' 1; Write-Host "KDC : Supported." }
      '3' { Set-Dword $kdcReg 'EnableCbacAndArmor' 2; Write-Host "KDC : Always provide claims." }
      '4' { Set-Dword $kdcReg 'EnableCbacAndArmor' 3; Write-Host "KDC : Fail unarmored authentication requests." }
      '5' { Set-Dword $kdcReg 'RequestCompoundId' 1; Write-Host "KDC : RequestCompoundId = 1." }
      '6' { Remove-IfExists $kdcReg 'EnableCbacAndArmor'; Remove-IfExists $kdcReg 'RequestCompoundId'; Write-Host "KDC : valeurs supprimées (Not Configured)." }
      'B' { return }
      default { }
    }
  }
}

function Main-Menu {
  Write-Host "=== Kerberos Armoring Assistant ===`n"  -ForegroundColor Cyan
  Write-Host "Cette opération modifie des clés sous:" -ForegroundColor Red
  Write-Host "  CLIENT : $clientReg  (EnableCbacAndArmor, RequireFast)"
  Write-Host "  KDC    : $kdcReg     (EnableCbacAndArmor, RequestCompoundId)`n"
  Write-Host "Une sauvegarde sera créée avant tout changement."
  Write-Host ""

  while ($true) {
    Write-Host "[S] Sauvegarder configuration actuelle"
    Write-Host "[C] Configurer côté CLIENT"
    Write-Host "[D] Configurer côté KDC (sur DC uniquement)"
    Write-Host "[R] Restaurer depuis sauvegarde"
    Write-Host "[W] Rétablir défauts Windows (supprimer toutes les valeurs)"
    Write-Host "[Q] Quitter"
    $x = Read-Host "Choix"
    switch ($x.ToUpper()) {
      'S' { Save-Backup }
      'C' { Save-Backup; Menu-Client }
      'D' { Save-Backup; Menu-KDC }
      'R' { Restore-Backup }
      'W' {
        Save-Backup
        Remove-IfExists $clientReg 'EnableCbacAndArmor'
        Remove-IfExists $clientReg 'RequireFast'
        Remove-IfExists $kdcReg    'EnableCbacAndArmor'
        Remove-IfExists $kdcReg    'RequestCompoundId'
        Write-Host "OK : valeurs supprimées (retour à Not Configured)."
      }
      'Q' { return }
      default { }
    }
  }
}

# Démarrage
try { Main-Menu } catch { Write-Error $_ }
