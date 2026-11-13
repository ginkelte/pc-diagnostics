# lib/Collect-Config.ps1
#
# Configuration and history collectors:
#   power / Fast Startup / pagefile / bugchecks   RF-18, RF-19, RF-25
#   Dynamic Lighting and RGB contention           RF-20, RF-23
#   Windows Update history and pending state      RF-21
#   oldest signed drivers                         RF-22
#   TRIM                                          RF-24
#   optional dxdiag                               RF-12
#
# Everything here is read-only. Remediation is text only (RS-01, AD-13): the
# toolkit prints "powercfg /h off" as advice and never runs it.

# ---------------------------------------------------------------------------
# Isolated probe constants. OQ-01: the Dynamic Lighting registry location is not
# a documented API and varies between builds, so the path and value name live
# here and nowhere else, and the section body prints the path actually probed.
# ---------------------------------------------------------------------------
$script:DiagFastStartupKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$script:DiagFastStartupValue = 'HiberbootEnabled'
$script:DiagFastStartupHint = 'Disable with: powercfg /h off (or use Restart instead of Shutdown).'
$script:DiagFastStartupConsequence = 'Shutdown is a partial hibernation: pending storage/firmware updates will not activate, and ''shut down'' does not reset device state.'

$script:DiagDynamicLightingKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Dynamic Lighting'
$script:DiagDynamicLightingValue = 'Enabled'

$script:DiagLightingPatterns = @(
    'ArmouryCrate', 'LightingService', 'LEDKeeper', 'MSI_', 'LGHUB',
    'Razer', 'iCUE', 'NZXT', 'OpenRGB', 'SignalRgb'
)

$script:DiagLightingContention = 'Multiple lighting services are running; they can contend for the same HID devices and reset device profiles.'
$script:DiagDynamicLightingNote = 'Windows Dynamic Lighting is enabled: OS-level lighting control supersedes third-party RGB profiles for supported devices.'

# Bugcheck codes that explain a store or paging failure on the reference machine
# (section 1.4). Everything else renders (unknown bugcheck).
if ($null -eq $script:DiagBugcheckNames) {
    $script:DiagBugcheckNames = @{
        0x1E  = 'KMODE_EXCEPTION_NOT_HANDLED'
        0xBE  = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY'
        0x9C  = 'MACHINE_CHECK_EXCEPTION'
        0x7A  = 'KERNEL_DATA_INPAGE_ERROR'
        0xEF  = 'CRITICAL_PROCESS_DIED'
        0x154 = 'UNEXPECTED_STORE_EXCEPTION'
    }
}

