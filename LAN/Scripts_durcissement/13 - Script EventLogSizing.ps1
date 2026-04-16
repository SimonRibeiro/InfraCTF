#requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Utilitaires ---
function Convert-BytesToFriendly {
    param([long]$Bytes)
    if ($null -eq $Bytes) { return "-" }
    if ($Bytes -lt 1KB) { return "$Bytes o" }
    elseif ($Bytes -lt 1MB) { "{0:N1} Ko" -f ($Bytes/1KB) }
    elseif ($Bytes -lt 1GB) { "{0:N1} Mo" -f ($Bytes/1MB) }
    else { "{0:N2} Go" -f ($Bytes/1GB) }
}

function Get-LogInfo {
    param([Parameter(Mandatory)][string]$ChannelName)
    $props = & wevtutil gl $ChannelName 2>$null
    if (-not $props) { return $null }

    $maxSize = $null; $file = $null
    foreach ($line in $props) {
        if ($line -match 'maxSize:\s*(\d+)') { $maxSize = [long]$Matches[1] }
        elseif ($line -match 'file:\s*(.+)') { $file = $Matches[1].Trim() }
    }

    $curSize = $null
    if ($file -and (Test-Path -LiteralPath $file)) {
        try { $curSize = (Get-Item -LiteralPath $file).Length } catch { $curSize = $null }
    }

    [PSCustomObject]@{
        Channel = $ChannelName
        File    = $file
        Cur     = $curSize
        Max     = $maxSize
    }
}

function Set-LogMaxSize {
    param(
        [Parameter(Mandatory)][string]$ChannelName,
        [Parameter(Mandatory)][long]$Bytes
    )
    & wevtutil sl $ChannelName /ms:$Bytes 2>&1 | Out-Null
}

# --- Cœur : journaux ciblés ---
$Targets = @(
    @{ Label = "Application";           Channel = "Application"      },
    @{ Label = "Sécurité";              Channel = "Security"         },
    @{ Label = "Installation";          Channel = "Setup"            },
    @{ Label = "Système";               Channel = "System"           },
    @{ Label = "Événements transférés"; Channel = "ForwardedEvents"  }
)

function Refresh-Infos {
    $global:Infos = @()
    foreach ($t in $Targets) {
        $info = Get-LogInfo -ChannelName $t.Channel
        if ($info) {
            $global:Infos += [PSCustomObject]@{
                Label   = $t.Label
                Channel = $t.Channel
                File    = $info.File
                Cur     = $info.Cur
                Max     = $info.Max
            }
        } else {
            $global:Infos += [PSCustomObject]@{
                Label   = $t.Label
                Channel = $t.Channel
                File    = $null
                Cur     = $null
                Max     = $null
            }
        }
    }
}

function Show-Menu {
    Write-Host ""
    Write-Host "========== Taille des journaux d'événements ==========" -ForegroundColor Yellow
    #"{0,3}  {1,-24} {2,12} {3,12}   {4}" -f "#","Journal","Taille","Max","Chemin"
    "{0,3}  {1,-24} {2,12} {3,12}   {4}" -f "#","Journal","Taille","Max",""
    for ($i=0; $i -lt $Infos.Count; $i++) {
        $cur = Convert-BytesToFriendly $Infos[$i].Cur
        $max = Convert-BytesToFriendly $Infos[$i].Max
        "{0,3}  {1,-24} {2,12} {3,12}   {4}" -f ($i+1), $Infos[$i].Label, $cur, $max, $Infos[$i].File
    }
    Write-Host ""
    Write-Host "Choisissez un numéro (1-$($Infos.Count)) pour modifier, 'R' pour rafraîchir, 'Q' pour quitter."
}

function Read-SizeMB {
    param([int]$MinMB = 1, [int]$MaxMB = 16384)  # jusqu'à 16 Go
    while ($true) {
        $s = Read-Host ("Nouvelle taille maximale en Mo")
        #$s = Read-Host ("Nouvelle taille maximale (en Mo, {0}-{1})" -f $MinMB,$MaxMB)
        if ($s -match '^\s*(\d+)\s*$') {
            $mb = [int]$Matches[1]
            if ($mb -ge $MinMB -and $mb -le $MaxMB) { return $mb }
        }
        Write-Warning "Entrez un entier entre $MinMB et $MaxMB."
    }
}

# --- Main loop ---
Refresh-Infos

while ($true) {
    Show-Menu
    $choice = (Read-Host "> Sélection").Trim()

    if ($choice -match '^[Qq]$') { break }
    if ($choice -match '^[Rr]$') { Refresh-Infos; continue }

    if ($choice -notmatch '^\d+$') { Write-Warning "Entrée invalide."; continue }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $Infos.Count) { Write-Warning "Numéro hors plage."; continue }

    $item = $Infos[$idx]
    Write-Host ""
    Write-Host ("Journal: {0} ({1})" -f $item.Label, $item.Channel) -ForegroundColor Cyan
    #Write-Host ("Taille actuelle: {0} | Max: {1}" -f (Convert-BytesToFriendly $item.Cur), (Convert-BytesToFriendly $item.Max))
    $mb = Read-SizeMB
    $bytes = [long]$mb * 1MB

    try {
        Set-LogMaxSize -ChannelName $item.Channel -Bytes $bytes
        Write-Host ("OK: nouvelle taille max = {0}" -f (Convert-BytesToFriendly $bytes)) -ForegroundColor Green
    }
    catch {
        Write-Warning ("ÉCHEC: {0}" -f $_.Exception.Message)
    }

    Refresh-Infos
}
Write-Host "Terminé."
