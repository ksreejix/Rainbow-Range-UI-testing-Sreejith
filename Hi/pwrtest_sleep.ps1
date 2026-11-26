#==============================================================================
# Script Name:       pwrtest_sleep.ps1
# Description:       Drives S3/S4 sleep transitions using pwrtest.exe. The
#                    system enters the selected sleep state and resumes on
#                    the configured wake source.
# Original Author:   Jayaprakash.BS
# Date:              August 20, 2026
# Version:           1.0
#==============================================================================

<#
.SYNOPSIS
  Runs pwrtest.exe S3 (sleep) cycles.

.DESCRIPTION
  Wrapper around:
    pwrtest /sleep /c:<Cycles> /d:<DelaySec> /p:<SleepSec> /s:3 /w:<WakeSource>

  Supported wake sources (-WakeSource):
    rtc          Wake using RTC timer              [default]
    powerbutton  Wake using power button
    bt           Wake using Bluetooth
    keyboard     Wake using keyboard
    mouse        Wake using mouse
    lan          Wake using LAN / Wake-on-LAN
    wifi         Wake using Wi-Fi network
    usb          Wake using USB device
    lid          Wake using laptop lid open
    ac           Wake using AC adapter event
    unknown      Generic / unknown wake source

.PARAMETER Cycles
  Number of sleep/wake cycles. Default: 1.

.PARAMETER DelaySec
  Delay in seconds before each sleep transition. Default: 10.

.PARAMETER SleepSec
  AUTO-WAKE (SleepSec > 0): how long the machine stays in S3, in seconds
    (maps to pwrtest /p). Uses pwrtest.exe.
  NO-WAKE   (SleepSec = 0): enter S3 once with no wake timer and wait for an
    EXTERNAL wake source (power button, keyboard, hotplug, LAN, PDU, etc.).
    Uses the Win32 SetSuspendState API instead of pwrtest.exe. -Cycles and
    -WakeSource are ignored in this mode.
  Default: 0 (NO-WAKE).

.PARAMETER WakeSource
  Wake source passed to pwrtest /w:<value>. Default: rtc.
  Valid values: rtc, powerbutton, bt, keyboard, mouse, lan, wifi, usb, lid, ac, unknown.

.PARAMETER PwrtestPath
  Optional full path to pwrtest.exe. When omitted, auto-resolves: checks PATH
  first, then searches Windows Kits 10 Tools for the current machine
  architecture (x64 / x86 / arm64), picking the latest SDK version found.

.PARAMETER LogDirectory
  Optional output directory for pwrtest.log / pwrtest.xml. When omitted,
  resolves to the active RBR session's
  Results\Session_*\Pwrtest_S3Sleep\ folder via
  Get-RBRCollectorOutputPath. Falls back to a local result_<timestamp>
  folder when no RBR session is active.

.EXAMPLE
  .\pwrtest_sleep.ps1
  .\pwrtest_sleep.ps1 -Cycles 1 -DelaySec 10 -SleepSec 30
  .\pwrtest_sleep.ps1 -Cycles 25 -DelaySec 30 -SleepSec 30 -WakeSource rtc
  .\pwrtest_sleep.ps1 -Cycles 1 -DelaySec 10 -SleepSec 30 -WakeSource powerbutton
#>

param(
    [Parameter(Mandatory=$false)][int]$Cycles     = 1,
    [Parameter(Mandatory=$false)][int]$DelaySec   = 10,
    [Parameter(Mandatory=$false)][int]$SleepSec   = 0,
    [Parameter(Mandatory=$false)]
    [ValidateSet('rtc','powerbutton','bt','keyboard','mouse','lan','wifi','usb','lid','ac','unknown')]
    [string]$WakeSource   = 'rtc',
    [Parameter(Mandatory=$false)][string]$PwrtestPath,
    [Parameter(Mandatory=$false)][string]$LogDirectory,
    [Parameter(Mandatory=$false)]
    [ValidateSet(3, 4)]
    [int]$SleepState = 4
)

$ErrorActionPreference = 'Stop'

# Import centralized logging when available. Keep the standalone script runnable
# in Downloads or another folder where the RBR helper module is not deployed.
$loggerPath = Join-Path $PSScriptRoot '..\helper\print-logger.psm1'
if (Test-Path -LiteralPath $loggerPath) {
    Import-Module $loggerPath -Force
} else {
    function Write-LogEntry {
        param([string]$Module, [string]$Type, [string]$Message)
        Write-Host ('[{0:yyyy-MM-dd HH:mm:ss}][{1}][{2}]{3}' -f (Get-Date), $Module, $Type, $Message)
    }
}