function Format-DiagBugcheckCode {
    <#
      "0x" plus 8 hex digits, with the friendly name when known and
      "(unknown bugcheck)" otherwise (RF-18).
    #>
    param($Code)
    if ($null -eq $Code) { return $null }
    $value = 0
    try { $value = [int]$Code } catch { return $null }
    $hex = '0x' + $value.ToString('X8', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($value -eq 0) { return $hex + ' no bugcheck (power loss or hard reset)' }
    if ($script:DiagBugcheckNames.ContainsKey($value)) {
        return $hex + ' ' + $script:DiagBugcheckNames[$value]
    }
    return $hex + ' (unknown bugcheck)'
}

function Get-DiagFastStartup {
    <#
      1 -> enabled, 0 -> disabled, missing key or value -> not_present,
      access denied -> unavailable (access denied). The raw token is stored in
      the snapshot; state.json converts it to a bool or null (section 7.2).
    #>
    $result = [pscustomobject]@{
        State     = 'not_present'
        Value     = $null
        ProbePath = $script:DiagFastStartupKey
        Reason    = $null
    }

    $exists = $false
    try { $exists = Test-Path -LiteralPath $script:DiagFastStartupKey } catch { $exists = $false }
    if (-not $exists) {
        # Windows 10 and any build without the key: absence is an answer, not an
        # error.
        return $result
    }

    try {
        $item = Get-ItemProperty -Path $script:DiagFastStartupKey -Name $script:DiagFastStartupValue -ErrorAction Stop
        $raw = Get-DiagPropValue -Object $item -Name $script:DiagFastStartupValue -Default $null
        if ($null -eq $raw) {
            $result.State = 'not_present'
            return $result
        }
        $result.Value = [int]$raw
        if ([int]$raw -eq 1) { $result.State = 'enabled' } else { $result.State = 'disabled' }
    } catch {
        if (Test-DiagAccessDenied -ErrorRecord $_) {
            $result.State = 'unavailable (access denied)'
            $result.Reason = 'access denied'
        } else {
            $reason = Get-DiagErrorText -ErrorRecord $_
            $result.State = 'unavailable (' + $reason + ')'
            $result.Reason = $reason
        }
        Add-DiagProblem -Collector 'power.faststartup' -Reason $result.Reason
    }
    return $result
}

function Get-DiagPagefile {
    <#
      Pagefile configuration (RF-25): each pagefile name, allocated size, current
      usage and peak usage in GB, plus whether the pagefile is system managed.
      "none configured" and "system managed" are decisions for the renderer; the
      snapshot only carries the facts and nulls where nothing was readable.
    #>
    $entries = New-Object System.Collections.ArrayList
    $automatic = $null
    $reason = $null

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $flag = Get-DiagPropValue -Object $cs -Name 'AutomaticManagedPagefile' -Default $null
        if ($null -ne $flag) { $automatic = [bool]$flag }
    } catch {
        Add-DiagProblem -Collector 'power.pagefile.managed' -Reason (Get-DiagErrorText -ErrorRecord $_)
    }

    try {
        $usage = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop)
    } catch {
        $reason = Get-DiagErrorText -ErrorRecord $_
        Add-DiagProblem -Collector 'power.pagefile' -Reason $reason
        $usage = @()
    }

    foreach ($u in $usage) {
        if ($null -eq $u) { continue }
        $allocated = Get-DiagPropValue -Object $u -Name 'AllocatedBaseSize' -Default $null
        $current = Get-DiagPropValue -Object $u -Name 'CurrentUsage' -Default $null
        $peak = Get-DiagPropValue -Object $u -Name 'PeakUsage' -Default $null
        [void]$entries.Add([pscustomobject]@{
            Name        = [string](Get-DiagPropValue -Object $u -Name 'Name' -Default '')
            AllocatedGB = $(if ($null -ne $allocated) { [math]::Round([double]$allocated / 1024.0, 1) } else { $null })
            CurrentGB   = $(if ($null -ne $current) { [math]::Round([double]$current / 1024.0, 1) } else { $null })
            PeakGB      = $(if ($null -ne $peak) { [math]::Round([double]$peak / 1024.0, 1) } else { $null })
        })
    }

    return [pscustomobject]@{
        Available       = ($null -ne $automatic -or $entries.Count -gt 0)
        Reason          = $reason
        AutomaticManaged = $automatic
        Entries         = @($entries.ToArray())
    }
}

function Get-DiagBugchecks {
    <#
      Kernel-Power 41 -> bugcheck codes. BugcheckCode and
      BugcheckParameter1..4 are read from EventData BY FIELD NAME, never by array
      index and never from the message text, so a Spanish or Portuguese event
      yields the same result (RF-18, EC-05).
    #>
    param($KernelPowerEvents)

    $codes = New-Object System.Collections.ArrayList
    foreach ($ev in @($KernelPowerEvents)) {
        if ($null -eq $ev) { continue }
        $raw = Get-DiagEventDataValue -Event $ev -Name 'BugcheckCode'
        $code = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$raw)) {
            try { $code = [int]$raw } catch { $code = $null }
        }
        $params = New-Object System.Collections.ArrayList
        $i = 1
        while ($i -le 4) {
            $p = Get-DiagEventDataValue -Event $ev -Name ('BugcheckParameter' + [string]$i)
            if ([string]::IsNullOrWhiteSpace([string]$p)) {
                [void]$params.Add($null)
            } else {
                [void]$params.Add([string]$p)
            }
            $i = $i + 1
        }
        [void]$codes.Add([pscustomobject]@{
            TimeCreated = Get-DiagPropValue -Object $ev -Name 'TimeCreated' -Default $null
            Code        = $code
            CodeHex     = $(if ($null -ne $code) { '0x' + ([int]$code).ToString('X8', [System.Globalization.CultureInfo]::InvariantCulture) } else { $null })
            Friendly    = (Format-DiagBugcheckCode -Code $code)
            Parameters  = @($params.ToArray())
        })
    }
    return @($codes.ToArray())
}

