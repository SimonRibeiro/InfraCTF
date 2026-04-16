<# 
.SYNOPSIS
  Script interactif pour vérifier / désactiver / activer SMBv1 (client/serveur),
  menu: 6=Redémarrer, 7=Quitter. Compatible Windows PowerShell 5.1+.

.NOTES
  - Exécuter en tant qu’Administrateur.
#>

#region Auto-élévation si nécessaire
$currUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host "[i] Relance du script avec élévation..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
#endregion

function Test-FeatureCmdlets {
    return (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) -ne $null
}
function Test-SmbServerCmdlets {
    return ((Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue) -ne $null) -and
           ((Get-Command Set-SmbServerConfiguration -ErrorAction SilentlyContinue) -ne $null)
}

function Get-SMB1Status {
    $status = [ordered]@{
        FeatureFound   = $false
        FeatureState   = $null
        ClientState    = $null
        ServerState    = $null
        SmbServerConf  = $null
        RegistryValue  = $null
        Summary        = $null
        RestartNeeded  = $false
    }

    if (Test-FeatureCmdlets) {
        $features = @("SMB1Protocol","SMB1Protocol-Client","SMB1Protocol-Server")
        try {
            $res = Get-WindowsOptionalFeature -Online -FeatureName $features -ErrorAction Stop
            foreach ($f in $res) {
                switch ($f.FeatureName) {
                    "SMB1Protocol"        { $status.FeatureFound = $true; $status.FeatureState = $f.State }
                    "SMB1Protocol-Client" { $status.ClientState  = $f.State }
                    "SMB1Protocol-Server" { $status.ServerState  = $f.State }
                }
                if ($f.RestartNeeded) { $status.RestartNeeded = $true }
            }
        } catch {}
    }

    if (Test-SmbServerCmdlets) {
        try {
            $smb = Get-SmbServerConfiguration -ErrorAction Stop
            $status.SmbServerConf = [ordered]@{
                EnableSMB1Protocol = $smb.EnableSMB1Protocol
                EnableSMB2Protocol = $smb.EnableSMB2Protocol
            }
        } catch {}
    }

    try {
        $reg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "SMB1" -ErrorAction SilentlyContinue
        if ($null -ne $reg) { $status.RegistryValue = $reg.SMB1 }
    } catch {}

    $enabledHints = @()
    if ($status.FeatureFound) {
        if ($status.FeatureState -eq "Enabled" -or $status.ClientState -eq "Enabled" -or $status.ServerState -eq "Enabled") { $enabledHints += "Feature" }
    }
    if ($status.SmbServerConf -and $status.SmbServerConf.EnableSMB1Protocol) { $enabledHints += "SmbServerConfiguration" }
    if ($status.RegistryValue -eq 1 -or $status.RegistryValue -eq $true) { $enabledHints += "Registry" }

    if ($enabledHints.Count -gt 0) {
        $status.Summary = "SMBv1 semble ACTIVÉ ($($enabledHints -join ', '))."
    } else {
        $status.Summary = "SMBv1 semble DÉSACTIVÉ."
    }

    [pscustomobject]$status
}

function Disable-SMB1 {
    $restartNeeded = $false; $errors = @()

    if (Test-FeatureCmdlets) {
        try {
            Write-Host "[*] Désactivation du composant 'SMB1Protocol'..." -ForegroundColor Cyan
            $res = Disable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -NoRestart -ErrorAction Stop
            if ($res.RestartNeeded) { $restartNeeded = $true }
        } catch { $errors += "Disable-WindowsOptionalFeature: $($_.Exception.Message)" }
    }

    if (Test-SmbServerCmdlets) {
        try {
            Write-Host "[*] Forçage côté serveur SMB : EnableSMB1Protocol = False" -ForegroundColor Cyan
            Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop | Out-Null
        } catch { $errors += "Set-SmbServerConfiguration: $($_.Exception.Message)" }
    }

    try {
        New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "SMB1" -Value 0 -Type DWord -ErrorAction SilentlyContinue
    } catch { $errors += "Registry write (SMB1=0): $($_.Exception.Message)" }

    [pscustomobject]@{ RestartNeeded = $restartNeeded; Errors = $errors }
}

