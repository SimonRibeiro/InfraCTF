[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('Enable','Disable','Restore','Status')]
    [string]$Action = 'Status'
)

# Registry path and value name
$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$ValueName = 'AutoDetect'

function Get-ProxyAutoDetect {
    try {
        $exists = $false
        $value = $null
        try {
            $value = Get-ItemPropertyValue -Path $RegPath -Name $ValueName -ErrorAction Stop
            $exists = $true
        } catch {
            $exists = $false
            $value = $null
        }
        [pscustomobject]@{
            Exists = $exists
            Value  = $value
        }
    } catch {
        Write-Error $_
        return $null
    }
}

function Set-ProxyAutoDetect {
    param(
        [Parameter(Mandatory=$true)]
        [bool]$Enable
    )
    try {
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force | Out-Null
        }
        $desired = if ($Enable) { 1 } else { 0 }
        New-ItemProperty -Path $RegPath -Name $ValueName -PropertyType DWord -Value $desired -Force | Out-Null
        return $true
    } catch {
        Write-Error $_
        return $false
    }
}

function Restore-ProxyAutoDetect {
    try {
        if (Test-Path $RegPath) {
            Remove-ItemProperty -Path $RegPath -Name $ValueName -ErrorAction SilentlyContinue
        }
        return $true
    } catch {
        Write-Error $_
        return $false
    }
}

function Show-Status {
    $s = Get-ProxyAutoDetect
    if ($null -eq $s) { return 2 }
    if (-not $s.Exists) {
        Write-Host "Status: AutoDetect value is ABSENT (Windows default behavior)" -ForegroundColor Yellow
    } else {
        $meaning = if ($s.Value -eq 1) { 'ENABLED' } elseif ($s.Value -eq 0) { 'DISABLED' } else { "Unknown ($($s.Value))" }
        Write-Host "Status: AutoDetect is $meaning (raw: $($s.Value))" -ForegroundColor Cyan
    }
    return 0
}

switch ($Action) {
    'Enable'  { if (Set-ProxyAutoDetect -Enable:$true)  { exit (Show-Status) } else { exit 1 } }
    'Disable' { if (Set-ProxyAutoDetect -Enable:$false) { exit (Show-Status) } else { exit 1 } }
    'Restore' { if (Restore-ProxyAutoDetect)            { exit (Show-Status) } else { exit 1 } }
    'Status'  { exit (Show-Status) }
    default   { Write-Host "Unknown action: $Action" -ForegroundColor Red; exit 1 }
}
