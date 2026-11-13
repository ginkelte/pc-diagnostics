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

function New-DiagDxDiagResult {
    <#
      One shape for every dxdiag outcome, so a renderer or a test never has to
      branch on which failure produced the block. A field that was not read is
      filled with "unavailable (<reason>)": never an empty string, never a
      guess, never a default that looks like real data (EC-07).
    #>
    param(
        [bool]$Available = $false,
        [bool]$Skipped = $false,
        [string]$State = 'unavailable (not run)',
        [string]$Reason = $null,
        $OperatingSystem = $null,
        $Processor = $null,
        $Memory = $null,
        [object[]]$DisplayDevices = @(),
        [string[]]$KeyLines = @(),
        [string]$File = $null
    )

    $fallback = [string]$Reason
    if ([string]::IsNullOrWhiteSpace($fallback)) { $fallback = 'not run' }
    $missing = 'unavailable (' + $fallback + ')'
    if ([string]::IsNullOrWhiteSpace([string]$OperatingSystem)) { $OperatingSystem = $missing }
    if ([string]::IsNullOrWhiteSpace([string]$Processor)) { $Processor = $missing }
    if ([string]::IsNullOrWhiteSpace([string]$Memory)) { $Memory = $missing }

    return [pscustomobject][ordered]@{
        Available       = $Available
        Skipped         = $Skipped
        State           = $State
        Reason          = $Reason
        OperatingSystem = $OperatingSystem
        Processor       = $Processor
        Memory          = $Memory
        DisplayDevices  = @($DisplayDevices)
        KeyLines        = @($KeyLines)
        File            = $File
    }
}

function Get-DiagXmlValue {
    <#
      Text of the element with that local name under -Node, or $null when the
      element is absent or blank. Selection is by LocalName only: a namespace
      prefix, the element order and the surrounding tree do not matter, and no
      label text is involved, which is what makes the read independent of the
      language dxdiag rendered the report in (EC-05).
    #>
    param([System.Xml.XmlNode]$Node, [string]$LocalName)

    if ($null -eq $Node) { return $null }
    if ([string]::IsNullOrWhiteSpace($LocalName)) { return $null }

    $element = $null
    try { $element = $Node.SelectSingleNode("./*[local-name()='" + $LocalName + "']") } catch { $element = $null }
    if ($null -eq $element) {
        # Some builds nest the value one level deeper; still by local name.
        try { $element = $Node.SelectSingleNode(".//*[local-name()='" + $LocalName + "']") } catch { $element = $null }
    }
    if ($null -eq $element) { return $null }

    $text = [string]$element.InnerText
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return (ConvertTo-DiagSingleLine -Text $text -MaxLength 200)
}

function Get-DiagXmlValueOrUnavailable {
    <#
      A field value that is never blank: a missing element becomes
      "unavailable (missing element <Name>)" so the report says what is missing
      instead of showing nothing.
    #>
    param([System.Xml.XmlNode]$Node, [string]$LocalName)

    $value = Get-DiagXmlValue -Node $Node -LocalName $LocalName
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        return ('unavailable (missing element ' + $LocalName + ')')
    }
    return $value
}

function Get-DiagDxDiagDisplayDevices {
    <#
      One flat object per adapter, so an integrated GPU plus a dedicated one
      yields two entries. The <DisplayDevices> container is preferred; a
      document that only carries <DisplayDevice> elsewhere still works.
    #>
    param([System.Xml.XmlNode]$Document)

    $nodes = New-Object System.Collections.ArrayList
    if ($null -ne $Document) {
        $containers = @()
        try { $containers = @($Document.SelectNodes("//*[local-name()='DisplayDevices']")) } catch { $containers = @() }
        foreach ($container in $containers) {
            if ($null -eq $container) { continue }
            foreach ($node in @($container.SelectNodes("./*[local-name()='DisplayDevice']"))) {
                if ($null -ne $node) { [void]$nodes.Add($node) }
            }
        }
        if ($nodes.Count -eq 0) {
            try {
                foreach ($node in @($Document.SelectNodes("//*[local-name()='DisplayDevice']"))) {
                    if ($null -ne $node) { [void]$nodes.Add($node) }
                }
            } catch { }
        }
    }

    $devices = New-Object System.Collections.ArrayList
    foreach ($node in $nodes.ToArray()) {
        [void]$devices.Add([pscustomobject][ordered]@{
            CardName        = (Get-DiagXmlValueOrUnavailable -Node $node -LocalName 'CardName')
            ChipType        = (Get-DiagXmlValueOrUnavailable -Node $node -LocalName 'ChipType')
            DedicatedMemory = (Get-DiagXmlValueOrUnavailable -Node $node -LocalName 'DedicatedMemory')
            DriverVersion   = (Get-DiagXmlValueOrUnavailable -Node $node -LocalName 'DriverVersion')
            DriverDate      = (Get-DiagXmlValueOrUnavailable -Node $node -LocalName 'DriverDate')
        })
    }
    return @($devices.ToArray())
}