function Get-DiagPower {
    <#
      Aggregate power section: Fast Startup, pagefile and bugcheck codes.
      Kernel-Power 41 events come from the single event query pass (RF-29).
    #>
    param($KernelPowerEvents)

    $fast = Get-DiagFastStartup
    $pagefile = Get-DiagPagefile
    $bugchecks = Get-DiagBugchecks -KernelPowerEvents $KernelPowerEvents

    return [pscustomobject]@{
        Available     = $true
        Reason        = $null
        FastStartup   = $fast.State
        FastStartupValue = $fast.Value
        FastStartupProbe = $fast.ProbePath
        FastStartupConsequence = $script:DiagFastStartupConsequence
        FastStartupHint = $script:DiagFastStartupHint
        Pagefile      = $pagefile
        BugcheckCodes = $bugchecks
    }
}

# ---------------------------------------------------------------------------
# Dynamic Lighting and RGB contention (RF-20, RF-23)
# ---------------------------------------------------------------------------

function Test-DiagLightingMatch {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($pattern in $script:DiagLightingPatterns) {
        if ($Text -match [regex]::Escape($pattern)) { return $true }
        if ($Text -match $pattern) { return $true }
    }
    return $false
}

function Get-DiagDynamicLighting {
    <#
      enabled | disabled | not_present | unavailable (<reason>). Absence of the
      key is not an error: it is the correct answer on Windows 10 and pre-22H2
      builds (RF-20, OQ-01).
    #>
    $state = 'not_present'
    $probe = $script:DiagDynamicLightingKey

    $exists = $false
    try { $exists = Test-Path -LiteralPath $script:DiagDynamicLightingKey } catch { $exists = $false }
    if (-not $exists) {
        return [pscustomobject]@{ State = 'not_present'; ProbePath = $probe; Enabled = $null }
    }

    try {
        $item = Get-ItemProperty -Path $script:DiagDynamicLightingKey -Name $script:DiagDynamicLightingValue -ErrorAction Stop
        $raw = Get-DiagPropValue -Object $item -Name $script:DiagDynamicLightingValue -Default $null
        if ($null -eq $raw) {
            $state = 'not_present'
            $enabled = $null
        } elseif ([int]$raw -eq 1) {
            $state = 'enabled'
            $enabled = $true
        } else {
            $state = 'disabled'
            $enabled = $false
        }
    } catch {
        $enabled = $null
        if (Test-DiagAccessDenied -ErrorRecord $_) {
            $state = 'unavailable (access denied)'
        } else {
            $state = 'unavailable (' + (Get-DiagErrorText -ErrorRecord $_) + ')'
        }
        Add-DiagProblem -Collector 'lighting.dynamiclighting' -Reason $state
    }
    return [pscustomobject]@{ State = $state; ProbePath = $probe; Enabled = $enabled }
}

