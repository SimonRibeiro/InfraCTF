# Toggle-UAC-Compat.ps1
# Compatible Windows PowerShell 5.1+
# Paramètres:
#   -SetMax  : force le passage au niveau maximum
#   -Restore : restaure l'état sauvegardé
#   -Toggle  : par défaut : si pas au max => sauvegarde + max ; si déjà au max => restauration
#   -Reboot  : redémarre automatiquement après changement

[CmdletBinding()]
param(
    [switch]$SetMax,
    [switch]$Restore,
    [switch]$Toggle = $true,
    [switch]$Reboot
)

# --- Constantes ---
$RegPath   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$StateDir  = Join-Path $env:ProgramData 'UACToggle'
$StateFile = Join-Path $StateDir 'uac_state.json'
$Keys      = @('EnableLUA','ConsentPromptBehaviorAdmin','ConsentPromptBehaviorUser','PromptOnSecureDesktop')

# --- Élévation Admin (compatible 5.1) ---
function Ensure-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Relance du script avec privilèges administrateur..."
        $argList = @('-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
        foreach ($kvp in $MyInvocation.BoundParameters.GetEnumerator()) {
            if ($kvp.Value -is [System.Management.Automation.SwitchParameter]) {
                if ($kvp.Value.IsPresent) { $argList += "-$($kvp.Key)" }
            } else {
                $argList += "-$($kvp.Key)"
                $argList += "`"$($kvp.Value)`""
            }
        }
        Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs | Out-Null
        exit
    }
}
Ensure-Admin

# --- Utilitaires ---
function Get-UACState {
    $obj = [ordered]@{}
    $props = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    foreach ($k in $Keys) {
        $val = $null
        if ($props) { $val = $props.$k }
        if ($null -eq $val) { $obj[$k] = -1 } else { $obj[$k] = [int]$val }
    }
    return [PSCustomObject]$obj
}

function Set-UACState([hashtable]$state) {
    foreach ($kvp in $state.GetEnumerator()) {
        New-ItemProperty -Path $RegPath -Name $kvp.Key -PropertyType DWord -Value ([int]$kvp.Value) -Force | Out-Null
    }
}

# Niveau maximum ("Toujours m’avertir")
$MaxState = @{
    EnableLUA                  = 1
    ConsentPromptBehaviorAdmin = 2
    ConsentPromptBehaviorUser  = 1
    PromptOnSecureDesktop      = 1
}

function Test-IsMax {
    $cur = Get-UACState
    foreach ($k in $MaxState.Keys) {
        if ($cur.$k -ne $MaxState[$k]) { return $false }
    }
    return $true
}

function Save-CurrentState {
    $cur = Get-UACState | ConvertTo-Json -Depth 3
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $cur | Set-Content -Path $StateFile -Encoding UTF8
}

function Load-SavedState {
    if (-not (Test-Path $StateFile)) { throw "Aucun état sauvegardé trouvé : $StateFile" }
    $json = Get-Content $StateFile -Encoding UTF8 | ConvertFrom-Json
    $ht = @{}
    foreach ($p in $json.PSObject.Properties) { $ht[$p.Name] = [int]$p.Value }
    return $ht
}

function Apply-And-MaybeReboot([string]$action) {
    Write-Host $action
    Write-Host "⚠️ Une déconnexion ou un redémarrage peut être nécessaire pour appliquer totalement les changements UAC."
    if ($Reboot) {
        Write-Host "Redémarrage en cours..."
        Restart-Computer -Force
    } else {
        Write-Host "Astuce : ajoutez -Reboot pour redémarrer automatiquement."
    }
}

# --- Logique principale ---
try {
    if ($SetMax) { $Toggle = $false }
    if ($Restore) { $Toggle = $false }

    if ($SetMax) {
        Save-CurrentState
        Set-UACState -state $MaxState
        Apply-And-MaybeReboot "UAC réglé au niveau maximum, état précédent sauvegardé dans: $StateFile"
        return
    }

    if ($Restore) {
        $saved = Load-SavedState
        Set-UACState -state $saved
        Apply-And-MaybeReboot "UAC restauré à l’état initial depuis: $StateFile"
        return
    }

    # Mode Toggle (par défaut)
    if (Test-IsMax) {
        if (Test-Path $StateFile) {
            $saved = Load-SavedState
            Set-UACState -state $saved
            Apply-And-MaybeReboot "UAC actuellement au niveau maximum → restauration de l’état initial."
        } else {
            Write-Host "UAC déjà au niveau maximum, mais aucun état sauvegardé n’a été trouvé."
            Write-Host "Exécutez d’abord -SetMax pour créer la sauvegarde, puis -Restore au besoin."
        }
    } else {
        Save-CurrentState
        Set-UACState -state $MaxState
        Apply-And-MaybeReboot "UAC passé de l’état actuel au niveau maximum. Sauvegarde créée dans: $StateFile"
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
