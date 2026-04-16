<# 
.SYNOPSIS
  Configure Microsoft Defender Controlled Folder Access (CFA) sans toucher aux personnalisations existantes.

.DESCRIPTION
  - Ne modifie pas les applis autorisées ni les dossiers ajoutés précédemment.
  - Permet de basculer en mode Blocage (Enable), Audit (AuditMode) ou Désactivation (Disable).
  - Retourne un état synthétique en fin d'exécution.

.EXAMPLES
  .\Set-CFA.ps1                # Active CFA en mode Blocage (par défaut)
  .\Set-CFA.ps1 -Audit         # Passe CFA en mode Audit
  .\Set-CFA.ps1 -Disable       # Désactive CFA
  .\Set-CFA.ps1 -Enable        # Force explicitement le mode Blocage
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(ParameterSetName='EnableSet')]
    [switch] $Enable,

    [Parameter(ParameterSetName='AuditSet')]
    [switch] $Audit,

    [Parameter(ParameterSetName='DisableSet')]
    [switch] $Disable
)

function Test-Admin {
    $wp = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    return $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 1) Vérification préalables
if (-not (Test-Admin)) {
    Write-Error "Exécutez PowerShell en tant qu'Administrateur."
    exit 1
}

if (-not (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) {
    Write-Error "Cmdlets Microsoft Defender indisponibles. Requis : Windows 10/11 avec Microsoft Defender."
    exit 2
}

# 2) Déterminer le mode demandé (par défaut : Enable)
$targetMode = if ($PSCmdlet.ParameterSetName -eq 'AuditSet') {
    'AuditMode'
} elseif ($PSCmdlet.ParameterSetName -eq 'DisableSet') {
    'Disabled'
} else {
    'Enabled'
}

# 3) Appliquer
try {
    $modeLabel = switch ($targetMode) {
        'Enabled'   { 'Blocage (Enabled)' }
        'AuditMode' { 'Audit (AuditMode)' }
        'Disabled'  { 'Désactivé (Disabled)' }
    }

    if ($PSCmdlet.ShouldProcess("Controlled Folder Access", "Basculer en mode $modeLabel")) {
        Set-MpPreference -EnableControlledFolderAccess $targetMode -ErrorAction Stop
        Write-Host "✅ CFA basculé en mode $modeLabel."
    }
}
catch {
    Write-Error "Échec de la configuration CFA : $($_.Exception.Message)"
    exit 3
}

# 4) Afficher l’état courant (sans toucher aux personnalisations)
$p = Get-MpPreference
$state = switch ($p.EnableControlledFolderAccess) {
    0 { 'Disabled' }
    1 { 'Enabled' }
    2 { 'AuditMode' }
    default { "Inconnu ($($_))" }
}

# NB : les listes renvoient uniquement les éléments *ajoutés manuellement* (pas les dossiers par défaut)
[PSCustomObject]@{
    CFA_State                                   = $state
    AllowedApplications_CustomCount             = ($p.ControlledFolderAccessAllowedApplications | Measure-Object).Count
    ProtectedFolders_CustomCount                = ($p.ControlledFolderAccessProtectedFolders | Measure-Object).Count
} | Format-List

# Codes de sortie
# 0 = OK, 1 = pas admin, 2 = cmdlets absentes, 3 = erreur Set-MpPreference
exit 0