function Get-DiagLighting {
    <#
      Two places are checked for competing lighting software (RF-23): services
      whose name or display name matches the constant pattern list, and autostart
      entries whose name or command matches the same list. Both are reported with
      their state so a reader can see which suite owns the devices.
    #>
    $services = New-Object System.Collections.ArrayList
    $startup = New-Object System.Collections.ArrayList
    $allServices = @()
    $allStartup = @()

    try {
        $allServices = @(Get-Service -ErrorAction Stop)
    } catch {
        Add-DiagProblem -Collector 'lighting.services' -Reason (Get-DiagErrorText -ErrorRecord $_)
    }
    foreach ($svc in $allServices) {
        if ($null -eq $svc) { continue }
        $name = [string](Get-DiagPropValue -Object $svc -Name 'Name' -Default '')
        $display = [string](Get-DiagPropValue -Object $svc -Name 'DisplayName' -Default '')
        if (-not ((Test-DiagLightingMatch -Text $name) -or (Test-DiagLightingMatch -Text $display))) { continue }
        [void]$services.Add([pscustomobject]@{
            Name        = $name
            DisplayName = $display
            State       = [string](Get-DiagPropValue -Object $svc -Name 'Status' -Default '')
            StartMode   = [string](Get-DiagPropValue -Object $svc -Name 'StartType' -Default '')
        })
    }

    try {
        $allStartup = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop)
    } catch {
        Add-DiagProblem -Collector 'lighting.startup' -Reason (Get-DiagErrorText -ErrorRecord $_)
    }
    foreach ($entry in $allStartup) {
        if ($null -eq $entry) { continue }
        $name = [string](Get-DiagPropValue -Object $entry -Name 'Name' -Default '')
        $command = [string](Get-DiagPropValue -Object $entry -Name 'Command' -Default '')
        if (-not ((Test-DiagLightingMatch -Text $name) -or (Test-DiagLightingMatch -Text $command))) { continue }
        [void]$startup.Add([pscustomobject]@{
            Name     = $name
            Command  = $command
            Location = [string](Get-DiagPropValue -Object $entry -Name 'Location' -Default '')
            User     = [string](Get-DiagPropValue -Object $entry -Name 'User' -Default '')
        })
    }

    $runningCount = 0
    foreach ($svc in $services) {
        if ($svc.State -eq 'Running') { $runningCount = $runningCount + 1 }
    }

    $dynamic = Get-DiagDynamicLighting

    return [pscustomobject]@{
        Available          = $true
        Reason             = $null
        DynamicLighting    = $dynamic.State
        DynamicLightingProbe = $dynamic.ProbePath
        DynamicLightingNote = $script:DiagDynamicLightingNote
        Services           = @($services.ToArray())
        RunningServices    = $runningCount
        StartupCommands    = @($startup.ToArray())
        StartupTotal       = $allStartup.Count
        ContentionNote     = $script:DiagLightingContention
        ContentionFlag     = ($runningCount -ge 2)
    }
}

# ---------------------------------------------------------------------------
# Windows Update (RF-21)
# ---------------------------------------------------------------------------