function Get-DiagDxDiag {
    <#
      Runs "dxdiag /x <OutputDir>\dxdiag-<host>-<stamp>.xml" with a 90 s timeout
      and reads the XML by element local name.

      Why XML and not the text report: "dxdiag /t" writes the report in the
      language of the system, so an allowlist of English labels ("Operating
      System:", "Card name:") matched zero lines on an es-CL Windows and the
      block degraded to "no key lines matched" after waiting up to 90 s. The /x
      document uses element names (OperatingSystem, CardName, ...) that do not
      change with the display language (EC-05).

      Never throws: a missing binary, a timeout, an absent file, an unparsable
      document or a missing element degrades the block to
      "unavailable (<reason>)" and the run continues (RF-12, EC-07).
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
        return (New-DiagDxDiagResult -Skipped $true -State 'skipped (-SkipDxDiag)' -Reason 'skipped')
    }

    $target = Join-Path -Path $OutputDir -ChildPath ('dxdiag-' + $HostName + '-' + $Stamp + '.xml')

    $command = $null
    try { $command = Get-Command -Name 'dxdiag.exe' -ErrorAction Stop } catch { $command = $null }
    if ($null -eq $command) {
        Add-DiagProblem -Collector 'dxdiag' -Reason 'missing'
        return (New-DiagDxDiagResult -State 'unavailable (missing)' -Reason 'missing')
    }

    $timedOut = $false
    try {
        $quoted = '"' + $target + '"'
        $proc = Start-Process -FilePath 'dxdiag.exe' -ArgumentList @('/x', $quoted) -PassThru -WindowStyle Hidden
        $exited = $false
        if ($null -ne $proc) {
            try { $exited = [bool]$proc.WaitForExit($TimeoutSeconds * 1000) } catch { $exited = $false }
        }
        if (-not $exited) {
            $timedOut = $true
            if ($null -ne $proc) {
                try { $proc.Kill() } catch { }
            }
        }
    } catch {
        $reason = Get-DiagErrorText -ErrorRecord $_
        Add-DiagProblem -Collector 'dxdiag' -Reason $reason
        return (New-DiagDxDiagResult -State ('unavailable (' + $reason + ')') -Reason $reason)
    }

    if ($timedOut) {
        Add-DiagProblem -Collector 'dxdiag' -Reason 'timeout'
        return (New-DiagDxDiagResult -State 'unavailable (timeout)' -Reason 'timeout')
    }

    # Wait for the size to stop changing: dxdiag returns before it has finished
    # flushing the file on some builds. The loop gives up after three polls with
    # no file at all, so a build that writes nothing costs three seconds instead
    # of thirty.
    $stable = 0
    $missingPolls = 0
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
        if ($size -gt 0) { $missingPolls = 0 } else { $missingPolls = $missingPolls + 1 }
        if ($missingPolls -ge 3) { break }
        $lastSize = $size
    }

    $exists = $false
    try { $exists = (Test-Path -LiteralPath $target) } catch { $exists = $false }
    if (-not $exists) {
        Add-DiagProblem -Collector 'dxdiag' -Reason 'no xml file'
        return (New-DiagDxDiagResult -State 'unavailable (no xml file)' -Reason 'no xml file')
    }

    # XmlDocument.Load reads the bytes: it honours the BOM and the encoding
    # declaration, so an accented value survives regardless of the output
    # encoding. Get-Content without -Encoding would decode as ANSI on Windows
    # PowerShell 5.1 and mangle it, which is why the file is not read as text.
    $document = $null
    $parseReason = $null
    try {
        $document = New-Object System.Xml.XmlDocument
        try { $document.XmlResolver = $null } catch { }
        $document.Load($target)
    } catch {
        $document = $null
        $detail = ''
        try {
            if ($null -ne $_.Exception.InnerException) { $detail = [string]$_.Exception.InnerException.Message }
        } catch {
            $detail = ''
        }
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = Get-DiagErrorText -ErrorRecord $_ }
        $parseReason = 'xml not parsable: ' + (ConvertTo-DiagSingleLine -Text $detail -MaxLength 160)
    }
    if ($null -eq $document) {
        Add-DiagProblem -Collector 'dxdiag' -Reason 'xml not parsable'
        return (New-DiagDxDiagResult -State ('unavailable (' + $parseReason + ')') -Reason $parseReason -File $target)
    }

    $os = Get-DiagXmlValue -Node $document -LocalName 'OperatingSystem'
    if ([string]::IsNullOrWhiteSpace([string]$os)) { $os = 'unavailable (missing element OperatingSystem)' }
    $processor = Get-DiagXmlValue -Node $document -LocalName 'Processor'
    if ([string]::IsNullOrWhiteSpace([string]$processor)) { $processor = 'unavailable (missing element Processor)' }
    $memory = Get-DiagXmlValue -Node $document -LocalName 'Memory'
    if ([string]::IsNullOrWhiteSpace([string]$memory)) { $memory = 'unavailable (missing element Memory)' }

    $devices = @(Get-DiagDxDiagDisplayDevices -Document $document)

    # The rendered lines are derived from the fields above, so the report and
    # the structured block can never disagree about what dxdiag said.
    $keyLines = New-Object System.Collections.ArrayList
    [void]$keyLines.Add('OperatingSystem: ' + [string]$os)
    [void]$keyLines.Add('Processor: ' + [string]$processor)
    [void]$keyLines.Add('Memory: ' + [string]$memory)
    if ($devices.Count -eq 0) {
        Add-DiagProblem -Collector 'dxdiag' -Reason 'no DisplayDevice element'
        [void]$keyLines.Add('DisplayDevice: unavailable (no DisplayDevice element)')
    } else {
        $index = 0
        foreach ($device in $devices) {
            if ($null -eq $device) { continue }
            $index = $index + 1
            $prefix = 'DisplayDevice #' + [string]$index + ' '
            [void]$keyLines.Add($prefix + 'CardName: ' + [string]$device.CardName)
            [void]$keyLines.Add($prefix + 'DedicatedMemory: ' + [string]$device.DedicatedMemory)
            [void]$keyLines.Add($prefix + 'DriverVersion: ' + [string]$device.DriverVersion)
            [void]$keyLines.Add($prefix + 'DriverDate: ' + [string]$device.DriverDate)
        }
    }

    $lines = @($keyLines.ToArray())
    if ($MaxKeyLines -gt 0 -and $lines.Count -gt $MaxKeyLines) {
        $lines = @($lines | Select-Object -First $MaxKeyLines)
    }

    # If the document parsed but carries none of the expected element names the
    # structure is not the one this collector knows: say so instead of reporting
    # a block of three "missing element" lines as a success.
    $anySystemField = $false
    foreach ($value in @($os, $processor, $memory)) {
        if ([string]$value -notmatch '^unavailable \(') { $anySystemField = $true; break }
    }
    if (-not $anySystemField -and $devices.Count -eq 0) {
        $reason = 'no dxdiag elements matched'
        Add-DiagProblem -Collector 'dxdiag' -Reason $reason
        return (New-DiagDxDiagResult -State ('unavailable (' + $reason + ')') -Reason $reason `
                -OperatingSystem $os -Processor $processor -Memory $memory `
                -DisplayDevices @() -KeyLines $lines -File $target)
    }

    return (New-DiagDxDiagResult -Available $true -State 'ok' -Reason $null `
            -OperatingSystem $os -Processor $processor -Memory $memory `
            -DisplayDevices $devices -KeyLines $lines -File $target)
}
