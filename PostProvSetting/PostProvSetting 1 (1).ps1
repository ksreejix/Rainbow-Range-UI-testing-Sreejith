# Requires: Run as Administrator
# Purpose: Apply post-provisioning settings in one run:
#   1) Disable blank password remote-use restriction policy
#   2) Set sleep/hibernate to Never
#   3) Disable Windows Update (policy + related services)

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-DwordValue {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [int]$Value
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Invoke-PowerCfgChange {
    param(
        [Parameter(Mandatory = $true)] [string[]]$Arguments,
        [Parameter(Mandatory = $true)] [string]$FailureMessage
    )

    & powercfg @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

function Set-BlankPasswordPolicyDisabled {
    param([switch]$Force)

    $policyName = 'Accounts: Limit local account use of blank passwords to console logon only'
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $valueName = 'LimitBlankPasswordUse'
    $targetValue = 0  # 0 = Disabled, 1 = Enabled

    $currentValue = $null
    try {
        $currentValue = (Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop).$valueName
    } catch {
        Write-Host "[$policyName] current value not found. It will be created." -ForegroundColor Yellow
    }

    if ($currentValue -eq $targetValue -and -not $Force) {
        Write-Host "[$policyName] is already Disabled (LimitBlankPasswordUse=$targetValue)." -ForegroundColor Green
        return
    }

    New-ItemProperty -Path $regPath -Name $valueName -PropertyType DWord -Value $targetValue -Force | Out-Null
    $updatedValue = (Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop).$valueName

    if ($updatedValue -ne $targetValue) {
        throw "Failed to set $valueName to $targetValue. Current value: $updatedValue"
    }

    Write-Host "[$policyName] set to Disabled successfully." -ForegroundColor Green
    Write-Host "Registry: $regPath\$valueName = $updatedValue"
}

function Set-SleepToNever {
    Write-Host 'Applying sleep, hibernate, and display settings (Never) for active power plan...' -ForegroundColor Cyan

    Invoke-PowerCfgChange -Arguments @('/change', 'standby-timeout-ac', '0') -FailureMessage 'Failed to set standby-timeout-ac.'
    Invoke-PowerCfgChange -Arguments @('/change', 'standby-timeout-dc', '0') -FailureMessage 'Failed to set standby-timeout-dc.'
    Invoke-PowerCfgChange -Arguments @('/change', 'hibernate-timeout-ac', '0') -FailureMessage 'Failed to set hibernate-timeout-ac.'
    Invoke-PowerCfgChange -Arguments @('/change', 'hibernate-timeout-dc', '0') -FailureMessage 'Failed to set hibernate-timeout-dc.'
    Invoke-PowerCfgChange -Arguments @('/change', 'monitor-timeout-ac', '0') -FailureMessage 'Failed to set monitor-timeout-ac.'
    Invoke-PowerCfgChange -Arguments @('/change', 'monitor-timeout-dc', '0') -FailureMessage 'Failed to set monitor-timeout-dc.'

    Write-Host 'Sleep/Hibernate/Display timeouts set to Never successfully.' -ForegroundColor Green
}

function Disable-WindowsUpdate {
    Write-Host 'Disabling Windows Update policies...' -ForegroundColor Cyan

    $wuPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    Set-DwordValue -Path $wuPolicyPath -Name 'NoAutoUpdate' -Value 1
    Set-DwordValue -Path $wuPolicyPath -Name 'AUOptions' -Value 1

    Write-Host 'Windows Update policy values set.' -ForegroundColor Green

    $services = @(
        'wuauserv',
        'UsoSvc',
        'WaaSMedicSvc'
    )

    foreach ($serviceName in $services) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop

            if ($service.Status -ne 'Stopped') {
                Write-Host "Stopping service: $serviceName" -ForegroundColor Cyan
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
            }

            Write-Host "Disabling service startup: $serviceName" -ForegroundColor Cyan
            Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
            Write-Host "Service disabled: $serviceName" -ForegroundColor Green
        } catch {
            Write-Warning "Could not fully disable service $serviceName. Details: $($_.Exception.Message)"
        }
    }

    Write-Host 'Windows Update disable operation completed.' -ForegroundColor Green
    Write-Host 'Note: Major Windows feature updates may re-enable update components.' -ForegroundColor Yellow
}

function Enable-RDP {
    Write-Host 'Enabling Remote Desktop...' -ForegroundColor Cyan

    $rdpRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    Set-DwordValue -Path $rdpRegPath -Name 'fDenyTSConnections' -Value 0

    try {
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop | Out-Null
        Write-Host 'Remote Desktop firewall rules enabled.' -ForegroundColor Green
    } catch {
        Write-Warning "Could not enable Remote Desktop firewall rules. Details: $($_.Exception.Message)"
    }

    Write-Host 'Remote Desktop enabled.' -ForegroundColor Green

    # Refresh UI by closing and reopening Remote Desktop settings
    Write-Host 'Refreshing Remote Desktop settings UI...' -ForegroundColor Cyan
    try {
        Stop-Process -Name SystemPropertiesRemote -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Start-Process 'ms-settings:remotedesktop'
        Write-Host 'Remote Desktop settings reopened for UI refresh.' -ForegroundColor Green
    } catch {
        Write-Warning "Could not refresh Remote Desktop UI. Details: $($_.Exception.Message)"
    }
}

function Disable-NonAdminUsers {
    Write-Host 'Disabling all non-administrator user accounts...' -ForegroundColor Cyan

    try {
        $adminAccount = Get-LocalUser -Name 'Administrator' -ErrorAction Stop
        $allUsers = Get-LocalUser -ErrorAction Stop | Where-Object { $_.Name -ne 'Administrator' }

        if ($allUsers.Count -eq 0) {
            Write-Host 'No non-administrator user accounts found.' -ForegroundColor Green
            return
        }

        foreach ($user in $allUsers) {
            try {
                Disable-LocalUser -Name $user.Name -ErrorAction Stop
                Write-Host "User disabled: $($user.Name)" -ForegroundColor Green
            } catch {
                Write-Warning "Could not disable user $($user.Name). Details: $($_.Exception.Message)"
            }
        }

        Write-Host "All non-administrator user accounts disabled successfully." -ForegroundColor Green
    } catch {
        Write-Warning "Error enumerating or disabling users. Details: $($_.Exception.Message)"
    }
}

if (-not (Test-IsAdministrator)) {
    Write-Error 'Run this script in an elevated PowerShell session (Run as Administrator).'
    exit 1
}

Set-BlankPasswordPolicyDisabled -Force:$Force
Set-SleepToNever
Disable-WindowsUpdate
Enable-RDP
Disable-NonAdminUsers

Write-Host ''
Write-Host 'All post-provisioning settings applied.' -ForegroundColor Green
Write-Host 'Tip: Run gpupdate /force if you want policy refresh immediately.'
