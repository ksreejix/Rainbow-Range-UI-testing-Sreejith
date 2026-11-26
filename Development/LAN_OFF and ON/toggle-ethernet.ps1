[CmdletBinding()]
param(
    [string]$AdapterName = 'Ethernet',

    [ValidateRange(1, 2147483)]
    [int]$IntervalSeconds = 60,

    [ValidateRange(1, 2147483)]
    [int]$DisconnectSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}

if ([string]::IsNullOrWhiteSpace($AdapterName)) {
    $ethernetAdapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {
        $_.Status -eq 'Up' -and $_.NdisPhysicalMedium -eq 14
    })
    if ($ethernetAdapters.Count -eq 0) {
        throw 'Could not automatically find an active physical Ethernet adapter. Specify -AdapterName manually.'
    }
    if ($ethernetAdapters.Count -gt 1) {
        $adapterNames = ($ethernetAdapters | ForEach-Object { $_.Name }) -join ', '
        throw "Found multiple active Ethernet adapters: $adapterNames. Specify -AdapterName to choose one."
    }

    $AdapterName = $ethernetAdapters[0].Name
    Write-Host "Automatically selected Ethernet adapter: $AdapterName"
}

$adapters = @(Get-NetAdapter -Name $AdapterName -ErrorAction Stop | Where-Object { $_.Name -ceq $AdapterName })
if ($adapters.Count -ne 1) {
    throw "No single network adapter exactly named '$AdapterName' was found. Use Get-NetAdapter to list adapter names."
}

$adapter = $adapters[0]
if ($adapter.Name -match '(?i)wi.?fi|wireless' -or
    $adapter.InterfaceDescription -match '(?i)wi.?fi|wireless' -or
    $adapter.NdisPhysicalMedium -eq 1) {
    throw "'$AdapterName' appears to be a Wi-Fi adapter. This script only targets Ethernet."
}
if ($adapter.Status -ne 'Up') {
    throw "'$AdapterName' must be connected (Status: $($adapter.Status)) before starting."
}

Write-Host "Adapter: $($adapter.Name) ($($adapter.InterfaceDescription))"
Write-Host "Connected duration: $IntervalSeconds seconds; disconnected duration: $DisconnectSeconds seconds."
Write-Host 'Wi-Fi will not be changed. Press Ctrl+C to stop the cycle.'

try {
    while ($true) {
        Write-Host "Keeping '$AdapterName' connected for $IntervalSeconds seconds."
        Start-Sleep -Seconds $IntervalSeconds
        Write-Host "Disconnecting '$AdapterName'."
        try {
            Disable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds $DisconnectSeconds
        }
        finally {
            Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-Host "Reconnected '$AdapterName'."
    }
}
finally {
    $currentAdapter = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ceq $AdapterName }
    if ($null -ne $currentAdapter -and $currentAdapter.Status -ne 'Up') {
        Write-Host "Re-enabling '$AdapterName' before exit..."
        Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction SilentlyContinue
    }
}