function Get-DiagUpdate {
    <#
      Last 5 installed hotfixes plus pending state.

      The pending search MUST be local only: IUpdateSearcher.Online = $false.
      A networked search is a trust violation for a read-only, possibly offline
      tool (RS-02). The search is bounded to 15 s; on timeout or COM failure the
      block renders "pending: unavailable (<reason>)" and the run continues.
    #>
    $hotfixes = New-Object System.Collections.ArrayList
    $pending = $null
    $pendingState = 'none'
    $pendingReason = $null
    $searchDate = $null

    try {
        $fixes = @(Get-HotFix -ErrorAction Stop)
        $usable = New-Object System.Collections.ArrayList
        foreach ($f in $fixes) {
            if ($null -eq $f) { continue }
            [void]$usable.Add([pscustomobject]@{
                HotFixID    = [string](Get-DiagPropValue -Object $f -Name 'HotFixID' -Default '')
                Description = [string](Get-DiagPropValue -Object $f -Name 'Description' -Default '')
                InstalledOn = (Get-DiagPropValue -Object $f -Name 'InstalledOn' -Default $null)
            })
        }
        $ordered = @($usable.ToArray() | Sort-Object -Property @{ Expression = { $_.InstalledOn }; Descending = $true } | Select-Object -First 5)
        foreach ($h in $ordered) { [void]$hotfixes.Add($h) }
    } catch {
        Add-DiagProblem -Collector 'update.hotfix' -Reason (Get-DiagErrorText -ErrorRecord $_)
    }

    $sw = New-Object System.Diagnostics.Stopwatch
    $sw.Start()
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searcher.Online = $false
        try {
            $history = $session.QueryHistory(0, 1)
            if ($null -ne $history -and $null -ne $history.LastSearchSuccessDate) {
                $searchDate = $history.LastSearchSuccessDate
            }
        } catch {
            $searchDate = $null
        }
        $found = $searcher.Search("IsInstalled=0 and Type='Software'")
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -gt 15) {
            $pendingState = 'unavailable (timeout)'
            $pendingReason = 'timeout'
        } elseif ($null -ne $found -and $null -ne $found.Updates -and $found.Updates.Count -gt 0) {
            $first = $found.Updates.Item(0)
            $title = [string]$first.Title
            $dateText = 'unknown'
            if ($null -ne $searchDate) {
                try { $dateText = ([datetime]$searchDate).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch { $dateText = 'unknown' }
            }
            $pending = [pscustomobject]@{ Title = $title; Date = $dateText }
            $pendingState = 'pending'
        } else {
            $pendingState = 'none'
        }
    } catch {
        $sw.Stop()
        $pendingReason = Get-DiagErrorText -ErrorRecord $_
        $pendingState = 'unavailable (' + $pendingReason + ')'
        Add-DiagProblem -Collector 'update.pending' -Reason $pendingReason
    }

    return [pscustomobject]@{
        Available    = $true
        Reason       = $null
        LatestKbs    = @($hotfixes.ToArray())
        Pending      = $pending
        PendingState = $pendingState
        SearchDate   = $searchDate
    }
}

# ---------------------------------------------------------------------------
# Oldest signed drivers (RF-22)
# ---------------------------------------------------------------------------

function Get-DiagDrivers {
    <#
      The 15 oldest signed drivers by DriverDate, ascending, then name ascending.
      Entries with a null or unparsable date are excluded from the ranking and
      counted in NoDriverDate (RF-22).
    #>
    param([int]$Top = 15)

    $entries = New-Object System.Collections.ArrayList
    $noDate = 0
    $reason = $null

    try {
        $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)
    } catch {
        $reason = Get-DiagErrorText -ErrorRecord $_
        Add-DiagProblem -Collector 'drivers' -Reason $reason
        return [pscustomobject]@{
            Available    = $false
            Reason       = $reason
            OldestDrivers = @()
            NoDriverDate = 0
        }
    }

    $now = Get-Date
    foreach ($d in $drivers) {
        if ($null -eq $d) { continue }
        $rawDate = Get-DiagPropValue -Object $d -Name 'DriverDate' -Default $null
        $parsed = $null
        if ($null -ne $rawDate) {
            try { $parsed = [datetime]$rawDate } catch { $parsed = $null }
        }
        if ($null -eq $parsed) {
            $noDate = $noDate + 1
            continue
        }
        $ageYears = $null
        try { $ageYears = [math]::Round((($now - $parsed).TotalDays / 365.25), 1) } catch { $ageYears = $null }
        [void]$entries.Add([pscustomobject]@{
            Date         = $parsed
            DateText     = $parsed.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            AgeYears     = $ageYears
            Name         = [string](Get-DiagPropValue -Object $d -Name 'DeviceName' -Default '')
            Provider     = [string](Get-DiagPropValue -Object $d -Name 'DriverProviderName' -Default '')
            Version      = [string](Get-DiagPropValue -Object $d -Name 'DriverVersion' -Default '')
        })
    }

    $ordered = @($entries.ToArray() | Sort-Object -Property @{ Expression = { $_.Date }; Descending = $false }, @{ Expression = { $_.Name }; Descending = $false } | Select-Object -First $Top)

    return [pscustomobject]@{
        Available     = $true
        Reason        = $null
        OldestDrivers = $ordered
        NoDriverDate  = $noDate
    }
}