if ($SleepSec -ne 0 -and -not $PwrtestPath) {
    # 1. Try PATH first
    $cmd = Get-Command pwrtest.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        $PwrtestPath = $cmd.Source
    } else {
        # 2. Detect architecture and search Windows Kits installations
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
            'AMD64' { 'x64'   }
            'x86'   { 'x86'   }
            'ARM64' { 'arm64' }
            default { 'x64'   }
        }
        $kitRoots = @(
            "${env:ProgramFiles(x86)}\Windows Kits\10\Tools"
            "$env:ProgramFiles\Windows Kits\10\Tools"
        )
        foreach ($root in $kitRoots) {
            if (-not (Test-Path $root)) { continue }
            $found = Get-ChildItem -Path $root -Filter 'pwrtest.exe' -Recurse -ErrorAction SilentlyContinue |
                     Where-Object { $_.DirectoryName -match "\\$arch$" } |
                     Sort-Object FullName -Descending |
                     Select-Object -First 1
            if ($found) { $PwrtestPath = $found.FullName; break }
        }
        if (-not $PwrtestPath) {
            $errMsg = "pwrtest.exe not found for arch '$arch'. " +
                  "Install the Windows HLK or pass -PwrtestPath. " +
                  "Expected: C:\Program Files (x86)\Windows Kits\10\Tools\<version>\$arch\pwrtest.exe"
Write-LogEntry -Module TEST -Type ERROR -Message "[PWRTEST] $errMsg"
            throw $errMsg
        }
    }
}
if ($SleepSec -ne 0) {
    Write-LogEntry -Module TEST -Type INFO -Message "[PWRTEST] PwrtestPath  : $PwrtestPath"
}
# Resolve output directory: explicit -LogDirectory > active RBR session > local fallback
if (-not $LogDirectory) {
    $sessionModule = Join-Path $PSScriptRoot '..\Engine\RBR.SessionInfo\RBR.SessionInfo.psd1'
    if (Test-Path -LiteralPath $sessionModule) {
        try {
            Import-Module $sessionModule -Force -ErrorAction Stop
            $LogDirectory = Get-RBRCollectorOutputPath -Collector 'Pwrtest_S3Sleep'
        } catch {
Write-LogEntry -Module TEST -Type WARNING -Message "[PWRTEST] RBR.SessionInfo unavailable: $($_.Exception.Message)"
        }
    }
    if (-not $LogDirectory) {
        $LogDirectory = Join-Path $PSScriptRoot ('result_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
}
if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}
$LogDirectory = (Resolve-Path -LiteralPath $LogDirectory).Path

# === NO-WAKE MODE (SleepSec = 0): enter S3 and wait on an EXTERNAL wake ========
# Does NOT use pwrtest.exe. Enters Sleep via the Win32 SetSuspendState API and
# blocks until an external trigger (power button, keyboard, hotplug, PDU, LAN,
# etc.) wakes the platform. -Cycles and -WakeSource are ignored in this mode.
if ($SleepSec -eq 0) {
    Add-Type -AssemblyName System.Windows.Forms

    Write-LogEntry -Module TEST -Type INFO -Message "[PWRTEST] LogDirectory : $LogDirectory"
    Write-LogEntry -Module TEST -Type INFO -Message "[PWRTEST] Mode         : No-wake (external wake required; -Cycles/-WakeSource ignored)"
    Write-LogEntry -Module TEST -Type INFO -Message "[PWRTEST] DelaySec     : $DelaySec"

    $marker = Join-Path $LogDirectory 'sleep_enter_marker.txt'
    @(
        "SleepRequestedUTC : $((Get-Date).ToUniversalTime().ToString('o'))"
        "Host              : $env:COMPUTERNAME"
        "User              : $env:USERNAME"
        "Mode              : No-wake (external trigger required)"
        "DelaySec          : $DelaySec"
        "Comment           : RBR enter-only S3 via SetSuspendState"
    ) | Set-Content -Path $marker -Encoding UTF8

    if ($DelaySec -gt 0) {
        Write-LogEntry -Module TEST -Type INFO -Message "[PWRTEST] Pre-sleep delay : ${DelaySec}s"
        Start-Sleep -Seconds $DelaySec
    }

    Write-LogEntry -Module TEST -Type INFO -Message "[PWRTEST] Issuing : [Application]::SetSuspendState(Suspend, force=true, disableWakeEvent=false)"
    $entered = [System.Windows.Forms.Application]::SetSuspendState(
        [System.Windows.Forms.PowerState]::Suspend, $true, $false)

    if (-not $entered) {
        "SuspendVetoed     : SetSuspendState returned FALSE" | Add-Content -Path $marker -Encoding UTF8
        Write-LogEntry -Module TEST -Type ERROR -Message "[PWRTEST] S3 not entered: SetSuspendState returned FALSE (suspend vetoed). Check powercfg /a and powercfg /requests"
        exit 1
    }

    # --- Machine sleeps here; process resumes transparently on external wake ---
    $wakeUTC = (Get-Date).ToUniversalTime().ToString('o')
    "WakeUTC           : $wakeUTC" | Add-Content -Path $marker -Encoding UTF8
    Write-LogEntry -Module TEST -Type INFO -Message "[PWRTEST] S3 wake confirmed : $wakeUTC"

    # Wake can be a genuine resume OR the backend force-recovering a SUT it
    # already gave up on (PDU power-cycle / its own watchdog timeout). Ask
    # the backend after the fact -- SetSuspendState blocks, so this is the
    # only point where we can check.
    $recoverySignal = [pscustomobject]@{ IsTimeout = $false; IsAbort = $false; IsRecovery = $false; IsPaused = $false; Note = $null }
    try {
        Import-Module "$PSScriptRoot\..\modules\RBR.Recovery.psm1" -Force -DisableNameChecking -ErrorAction Stop
        $recoverySignal = Test-RBRBackendRecoverySignal
    } catch {
        Write-LogEntry -Module TEST -Type WARNING -Message ("[PWRTEST] Backend recovery-status check unavailable: {0}" -f $_.Exception.Message)
    }
    # Only a backend-reported timeout (exit 97) or operator abort (exit 96) halts the whole session (mirrors
    # the resume path's Complete-RBRRecoveryTimeout trigger). A PDU recovery with
    # no timeout is a per-task note only (exit 98) -- the session keeps going.
    if ($recoverySignal.IsTimeout) {
        Write-LogEntry -Module TEST -Type ERROR -Message ("[PWRTEST] S3 did not resume normally (backend timeout): {0}" -f $recoverySignal.Note)
        exit 97
    }
    if ($recoverySignal.IsAbort) {
        Write-LogEntry -Module TEST -Type ERROR -Message ("[PWRTEST] Backend reported operator abort: {0}" -f $recoverySignal.Note)
        exit 96
    }
    if ($recoverySignal.IsRecovery) {
        Write-LogEntry -Module TEST -Type ERROR -Message ("[PWRTEST] S3 did not resume normally (backend recovery): {0}" -f $recoverySignal.Note)
        exit 98
    }
    if ($recoverySignal.IsPaused) { Request-RBREnginePause }
    exit 0
}

$pwrArgs = @('/sleep', "/c:$Cycles", "/d:$DelaySec", "/p:$SleepSec", "/s:$SleepState", "/w:$WakeSource")

Write-LogEntry -Module TEST -Type INFO -Message "[PWRTEST] LogDirectory : $LogDirectory"
Write-LogEntry -Module TEST -Type INFO -Message "[PWRTEST] WakeSource   : $WakeSource"
Write-LogEntry -Module TEST -Type INFO -Message "[PWRTEST] Executing    : `"$PwrtestPath`" $($pwrArgs -join ' ')"
Push-Location -LiteralPath $LogDirectory
$launchErr = $null
try {
    & $PwrtestPath @pwrArgs
    $code = $LASTEXITCODE
} catch {
    $launchErr = $_
    Write-LogEntry -Module TEST -Type ERROR -Message ("[PWRTEST] pwrtest.exe failed to launch ({0}): {1}" -f $PwrtestPath, $_.Exception.Message)
} finally {
    Pop-Location
}
if ($launchErr) { throw $launchErr }
if ($code -eq 0) {
    Write-LogEntry -Module TEST -Type RESULT -Message ("[PWRTEST] pwrtest.exe exited 0")

    # pwrtest.exe exiting 0 does not distinguish a genuine wake from the backend
    # force-recovering a SUT it already gave up on (PDU power-cycle / its own
    # watchdog timeout). Ask the backend after the fact -- pwrtest.exe blocks for
    # the whole cycle, so this is the only point where we can check.
    $recoverySignal = [pscustomobject]@{ IsTimeout = $false; IsAbort = $false; IsRecovery = $false; IsPaused = $false; Note = $null }
    try {
        Import-Module "$PSScriptRoot\..\modules\RBR.Recovery.psm1" -Force -DisableNameChecking -ErrorAction Stop
        $recoverySignal = Test-RBRBackendRecoverySignal
    } catch {
        Write-LogEntry -Module TEST -Type WARNING -Message ("[PWRTEST] Backend recovery-status check unavailable: {0}" -f $_.Exception.Message)
    }
    # Only a backend-reported timeout (exit 97) or operator abort (exit 96) halts the whole session (mirrors
    # the resume path's Complete-RBRRecoveryTimeout trigger). A PDU recovery with
    # no timeout is a per-task note only (exit 98) -- the session keeps going.
    if ($recoverySignal.IsTimeout) {
        Write-LogEntry -Module TEST -Type ERROR -Message ("[PWRTEST] S3 did not resume normally (backend timeout): {0}" -f $recoverySignal.Note)
        exit 97
    }
    if ($recoverySignal.IsAbort) {
        Write-LogEntry -Module TEST -Type ERROR -Message ("[PWRTEST] Backend reported operator abort: {0}" -f $recoverySignal.Note)
        exit 96
    }
    if ($recoverySignal.IsRecovery) {
        Write-LogEntry -Module TEST -Type ERROR -Message ("[PWRTEST] S3 did not resume normally (backend recovery): {0}" -f $recoverySignal.Note)
        exit 98
    }
    if ($recoverySignal.IsPaused) { Request-RBREnginePause }
} else {
    Write-LogEntry -Module TEST -Type ERROR -Message ("[PWRTEST] pwrtest.exe /sleep /s:$SleepState exited {0} (Cycles={1}, WakeSource={2}). See pwrtest.log/pwrtest.xml in {3}" -f $(if ($code -lt 0) { '0x{0:X8}' -f $code } else { $code }), $Cycles, $WakeSource, $LogDirectory)
}
exit $code
