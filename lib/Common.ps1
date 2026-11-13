# lib/Common.ps1
#
# Shared helpers for the PC diagnostics toolkit.
#
# Rules that apply to this file and to every other file in lib/:
#   * dot-sourcing must have no side effects: functions are only defined here,
#     nothing is collected and nothing is written;
#   * function definitions are idempotent, so a repeated dot-source is harmless;
#   * the only place allowed to call Write-Host is Invoke-DiagStep. Every other
#     helper either returns data or records a problem; progress is a protocol,
#     not a log;
#   * read-only: nothing here touches the registry, the network or the disk.
#
# Requirement map: RF-14 (event query guard), RF-27 (unavailable discipline),
# section 9 (progress protocol), RNF-04 (Windows PowerShell 5.1 compatibility).

# Version is exposed in the report header and in state.json consumers.
if ([string]::IsNullOrEmpty([string]$script:PcDiagVersion)) {
    $script:PcDiagVersion = '1.0.0'
}

# ---------------------------------------------------------------------------
# Host and platform helpers
# ---------------------------------------------------------------------------

function Test-DiagWindowsHost {
    <#
      True when the current host is Windows. Windows PowerShell 5.1 has no
      $IsWindows automatic variable, so its absence means Windows.
    #>
    $v = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -ne $v) { return [bool]$v.Value }
    return $true
}

function Get-DiagPropValue {
    <#
      Safe property read. Returns -Default when the object, the property or the
      value is missing/empty. Used everywhere because CIM objects differ between
      Windows builds and because stubs return partial objects.
    #>
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $prop = $null
    try { $prop = $Object.PSObject.Properties[$Name] } catch { $prop = $null }
    if ($null -eq $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Get-DiagErrorText {
    <#
      One single line describing an error record. Reasons end up inside
      "unavailable (<reason>)" so CR/LF inside an exception message would break
      the report layout.
    #>
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) { return 'unknown error' }
    $text = $null
    try { $text = $ErrorRecord.Exception.Message } catch { $text = $null }
    if ([string]::IsNullOrWhiteSpace($text)) {
        try { $text = [string]$ErrorRecord } catch { $text = $null }
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return 'unknown error' }
    return (ConvertTo-DiagSingleLine -Text $text -MaxLength 300)
}

function Test-DiagAccessDenied {
    <#
      Detects an access-denied failure by HRESULT (0x80070005) or by exception
      type, never by the localised message text (EC-05).
    #>
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) { return $false }
    try {
        if ($ErrorRecord.Exception -is [System.UnauthorizedAccessException]) { return $true }
    } catch { }
    $hresult = $null
    try { $hresult = $ErrorRecord.Exception.HResult } catch { $hresult = $null }
    if ($null -ne $hresult -and ($hresult -eq -2147024891 -or $hresult -eq 5)) { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# Formatting helpers (invariant culture, one decimal, never locale dependent)
# ---------------------------------------------------------------------------

function Format-DiagNumber {
    <#
      Invariant one-decimal formatting. A "2,1" in an artifact is a defect in
      every locale (section 7.3).
    #>
    param($Value, [int]$Decimals = 1)
    if ($null -eq $Value) { return $null }
    $fmt = '{0:F' + [string]$Decimals + '}'
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $fmt, [double]$Value)
}

function Format-DiagSeconds {
    param($Seconds)
    if ($null -eq $Seconds) { $Seconds = 0 }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F1}', [double]$Seconds)
}

function Format-DiagGb {
    <#
      Bytes to a one-decimal gigabyte string, invariant culture.
    #>
    param($Bytes)
    if ($null -eq $Bytes) { return $null }
    return (Format-DiagNumber -Value ([double]$Bytes / 1073741824.0) -Decimals 1)
}

function ConvertTo-DiagSingleLine {
    <#
      Collapses CR, LF and TAB to single spaces and truncates to -MaxLength
      characters plus "...". Applied after collapsing, so a 4000-character
      single line and a 400-line message both become one bounded line (EC-10).
    #>
    param([string]$Text, [int]$MaxLength = 160)
    if ($null -eq $Text) { return '' }
    $t = [string]$Text
    $t = $t.Replace("`r`n", ' ').Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ')
    while ($t.Contains('  ')) { $t = $t.Replace('  ', ' ') }
    $t = $t.Trim()
    if ($t.Length -gt $MaxLength) { $t = $t.Substring(0, $MaxLength) + '...' }
    return $t
}