# ---------------------------------------------------------------------------
# TRIM and misc (RF-24)
# ---------------------------------------------------------------------------

function Get-DiagTrim {
    <#
      Parses "fsutil behavior query DisableDeleteNotify" with a locale-independent
      token regex. 0 = enabled, 1 = disabled, anything else renders the raw
      number. No match or a missing tool renders "unavailable (<reason>)", never
      "enabled" by default (RF-24).
    #>
    $raw = $null
    $state = 'unavailable (fsutil not run)'
    $reason = $null

    try {
        $output = & fsutil.exe behavior query DisableDeleteNotify 2>$null
        $raw = (@($output) -join "`n")
    } catch {
        $reason = Get-DiagErrorText -ErrorRecord $_
        $state = 'unavailable (' + $reason + ')'
        Add-DiagProblem -Collector 'misc.trim' -Reason $reason
        return [pscustomobject]@{ Trim = $state; Raw = $null; Reason = $reason }
    }

    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
        $reason = 'no output from fsutil'
        $state = 'unavailable (' + $reason + ')'
        Add-DiagProblem -Collector 'misc.trim' -Reason $reason
        return [pscustomobject]@{ Trim = $state; Raw = $null; Reason = $reason }
    }

    $match = [regex]::Match([string]$raw, 'DisableDeleteNotify\s*=\s*(\d)')
    if (-not $match.Success) {
        $reason = 'pattern not found in fsutil output'
        $state = 'unavailable (' + $reason + ')'
        Add-DiagProblem -Collector 'misc.trim' -Reason $reason
        return [pscustomobject]@{ Trim = $state; Raw = [string]$raw; Reason = $reason }
    }

    $value = [int]$match.Groups[1].Value
    if ($value -eq 0) {
        $state = 'enabled'
    } elseif ($value -eq 1) {
        $state = 'disabled'
    } else {
        $state = [string]$value
    }
    return [pscustomobject]@{ Trim = $state; Raw = [string]$raw; Reason = $null }
}

function Get-DiagMisc {
    <#
      Section 14 facts: TRIM, uptime and the Windows build string. Pagefile is
      collected by Get-DiagPagefile and lives under power in the snapshot
      (section 4.4) even though RF-25 renders it in section 14.
    #>
    param($System)

    $trim = Get-DiagTrim

    $uptimeHours = $null
    if ($null -ne $System) { $uptimeHours = Get-DiagPropValue -Object $System -Name 'UptimeHours' -Default $null }

    $build = $null
    if ($null -ne $System) { $build = Get-DiagPropValue -Object $System -Name 'Build' -Default $null }

    return [pscustomobject]@{
        Available    = $true
        Reason       = $null
        Trim         = $trim.Trim
        TrimRaw      = $trim.Raw
        UptimeHours  = $uptimeHours
        WindowsBuild = $build
    }
}

# ---------------------------------------------------------------------------
# dxdiag (RF-12, EC-07, OQ-02)
# ---------------------------------------------------------------------------

if ($null -eq $script:DiagDxDiagLabels) {
    $script:DiagDxDiagLabels = @(
        'Operating System:',
        'System Model:',
        'BIOS:',
        'Processor:',
        'Memory:',
        'Card name:',
        'Driver Version:',
        'Driver Date:',
        'Display Memory:'
    )
}