function Enable-SMB1 {
    param([ValidateSet("All","Client","Server")] [string]$Scope = "All")
    $restartNeeded = $false; $errors = @()

    if (Test-FeatureCmdlets) {
        try {
            switch ($Scope) {
                "All"    { Write-Host "[*] Activation de 'SMB1Protocol' (client + serveur)..." -ForegroundColor Cyan; $res = Enable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -All -NoRestart -ErrorAction Stop }
                "Client" { Write-Host "[*] Activation 'SMB1Protocol-Client'..." -ForegroundColor Cyan; $res = Enable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol-Client" -All -NoRestart -ErrorAction Stop }
                "Server" { Write-Host "[*] Activation 'SMB1Protocol-Server'..." -ForegroundColor Cyan; $res = Enable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol-Server" -All -NoRestart -ErrorAction Stop }
            }
            if ($res.RestartNeeded) { $restartNeeded = $true }
        } catch { $errors += "Enable-WindowsOptionalFeature ($Scope): $($_.Exception.Message)" }
    }

    if ( ($Scope -in @("All","Server")) -and (Test-SmbServerCmdlets) ) {
        try {
            Write-Host "[*] Forçage côté serveur SMB : EnableSMB1Protocol = True" -ForegroundColor Cyan
            Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force -ErrorAction Stop | Out-Null
        } catch { $errors += "Set-SmbServerConfiguration: $($_.Exception.Message)" }
    }

    if ($Scope -in @("All","Server")) {
        try {
            New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "SMB1" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        } catch { $errors += "Registry write (SMB1=1): $($_.Exception.Message)" }
    }

    [pscustomobject]@{ RestartNeeded = $restartNeeded; Errors = $errors }
}

function Show-Status {
    $s = Get-SMB1Status
    Write-Host ""
    Write-Host "=== ÉTAT SMBv1 ===" -ForegroundColor Green
    Write-Host ("Résumé        : {0}" -f $s.Summary)
    if ($s.FeatureFound) {
        Write-Host ("Feature       : {0}" -f $s.FeatureState)
        if ($s.ClientState) { Write-Host ("Client        : {0}" -f $s.ClientState) }
        if ($s.ServerState) { Write-Host ("Serveur       : {0}" -f $s.ServerState) }
    } else {
        Write-Host "Feature       : Non détectée (peut avoir été supprimée du système)."
    }
    if ($s.SmbServerConf) { Write-Host ("SmbServerConf : EnableSMB1={0} | EnableSMB2={1}" -f $s.SmbServerConf.EnableSMB1Protocol, $s.SmbServerConf.EnableSMB2Protocol) }
    if ($null -ne $s.RegistryValue) { Write-Host ("Registre SMB1 : {0}" -f $s.RegistryValue) }
    if ($s.RestartNeeded) { Write-Host "[!] Un redémarrage est signalé comme nécessaire." -ForegroundColor Yellow }
    Write-Host ""
}

function Confirm-And-Reboot {
    param([string]$Reason = "Redémarrer pour appliquer certains changements.")
    Write-Host "[?] $Reason" -ForegroundColor Yellow
    $answer = Read-Host "Voulez-vous redémarrer maintenant ? (O/N)"
    if ($answer -match '^(o|oui|y|yes)$') {
        Write-Host "[i] Redémarrage en cours..." -ForegroundColor Cyan
        try { Restart-Computer -Force } catch { Write-Host "[!] Échec du redémarrage: $($_.Exception.Message)" -ForegroundColor Red }
    } else {
        Write-Host "[i] Redémarrage annulé par l'utilisateur." -ForegroundColor DarkYellow
    }
}

function Main-Menu {
    do {
        Show-Status
        Write-Host "Choisissez une action :" -ForegroundColor Yellow
        Write-Host "  1) Vérifier l’état"
        Write-Host "  2) Désactiver SMBv1 (client + serveur)"
        Write-Host "  3) Activer SMBv1 (client + serveur)"
        Write-Host "  4) Activer SMBv1 (client uniquement)"
        Write-Host "  5) Activer SMBv1 (serveur uniquement)"
        Write-Host "  6) Redémarrer l’ordinateur"
        Write-Host "  7) Quitter"
        $choice = Read-Host "Votre choix [1-7]"

        switch ($choice) {
            "1" { Show-Status }
            "2" { 
                $res = Disable-SMB1
                if ($res.Errors.Count -gt 0) {
                    Write-Host "[!] Erreurs :" -ForegroundColor Red
                    $res.Errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
                }
                if ($res.RestartNeeded) { Write-Host "[i] Un redémarrage peut être nécessaire." -ForegroundColor Yellow }
            }
            "3" {
                $res = Enable-SMB1 -Scope All
                if ($res.Errors.Count -gt 0) {
                    Write-Host "[!] Erreurs :" -ForegroundColor Red
                    $res.Errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
                }
                if ($res.RestartNeeded) { Write-Host "[i] Un redémarrage peut être nécessaire." -ForegroundColor Yellow }
            }
            "4" {
                $res = Enable-SMB1 -Scope Client
                if ($res.Errors.Count -gt 0) {
                    Write-Host "[!] Erreurs :" -ForegroundColor Red
                    $res.Errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
                }
                if ($res.RestartNeeded) { Write-Host "[i] Un redémarrage peut être nécessaire." -ForegroundColor Yellow }
            }
            "5" {
                $res = Enable-SMB1 -Scope Server
                if ($res.Errors.Count -gt 0) {
                    Write-Host "[!] Erreurs :" -ForegroundColor Red
                    $res.Errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
                }
                if ($res.RestartNeeded) { Write-Host "[i] Un redémarrage peut être nécessaire." -ForegroundColor Yellow }
            }
            "6" { Confirm-And-Reboot "Vous avez choisi de redémarrer l’ordinateur." }
            "7" { Write-Host "Au revoir." -ForegroundColor Green; return }
            default { Write-Host "Entrée invalide." -ForegroundColor Red }
        }

        if ($choice -in "2","3","4","5") {
            Write-Host ""
            Write-Host "État après action :" -ForegroundColor Green
            Show-Status
        }
    } while ($true)
}

# Lancement du menu
Main-Menu