function Get-DiagTimestamp {
    <#
      ISO 8601 with the local UTC offset, e.g. 2026-11-13T18:42:11-03:00.
      Never epoch numbers, never a culture-formatted date (section 7.3).
    #>
    param([datetime]$Date)
    if ($PSBoundParameters.ContainsKey('Date')) {
        return $Date.ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-DiagDateTime {
    <#
      Normalises a timestamp that arrives either as a string (JSON on a cold read)
      or as a [datetime] (ConvertFrom-Json materialises an ISO 8601 string into a
      DateTime, so the "obvious" [string] cast silently changes the format and,
      under a non-invariant culture, the value).

      Returns $null when the value is absent or unparsable, so the caller renders
      "unavailable" or "no baseline" instead of comparing against a guessed date.
      RoundtripKind keeps the offset, and a UTC value is converted to local time
      before any window comparison because .NET compares Ticks and ignores Kind.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }

    $dt = $null
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
    } elseif ($Value -is [System.DateTimeOffset]) {
        $dt = $Value.LocalDateTime
    } else {
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        try {
            $dt = [datetime]::Parse($text.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        } catch {
            $dt = $null
        }
    }

    if ($null -eq $dt) { return $null }
    if ($dt.Kind -eq [System.DateTimeKind]::Utc) { $dt = $dt.ToLocalTime() }
    return $dt
}

function Get-DiagFileNameStamp {
    param([datetime]$Date)
    if ($PSBoundParameters.ContainsKey('Date')) {
        return $Date.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DiagHostName {
    <#
      $env:COMPUTERNAME lowercased with characters outside [a-z0-9-] replaced by
      "-", as used in artifact file names (section 8.1). Falls back to "unknown"
      so a Linux test host without COMPUTERNAME still produces a valid name.
    #>
    $name = [string]$env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string][System.Environment]::MachineName }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'unknown' }
    $name = $name.ToLowerInvariant()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $name.ToCharArray()) {
        if (($ch -ge 'a' -and $ch -le 'z') -or ($ch -ge '0' -and $ch -le '9') -or $ch -eq '-') {
            [void]$sb.Append($ch)
        } else {
            [void]$sb.Append('-')
        }
    }
    return $sb.ToString()
}

function Get-DiagUniquePath {
    <#
      Returns -Path, or "<stem>-2<suffix>", "<stem>-3<suffix>" ... when the file
      already exists. A second run in the same second must never overwrite the
      previous artifact (section 8.1).
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    $n = 2
    while ($n -lt 1000) {
        $candidate = [System.IO.Path]::Combine($dir, $stem + '-' + [string]$n + $ext)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $n = $n + 1
    }
    return $Path
}

function New-DiagUnavailableSection {
    <#
      Uniform "this section could not be collected" shape. Renderers may use
      Available/Reason; the same fact is also recorded in problems[] (RF-27).
    #>
    param([string]$Reason = 'unavailable')
    return [pscustomobject]@{
        Available = $false
        Reason    = $Reason
    }
}

# ---------------------------------------------------------------------------
# Problems and counters (RF-27, RF-14 step 4)
# ---------------------------------------------------------------------------

function Get-DiagProblemList {
    <#
      The live problem list. Returned with -NoEnumerate because an empty
      ArrayList that goes through the pipeline as a return value is unrolled to
      nothing, which would turn "no problems" into a null reference. Prefer
      Add-DiagProblem / Get-DiagProblems over using this directly.
    #>
    if ($null -eq $script:PcDiagProblems) {
        $script:PcDiagProblems = New-Object System.Collections.ArrayList
    }
    Write-Output -NoEnumerate $script:PcDiagProblems
}

function Reset-DiagProblems {
    $script:PcDiagProblems = New-Object System.Collections.ArrayList
}

function Add-DiagProblem {
    <#
      Records a degraded collector. Deduplicated on (Collector, Reason) so a
      per-volume failure does not fill the report with the same line.
    #>
    param([string]$Collector, [string]$Reason)
    if ([string]::IsNullOrWhiteSpace($Collector)) { $Collector = 'unknown' }
    if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = 'unavailable' }
    if ($null -eq $script:PcDiagProblems) {
        $script:PcDiagProblems = New-Object System.Collections.ArrayList
    }
    $list = $script:PcDiagProblems
    foreach ($existing in $list) {
        if ($existing.Collector -eq $Collector -and $existing.Reason -eq $Reason) { return }
    }
    [void]$list.Add([pscustomobject]@{ Collector = $Collector; Reason = $Reason })
}

function Get-DiagProblems {
    if ($null -eq $script:PcDiagProblems) { return @() }
    return @($script:PcDiagProblems.ToArray())
}

function Reset-DiagOffProviderDropped {
    $script:PcDiagOffProviderDropped = 0
}

function Add-DiagOffProviderDropped {
    <#
      Counts events dropped because the source ignored the provider filter
      (RF-14 step 4). A non-zero value is a warning in the report header.
    #>
    param([int]$Count = 1)
    if ($null -eq $script:PcDiagOffProviderDropped) { $script:PcDiagOffProviderDropped = 0 }
    $script:PcDiagOffProviderDropped = $script:PcDiagOffProviderDropped + $Count
}

function Get-DiagOffProviderDropped {
    if ($null -eq $script:PcDiagOffProviderDropped) { return 0 }
    return [int]$script:PcDiagOffProviderDropped
}

# ---------------------------------------------------------------------------
# Elevation (RF-27, EC-01)
# ---------------------------------------------------------------------------