function Get-DiagDxDiag {
    <#
      Runs dxdiag /t <OutputDir>\dxdiag-<host>-<stamp>.txt with a 90 s timeout,
      waits for the file size to stabilise over two consecutive 1 s polls, then
      extracts at most 40 allowlisted key lines. Never throws; a missing binary
      or a timeout degrades the block and the run continues (RF-12, EC-07).

      The raw file is either complete or absent, never half-written into the
      report.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Stamp,
        [switch]$SkipDxDiag,
        [int]$TimeoutSeconds = 90,
        [int]$MaxKeyLines = 40
    )

    if ($SkipDxDiag) {
        return [pscustomobject]@{
            Available = $false
            Skipped   = $true
            State     = 'skipped (-SkipDxDiag)'
            Reason    = 'skipped'
            KeyLines  = @()
            File      = $null
        }
    }

    $target = Join-Path -Path $OutputDir -ChildPath ('dxdiag-' + $HostName + '-' + $Stamp + '.txt')

    $command = $null
    try { $command = Get-Command -Name 'dxdiag.exe' -ErrorAction Stop } catch { $command = $null }
    if ($null -eq $command) {
        Add-DiagProblem -Collector 'dxdiag' -Reason 'missing'
        return [pscustomobject]@{
            Available = $false
            Skipped   = $false
            State     = 'unavailable (missing)'
            Reason    = 'missing'
            KeyLines  = @()
            File      = $null
        }
    }

    $timedOut = $false
    try {
        $quoted = '"' + $target + '"'
        $proc = Start-Process -FilePath 'dxdiag.exe' -ArgumentList @('/t', $quoted) -PassThru -WindowStyle Hidden
        if ($null -eq $proc -or -not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            if ($null -ne $proc) {
                try { $proc.Kill() } catch { }
            }
        }
    } catch {
        $reason = Get-DiagErrorText -ErrorRecord $_
        Add-DiagProblem -Collector 'dxdiag' -Reason $reason
        return [pscustomobject]@{
            Available = $false
            Skipped   = $false
            State     = 'unavailable (' + $reason + ')'
            Reason    = $reason
            KeyLines  = @()
            File      = $null
        }
    }

    if ($timedOut) {
        Add-DiagProblem -Collector 'dxdiag' -Reason 'timeout'
        return [pscustomobject]@{
            Available = $false
            Skipped   = $false
            State     = 'unavailable (timeout)'
            Reason    = 'timeout'
            KeyLines  = @()
            File      = $null
        }
    }

    # Wait for the size to stop changing: dxdiag returns before it has finished
    # flushing the file on some builds.
    $stable = 0
    $lastSize = -1
    $polls = 0
    while ($stable -lt 2 -and $polls -lt 30) {
        Start-Sleep -Seconds 1
        $polls = $polls + 1
        $size = -1
        try {
            if (Test-Path -LiteralPath $target) {
                $size = (Get-Item -LiteralPath $target).Length
            }
        } catch {
            $size = -1
        }
        if ($size -gt 0 -and $size -eq $lastSize) {
            $stable = $stable + 1
        } else {
            $stable = 0
        }
        $lastSize = $size
    }

    $lines = @()
    try {
        if (Test-Path -LiteralPath $target) { $lines = @(Get-Content -LiteralPath $target -ErrorAction Stop) }
    } catch {
        $lines = @()
    }

    $keyLines = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ($null -eq $line) { continue }
        $text = [string]$line
        foreach ($label in $script:DiagDxDiagLabels) {
            if ($text.TrimStart().StartsWith($label, [System.StringComparison]::OrdinalIgnoreCase) -or
                $text.TrimStart().StartsWith($label.TrimEnd(':'), [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$keyLines.Add((ConvertTo-DiagSingleLine -Text $text -MaxLength 200))
                break
            }
        }
        if ($keyLines.Count -ge $MaxKeyLines) { break }
    }

    if ($keyLines.Count -eq 0) {
        Add-DiagProblem -Collector 'dxdiag' -Reason 'no key lines matched'
    }

    return [pscustomobject]@{
        Available = ($keyLines.Count -gt 0)
        Skipped   = $false
        State     = $(if ($keyLines.Count -gt 0) { 'ok' } else { 'no key lines matched' })
        Reason    = $(if ($keyLines.Count -gt 0) { $null } else { 'no key lines matched' })
        KeyLines  = @($keyLines.ToArray())
        File      = $target
    }
}