function Test-DiagElevation {
    <#
      True when the process is running with administrator rights. Returns false
      on non-Windows hosts and on any failure: a wrong "yes" would hide the
      DEGRADED RUN banner, a wrong "no" only adds a warning.
    #>
    try {
        if (-not (Test-DiagWindowsHost)) { return $false }
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $role = [System.Security.Principal.WindowsBuiltInRole]::Administrator
        return [bool]$principal.IsInRole($role)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Progress protocol (section 9)
# ---------------------------------------------------------------------------

function Set-DiagProgressSink {
    <#
      Sets the process-wide progress sink used by Invoke-DiagStep when no -Sink
      is passed explicitly. Passing an empty scriptblock silences progress, which
      is how Quick mode satisfies "no progress lines" (RF-04) while still using
      the same step machinery. Passing $null restores host output.
    #>
    param([scriptblock]$Sink)
    $script:PcDiagProgressSink = $Sink
}

function Get-DiagProgressSink {
    return $script:PcDiagProgressSink
}

function Invoke-DiagStep {
    <#
      The single point that emits progress. One line per step:

        [i/N] <Label> ...
        [i/N] <Label> ... done (0.4s)
        [i/N] <Label> ... unavailable (<reason>) (90.1s)

      The prefix is printed before the work starts so a 90 s dxdiag step is
      visibly alive. A step that throws does not abort the run: it completes as
      "unavailable", records a problem and returns $null (RF-27).

      -Sink receives the completed line verbatim (used by tests to count lines).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [scriptblock]$Sink
    )

    $prefix = '[' + [string]$Index + '/' + [string]$Total + '] ' + $Label + ' ...'

    $sinkToUse = $null
    if ($PSBoundParameters.ContainsKey('Sink')) {
        $sinkToUse = $Sink
    } elseif ($null -ne $script:PcDiagProgressSink) {
        $sinkToUse = $script:PcDiagProgressSink
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timer = $null
    $subscriber = $null

    if ($null -eq $sinkToUse) {
        Write-Host -NoNewline $prefix
        # Heartbeat: a "." every 2 s on the same line. The timer only pumps the
        # message queue; if the host cannot service it the run is unaffected.
        try {
            $subscriber = 'PcDiagHeartbeat' + [string]$Index
            $timer = New-Object System.Timers.Timer
            $timer.Interval = 2000
            $timer.AutoReset = $true
            Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier $subscriber -Action {
                try { [System.Console]::Out.Write('.'); [System.Console]::Out.Flush() } catch { }
            } | Out-Null
            $timer.Start()
        } catch {
            $timer = $null
        }
    }

    $result = $null
    $failure = $null
    try {
        $result = & $Script
    } catch {
        $failure = Get-DiagErrorText -ErrorRecord $_
    } finally {
        if ($null -ne $timer) {
            try { $timer.Stop(); $timer.Dispose() } catch { }
            $timer = $null
        }
        if ($null -ne $subscriber) {
            try { Unregister-Event -SourceIdentifier $subscriber -ErrorAction SilentlyContinue } catch { }
            try { Get-Job -Name $subscriber -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue } catch { }
            try { Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Completed' -and $_.Name -like 'PcDiagHeartbeat*' } | Remove-Job -Force -ErrorAction SilentlyContinue } catch { }
        }
        $sw.Stop()
    }

    $elapsed = Format-DiagSeconds -Seconds $sw.Elapsed.TotalSeconds
    if ($null -ne $failure) {
        $line = $prefix + ' unavailable (' + $failure + ') (' + $elapsed + 's)'
    } else {
        $line = $prefix + ' done (' + $elapsed + 's)'
    }

    if ($null -ne $sinkToUse) {
        & $sinkToUse $line
    } else {
        Write-Host $line.Substring($prefix.Length)
    }

    if ($null -ne $failure) {
        Add-DiagProblem -Collector $Label -Reason $failure
        return $null
    }
    return $result
}

# ---------------------------------------------------------------------------
# Event access (RF-13, RF-14) - the ONLY place allowed to call Get-WinEvent
# ---------------------------------------------------------------------------

function Test-DiagNoEventsError {
    <#
      True for the "no events were found that match the selection criteria"
      failure (HRESULT 0x80070490). Detected by HRESULT, never by matching
      localised message text (EC-04, EC-05). The FullyQualifiedErrorId check is
      a resource identifier, not a display string, and is only a fallback.
    #>
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) { return $false }
    $hresult = $null
    try { $hresult = $ErrorRecord.Exception.HResult } catch { $hresult = $null }
    if ($null -eq $hresult -and $null -ne $ErrorRecord.Exception.InnerException) {
        try { $hresult = $ErrorRecord.Exception.InnerException.HResult } catch { $hresult = $null }
    }
    # 0x80070490 as a signed 32-bit integer.
    if ($null -ne $hresult -and ($hresult -eq -2147023728 -or $hresult -eq 0x80070490)) { return $true }
    $fqid = [string]$ErrorRecord.FullyQualifiedErrorId
    if ($fqid -like 'NoMatchingEventsFound*') { return $true }
    return $false
}

function Get-DiagEventData {
    <#
      EventData as an ordered name/value map. Field names are read from the XML
      Data[@Name] attribute, so classification never depends on message language
      (EC-05). Stubs may supply the map directly on a Data property.
    #>
    param($Event)
    $data = [ordered]@{}
    if ($null -eq $Event) { return $data }

    $prop = $null
    try { $prop = $Event.PSObject.Properties['Data'] } catch { $prop = $null }
    if ($null -ne $prop -and $null -ne $prop.Value) {
        $val = $prop.Value
        if ($val -is [System.Collections.IDictionary]) {
            foreach ($k in $val.Keys) { $data[[string]$k] = $val[$k] }
            return $data
        }
        if ($val -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $val.PSObject.Properties) { $data[[string]$p.Name] = $p.Value }
            return $data
        }
    }

    $xmlText = $null
    $method = $null
    try { $method = $Event.PSObject.Methods['ToXml'] } catch { $method = $null }
    if ($null -ne $method) {
        try { $xmlText = [string]$Event.ToXml() } catch { $xmlText = $null }
    }
    if ([string]::IsNullOrWhiteSpace($xmlText)) {
        $rawXml = Get-DiagPropValue -Object $Event -Name 'Xml' -Default $null
        if ($null -ne $rawXml) { $xmlText = [string]$rawXml }
    }
    if ([string]::IsNullOrWhiteSpace($xmlText)) { return $data }

    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($xmlText)
        $nodes = $doc.SelectNodes("/*[local-name()='Event']/*[local-name()='EventData']/*[local-name()='Data']")
        $i = 0
        foreach ($node in $nodes) {
            $key = $node.GetAttribute('Name')
            if ([string]::IsNullOrWhiteSpace($key)) { $key = 'Data' + [string]$i }
            $data[$key] = $node.InnerText
            $i = $i + 1
        }
    } catch {
        # Unparsable XML yields an empty map; callers treat that as "no fields".
    }
    return $data
}

function Get-DiagEventDataValue {
    <#
      Single EventData value by field name (RF-15 P1..P10, RF-18 bugcheck
      fields). By name, never by array index.
    #>
    param($Event, [string]$Name)
    $data = Get-DiagPropValue -Object $Event -Name 'Data' -Default $null
    if ($null -eq $data) { return $null }
    if ($data -is [System.Collections.IDictionary]) {
        if ($data.Contains($Name)) { return $data[$Name] }
        return $null
    }
    $prop = $null
    try { $prop = $data.PSObject.Properties[$Name] } catch { $prop = $null }
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-DiagEvent {
    <#
      Provider-and-ID filtered event query. This is the only function in the
      toolkit allowed to call Get-WinEvent.

      Guards (RF-14):
        1. empty ProviderName  -> PROVIDER_FILTER_REQUIRED
        2. empty Id            -> ID_FILTER_REQUIRED
        3. LogName + ProviderName + Id + StartTime go into ONE FilterHashtable
           (server-side filtering; Where-Object post-filtering is not a substitute)
        4. events whose ProviderName differs from the requested one are dropped
           and counted, so the count stays correct even if the source is wrong
        5. no classification by message text happens here

      The no-events failure is an empty result (EC-04). Any other failure is a
      terminating error so the caller can render "unavailable (<reason>)"
      instead of a false zero (RF-27).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LogName,
        [string]$ProviderName,
        [int[]]$Id,
        # Not Mandatory on purpose: the provider and Id guards below must be what
        # fails when a caller forgets a filter, not a parameter-binding prompt.
        # Every internal caller passes -Since explicitly; the default only exists
        # so the guards are reachable.
        [datetime]$Since = (Get-Date).AddYears(-1),
        [int]$MaxEvents = 0
    )

    if ([string]::IsNullOrWhiteSpace($ProviderName)) {
        $ex = New-Object System.Exception('PROVIDER_FILTER_REQUIRED: every event query must name an exact provider, not only an event Id.')
        $record = New-Object System.Management.Automation.ErrorRecord(
            $ex, 'PROVIDER_FILTER_REQUIRED',
            [System.Management.Automation.ErrorCategory]::InvalidArgument, $ProviderName)
        $PSCmdlet.ThrowTerminatingError($record)
    }
    if ($null -eq $Id -or $Id.Count -eq 0) {
        $ex = New-Object System.Exception('ID_FILTER_REQUIRED: every event query must name at least one event Id.')
        $record = New-Object System.Management.Automation.ErrorRecord(
            $ex, 'ID_FILTER_REQUIRED',
            [System.Management.Automation.ErrorCategory]::InvalidArgument, $Id)
        $PSCmdlet.ThrowTerminatingError($record)
    }

    $filter = @{
        LogName      = $LogName
        ProviderName = $ProviderName
        Id           = $Id
        StartTime    = $Since
    }

    $raw = $null
    try {
        if ($MaxEvents -gt 0) {
            $raw = Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop
        } else {
            $raw = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop
        }
    } catch {
        if (Test-DiagNoEventsError -ErrorRecord $_) {
            $raw = @()
        } else {
            $reason = Get-DiagErrorText -ErrorRecord $_
            $ex = New-Object System.Exception('DIAG_QUERY_FAILED: ' + $reason, $_.Exception)
            $record = New-Object System.Management.Automation.ErrorRecord(
                $ex, 'DIAG_QUERY_FAILED',
                [System.Management.Automation.ErrorCategory]::NotSpecified, $filter)
            $PSCmdlet.ThrowTerminatingError($record)
        }
    }

    $result = New-Object System.Collections.ArrayList
    $dropped = 0
    foreach ($ev in @($raw)) {
        if ($null -eq $ev) { continue }
        $evProvider = [string](Get-DiagPropValue -Object $ev -Name 'ProviderName' -Default '')
        if ($evProvider -ne $ProviderName) {
            $dropped = $dropped + 1
            continue
        }
        $level = Get-DiagPropValue -Object $ev -Name 'LevelDisplayName' -Default $null
        if ([string]::IsNullOrWhiteSpace([string]$level)) {
            $level = Get-DiagPropValue -Object $ev -Name 'Level' -Default $null
        }
        $time = Get-DiagPropValue -Object $ev -Name 'TimeCreated' -Default $null
        $id = Get-DiagPropValue -Object $ev -Name 'Id' -Default $null
        $message = [string](Get-DiagPropValue -Object $ev -Name 'Message' -Default '')
        [void]$result.Add([pscustomobject]@{
            TimeCreated  = $time
            Id           = $id
            ProviderName = $evProvider
            Level        = $level
            Message      = $message
            Data         = (Get-DiagEventData -Event $ev)
        })
    }
    if ($dropped -gt 0) { Add-DiagOffProviderDropped -Count $dropped }

    return @($result.ToArray())
}

# ---------------------------------------------------------------------------
# Snapshot assembly (section 4.4, AD-07)
#
# New-DiagSnapshot is the only aggregate seam: collection produces one plain
# object and the renderers consume nothing else. That is what lets a renderer be
# tested on Linux with fixtures and a collector be tested without a renderer.
#
# The frozen parameters of section 4.3 are -Days, -TopFolders,
# -MaxEventsPerCategory and -SkipDxDiag. Four additional optional parameters are
# needed by the entry point and default to values that keep a bare
# "New-DiagSnapshot -Days 30 -TopFolders 10 -MaxEventsPerCategory 20" call valid:
#   -Mode           Full or Quick; Quick skips the expensive collectors (RF-04)
#   -OutputDir      where dxdiag writes; empty means skip dxdiag (write containment)
#   -StatePath      the path rendered by Quick mode's "state:" line
#   -Previous       previous state object, used for deltas and the baseline line
# ---------------------------------------------------------------------------
function New-DiagSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Days,
        [Parameter(Mandatory = $true)][int]$TopFolders,
        [Parameter(Mandatory = $true)][int]$MaxEventsPerCategory,
        [switch]$SkipDxDiag,
        [ValidateSet('Full', 'Quick')][string]$Mode = 'Full',
        [string]$OutputDir = '',
        [string]$StatePath = '',
        $Previous = $null,
        [int]$EventBudgetSeconds = 0,
        [int]$FolderBudgetSeconds = 30
    )

    Reset-DiagProblems
    Reset-DiagOffProviderDropped

    $startedAt = Get-Date
    $windowStart = $startedAt.Date.AddDays(-1 * $Days)
    $hostName = Get-DiagHostName
    $stamp = Get-DiagFileNameStamp -Date $startedAt
    $elevated = Test-DiagElevation

    if ($EventBudgetSeconds -le 0) {
        # RNF-01: 30 s for the whole event step in Full mode, 10 s in Quick.
        if ($Mode -eq 'Quick') { $EventBudgetSeconds = 10 } else { $EventBudgetSeconds = 30 }
    }

    $total = 12
    # RF-04: Quick mode never runs dxdiag, so the step does not exist and the
    # progress denominator drops with it (as it already does for -SkipDxDiag).
    if ($SkipDxDiag -or $Mode -ne 'Full') { $total = 11 }

    # Baseline resolution (RF-29, EC-13).
    $baselineUsable = $false
    $baselineReason = 'none (first run)'
    $previousLastRun = $null
    $previousLastRunDate = $null
    if ($null -ne $Previous) {
        $previousLastRun = Get-DiagPropValue -Object $Previous -Name 'last_run_at' -Default $null
        $previousHost = [string](Get-DiagPropValue -Object $Previous -Name 'host' -Default '')
        # Accepts both shapes the state can have in memory: an ISO string or the
        # DateTime ConvertFrom-Json produced (see ConvertTo-DiagDateTime).
        if (-not [string]::IsNullOrWhiteSpace([string]$previousLastRun)) {
            $previousLastRunDate = ConvertTo-DiagDateTime -Value $previousLastRun
        }
        if ($null -eq $previousLastRunDate) {
            $baselineReason = 'none (first run)'
        } elseif (-not [string]::IsNullOrEmpty($previousHost) -and $previousHost -ne $hostName) {
            $baselineReason = 'none (host changed)'
        } elseif ($previousLastRunDate -gt $startedAt) {
            $baselineReason = 'none (previous run is in the future)'
        } elseif ($previousLastRunDate -lt $windowStart) {
            $baselineReason = 'out of window (' + $previousLastRunDate.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) + ')'
        } else {
            $baselineUsable = $true
            $baselineReason = 'ok'
        }
    }

    $system = $null
    $gpu = $null
    $cpu = $null
    $memory = $null
    $disks = @()
    $disksSection = $null
    $volumes = @()
    $scanMap = @{}
    $eventPass = $null
    $wer = $null
    $boots = $null
    $power = $null
    $lighting = $null
    $update = $null
    $drivers = $null
    $misc = $null
    $dxdiag = $null

    # 1 - system identity and display adapters (RF-05, RF-08b)
    $s1 = Invoke-DiagStep -Index 1 -Total $total -Label 'Collecting system identity' -Script {
        [pscustomobject]@{
            System = (Get-DiagSystem)
            Gpu    = (Get-DiagGpu)
        }
    }
    if ($null -ne $s1) { $system = $s1.System; $gpu = $s1.Gpu }
    if ($null -eq $system) { $system = New-DiagUnavailableSection -Reason 'collector failed' }
    if ($null -eq $gpu) { $gpu = [pscustomobject]@{ Available = $false; Reason = 'collector failed'; Adapters = @() } }

    # 2 - CPU (RF-06)
    $cpu = Invoke-DiagStep -Index 2 -Total $total -Label 'Collecting CPU information' -Script {
        Get-DiagCpu
    }
    if ($null -eq $cpu) { $cpu = New-DiagUnavailableSection -Reason 'collector failed' }

    # 3 - memory modules (RF-07)
    $memory = Invoke-DiagStep -Index 3 -Total $total -Label 'Collecting memory modules' -Script {
        Get-DiagMemory
    }
    if ($null -eq $memory) { $memory = New-DiagUnavailableSection -Reason 'collector failed' }

    # 4 - storage inventory (RF-08)
    $s4 = Invoke-DiagStep -Index 4 -Total $total -Label 'Enumerating storage devices' -Script {
        Get-DiagDisks
    }
    if ($null -ne $s4) { $disksSection = $s4; $disks = @($s4.Disks) }
    if ($null -eq $disksSection) { $disksSection = [pscustomobject]@{ Available = $false; Reason = 'collector failed'; Disks = @() } }

    # 5 - NVMe SMART (RF-09)
    $s5 = Invoke-DiagStep -Index 5 -Total $total -Label 'Reading NVMe SMART counters' -Script {
        Add-DiagNvmeSmart -Disks $disks
    }
    if ($null -ne $s5) { $disks = @($s5); $disksSection.Disks = $disks }

    # 6 - volume free space (RF-10)
    $s6 = Invoke-DiagStep -Index 6 -Total $total -Label 'Measuring volume free space' -Script {
        Get-VolumeSpace
    }
    if ($null -ne $s6) { $volumes = @($s6) } else { $volumes = @() }

    # 7 - largest folders and files (RF-11). Quick mode must not scan (RF-04).
    if ($Mode -eq 'Full') {
        $s7 = Invoke-DiagStep -Index 7 -Total $total -Label 'Scanning largest folders' -Script {
            $scans = @{}
            foreach ($v in @($volumes)) {
                if ($null -eq $v) { continue }
                $scans[[string]$v.Mount] = Measure-DiagFolderScan -Volume ([string]$v.Mount) -Top $TopFolders -TimeBudgetSeconds $FolderBudgetSeconds
            }
            $scans
        }
        if ($null -ne $s7) { $scanMap = $s7 }
    } else {
        Add-DiagProblem -Collector 'largest_folders' -Reason 'skipped in Quick mode'
    }

    # Attach the per-volume scan result to the volume itself so a renderer can
    # state scanned bytes against the volume's used bytes and detect a partial
    # scan from the numbers alone (RF-11) without needing another key in the
    # snapshot.
    foreach ($v in @($volumes)) {
        if ($null -eq $v) { continue }
        $scannedGb = $null
        $scannedFiles = $null
        $scanPartial = $null
        if ($scanMap.ContainsKey([string]$v.Mount)) {
            $scan = $scanMap[[string]$v.Mount]
            if ($null -ne $scan) {
                $scannedGb = $scan.ScannedGB
                $scannedFiles = $scan.FileCount
                $scanPartial = $scan.Partial
            }
        }
        $v | Add-Member -NotePropertyName 'ScannedGB' -NotePropertyValue $scannedGb -Force
        $v | Add-Member -NotePropertyName 'ScannedFileCount' -NotePropertyValue $scannedFiles -Force
        $v | Add-Member -NotePropertyName 'ScanPartial' -NotePropertyValue $scanPartial -Force
    }

    # 8 - event logs: totals, deltas and listings from one query per catalog row
    #     (RF-13, RF-14, RF-29). 9 - WER grouping (RF-15).
    $sinceLastRun = $null
    if ($baselineUsable) { $sinceLastRun = $previousLastRunDate }

    $s8 = Invoke-DiagStep -Index 8 -Total $total -Label 'Querying event logs' -Script {
        Get-DiagEventPass -Since $windowStart -SinceLastRun $sinceLastRun -TotalBudgetSeconds $EventBudgetSeconds
    }
    if ($null -ne $s8) { $eventPass = $s8 }

    $s9 = Invoke-DiagStep -Index 9 -Total $total -Label 'Grouping crashes (WER)' -Script {
        $werEvents = @()
        if ($null -ne $eventPass -and $null -ne $eventPass.Events -and $eventPass.Events.ContainsKey('wer_1001')) {
            $werEvents = @($eventPass.Events['wer_1001'])
        }
        Get-WerSummary -Events $werEvents
    }
    if ($null -eq $s9) {
        $s9 = [pscustomobject]@{
            events_seen = 0; unique_dumps = 0; unique_params = 0; unidentified = 0; repeats = 0; signatures = @()
        }
    }
    $wer = $s9

    # Boot classification uses the same event pass (RF-17).
    $boots = Get-DiagBoots `
        -Events6005 $(if ($null -ne $eventPass) { $eventPass.Events['eventlog_6005'] } else { @() }) `
        -Events6006 $(if ($null -ne $eventPass) { $eventPass.Events['eventlog_6006'] } else { @() }) `
        -Events6008 $(if ($null -ne $eventPass) { $eventPass.Events['eventlog_6008'] } else { @() })

    # 10 - power, lighting, drivers and misc (RF-18..RF-20, RF-22..RF-25).
    if ($Mode -eq 'Full') {
        $s10 = Invoke-DiagStep -Index 10 -Total $total -Label 'Reading power, lighting and driver configuration' -Script {
            $kp = @()
            if ($null -ne $eventPass -and $null -ne $eventPass.Events -and $eventPass.Events.ContainsKey('kernel_power_41')) {
                $kp = @($eventPass.Events['kernel_power_41'])
            }
            [pscustomobject]@{
                Power    = (Get-DiagPower -KernelPowerEvents $kp)
                Lighting = (Get-DiagLighting)
                Drivers  = (Get-DiagDrivers)
                Misc     = (Get-DiagMisc -System $system)
            }
        }
        if ($null -ne $s10) {
            $power = $s10.Power
            $lighting = $s10.Lighting
            $drivers = $s10.Drivers
            $misc = $s10.Misc
        }
    } else {
        Add-DiagProblem -Collector 'drivers' -Reason 'skipped in Quick mode'
    }
    if ($null -eq $power) {
        $power = [pscustomobject]@{
            Available = $false; Reason = 'not collected'; FastStartup = 'unavailable (not collected)'
            FastStartupValue = $null; Pagefile = $null; BugcheckCodes = @()
        }
    }
    if ($null -eq $lighting) {
        $lighting = [pscustomobject]@{
            Available = $false; Reason = 'not collected'; DynamicLighting = 'unavailable (not collected)'
            DynamicLightingProbe = $null; Services = @(); StartupCommands = @(); ContentionFlag = $false
        }
    }
    if ($null -eq $drivers) {
        $drivers = [pscustomobject]@{ Available = $false; Reason = 'not collected'; OldestDrivers = @(); NoDriverDate = 0 }
    }
    if ($null -eq $misc) {
        $misc = [pscustomobject]@{ Available = $false; Reason = 'not collected'; Trim = 'unavailable (not collected)'; UptimeHours = $null; WindowsBuild = $null }
    }

    # 11 - Windows Update history (RF-21).
    if ($Mode -eq 'Full') {
        $update = Invoke-DiagStep -Index 11 -Total $total -Label 'Reading Windows Update history' -Script {
            Get-DiagUpdate
        }
    }
    if ($null -eq $update) {
        $update = [pscustomobject]@{ Available = $false; Reason = 'not collected'; LatestKbs = @(); Pending = $null; PendingState = 'unavailable (not collected)'; SearchDate = $null }
    }

    # 12 - dxdiag (RF-12). Full mode only: RF-04 forbids Quick mode from running
    # dxdiag at all (it would spend up to 90 s and write a .txt into OutputDir).
    # The step is dropped from the count when -SkipDxDiag is passed as well.
    if (-not $SkipDxDiag -and $Mode -eq 'Full') {
        $s12 = Invoke-DiagStep -Index 12 -Total $total -Label 'Running dxdiag (may take up to 90 s)' -Script {
            if ([string]::IsNullOrWhiteSpace($OutputDir)) {
                [pscustomobject]@{ Available = $false; Skipped = $true; State = 'unavailable (no output directory)'; Reason = 'no output directory'; KeyLines = @(); File = $null }
            } else {
                Get-DiagDxDiag -OutputDir $OutputDir -HostName $hostName -Stamp $stamp
            }
        }
        if ($null -ne $s12) { $dxdiag = $s12 }
    }
    if ($null -eq $dxdiag) {
        if ($SkipDxDiag) {
            $dxdiag = [pscustomobject]@{ Available = $false; Skipped = $true; State = 'skipped (-SkipDxDiag)'; Reason = 'skipped'; KeyLines = @(); File = $null }
        } elseif ($Mode -ne 'Full') {
            $dxdiag = [pscustomobject]@{ Available = $false; Skipped = $true; State = 'skipped (Quick mode)'; Reason = 'skipped in Quick mode'; KeyLines = @(); File = $null }
        } else {
            $dxdiag = [pscustomobject]@{ Available = $false; Skipped = $false; State = 'unavailable (collector failed)'; Reason = 'collector failed'; KeyLines = @(); File = $null }
        }
    }

    # -----------------------------------------------------------------------
    # Listings and their truncation metadata (RF-16). Truncation happens here,
    # not in the renderers, so the omitted count is available without a requery.
    # -----------------------------------------------------------------------
    $catalog = Get-DiagEventCatalog
    $listings = @{}
    $listingsMeta = @{}
    foreach ($row in $catalog) {
        $key = [string]$row.Key
        $rowEvents = @()
        if ($null -ne $eventPass -and $null -ne $eventPass.Events -and $eventPass.Events.ContainsKey($key)) {
            $rowEvents = @($eventPass.Events[$key])
        }
        $rowEvents = @($rowEvents | Sort-Object -Property @{ Expression = { $_.TimeCreated }; Descending = $true })
        if ($MaxEventsPerCategory -le 0) {
            $listings[$key] = @()
            $listingsMeta[$key] = @{ shown = 0; omitted = $rowEvents.Count; cap = 0 }
            continue
        }
        $shown = @($rowEvents | Select-Object -First $MaxEventsPerCategory)
        $listings[$key] = $shown
        $listingsMeta[$key] = @{ shown = $shown.Count; omitted = ($rowEvents.Count - $shown.Count); cap = $MaxEventsPerCategory }
    }

    # WER signatures are bounded to the same cap so state.json stays small. A cap
    # of 0 means "counts only" for the report, but the signature set is still
    # kept (up to a hard 1000) because the next run's delta needs it.
    $signatureCap = $MaxEventsPerCategory
    if ($signatureCap -le 0) { $signatureCap = 1000 }
    $signatureList = @($wer.signatures)
    if ($signatureList.Count -gt $signatureCap) {
        $signatureList = @($signatureList | Select-Object -First $signatureCap)
    }

    # WER delta: new signatures only, so a re-report of a known dump cannot raise
    # the crash delta (RF-29).
    $newSignatures = $null
    if ($baselineUsable -and $null -ne $Previous) {
        $previousSet = @{}
        $previousWer = Get-DiagPropValue -Object $Previous -Name 'wer' -Default $null
        if ($null -ne $previousWer) {
            foreach ($sig in @(Get-DiagPropValue -Object $previousWer -Name 'signatures' -Default @())) {
                if ($null -eq $sig) { continue }
                $sigKey = [string](Get-DiagPropValue -Object $sig -Name 'signature' -Default '')
                if (-not [string]::IsNullOrEmpty($sigKey)) { $previousSet[$sigKey] = $true }
            }
        }
        $newSignatures = 0
        foreach ($sig in $signatureList) {
            if ($null -eq $sig) { continue }
            if (-not $previousSet.ContainsKey([string]$sig.signature)) { $newSignatures = $newSignatures + 1 }
        }
    }

    $werObject = [pscustomobject]@{
        events_seen      = [int]$wer.events_seen
        unique_dumps     = [int]$wer.unique_dumps
        unique_params    = [int]$wer.unique_params
        unidentified     = [int]$wer.unidentified
        repeats          = [int]$wer.repeats
        signatures       = $signatureList
        new_signatures   = $newSignatures
        delta_available  = $baselineUsable
    }

    # Section-level skip bookkeeping (RF-27). Meta.SectionsSkipped and
    # problems[] carry the same facts, so a renderer never has to guess why a
    # section is empty.
    $skippedSections = New-Object System.Collections.ArrayList
    foreach ($problem in (Get-DiagProblems)) {
        if (-not $skippedSections.Contains($problem.Collector)) { [void]$skippedSections.Add($problem.Collector) }
    }

    $largestFolderMap = @{}
    $largestFileMap = @{}
    foreach ($mount in $scanMap.Keys) {
        $scan = $scanMap[$mount]
        $largestFolderMap[$mount] = @($scan.Folders)
        $largestFileMap[$mount] = @($scan.Files)
    }

    $meta = [pscustomobject]@{
        Timestamp           = (Get-DiagTimestamp -Date $startedAt)
        Host                = $hostName
        Mode                = $Mode
        WindowDays          = $Days
        WindowStart         = (Get-DiagTimestamp -Date $windowStart)
        Elevated            = $elevated
        Version             = $script:PcDiagVersion
        SectionsSkipped     = @($skippedSections.ToArray())
        OffProviderDropped  = (Get-DiagOffProviderDropped)
        OutputDir           = $OutputDir
        StatePath           = $StatePath
        Stamp               = $stamp
        BaselineUsable      = $baselineUsable
        BaselineReason      = $baselineReason
        PreviousLastRunAt   = $previousLastRun
        SkipDxDiag          = [bool]$SkipDxDiag
        EventBudgetSeconds  = $EventBudgetSeconds
    }

    $problems = Get-DiagProblems

    return [pscustomobject]@{
        meta            = $meta
        system          = $system
        cpu             = $cpu
        memory          = $memory
        gpu             = $gpu
        storage         = $disksSection
        volumes         = [pscustomobject]@{ Volumes = $volumes }
        largest_folders = $largestFolderMap
        largest_files   = $largestFileMap
        events          = [pscustomobject]@{
            Counters      = $(if ($null -ne $eventPass) { $eventPass.Counters } else { [ordered]@{} })
            Catalog       = $catalog
            Listings      = $listings
            ListingsMeta  = $listingsMeta
        }
        wer             = $werObject
        boots           = $boots
        power           = $power
        lighting        = $lighting
        update          = $update
        drivers         = $drivers
        misc            = $misc
        dxdiag          = $dxdiag
        problems        = [pscustomobject]@{ Problems = $problems }
    }
}
