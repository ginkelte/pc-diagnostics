# lib/State.ps1
#
# state.json contract (section 7): schema version 1, ISO 8601 timestamps with a
# local offset, invariant numbers, JSON null for every unavailable value, and
# every RF-13 catalog counter present even when it is 0 - a missing key makes the
# next delta silently wrong.
#
# Writes are atomic (state.json.tmp then a forced move) and confined to
# -OutputDir (RS-03). A corrupt or incompatible file is set aside, never
# partially read (EC-11).

$script:DiagStateSchemaVersion = 1

function Set-DiagStateAside {
    <#
      Moves an unreadable or incompatible state next to itself as
      state.json.corrupt-<yyyyMMdd-HHmmss>, prints exactly one warning and lets
      the caller continue as a first run (EC-11). Never throws.
    #>
    param([string]$Path, [string]$Reason = 'unreadable')

    $stamp = Get-DiagFileNameStamp
    $target = $Path + '.corrupt-' + $stamp
    $n = 2
    while ($true) {
        try {
            if (-not (Test-Path -LiteralPath $target)) {
                [System.IO.File]::Move($Path, $target)
                break
            }
        } catch {
            break
        }
        $target = $Path + '.corrupt-' + $stamp + '-' + [string]$n
        $n = $n + 1
        if ($n -gt 100) { break }
    }

    Write-Warning ('state file unusable (' + $Reason + '); previous state set aside as ' + [System.IO.Path]::GetFileName($target) + ', continuing as a first run.')
    return $null
}

function Test-DiagStateCompatible {
    <#
      Structural check. A syntactically valid file with a missing key is as
      unusable as a truncated one: a half-read baseline is worse than none.
    #>
    param($State)
    if ($null -eq $State) { return $false }
    $version = Get-DiagPropValue -Object $State -Name 'schema_version' -Default $null
    if ($null -eq $version) { return $false }
    if ([int]$version -ne $script:DiagStateSchemaVersion) { return $false }
    foreach ($required in @('last_run_at', 'last_run_mode', 'host', 'window_days', 'counters', 'wer', 'volumes')) {
        $value = Get-DiagPropValue -Object $State -Name $required -Default $null
        if ($null -eq $value) { return $false }
    }
    return $true
}

function Read-DiagState {
    <#
      Returns the parsed state object, or $null when the file is absent,
      unreadable, invalid JSON, structurally incomplete or of a different schema
      version. In the last three cases the file is set aside with one warning
      (RF-30, EC-11). Never throws.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $exists = $false
    try { $exists = Test-Path -LiteralPath $Path } catch { $exists = $false }
    if (-not $exists) { return $null }

    $text = $null
    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        return (Set-DiagStateAside -Path $Path -Reason (Get-DiagErrorText -ErrorRecord $_))
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return (Set-DiagStateAside -Path $Path -Reason 'file is empty')
    }

    $parsed = $null
    try {
        $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } catch {
        return (Set-DiagStateAside -Path $Path -Reason 'invalid JSON')
    }

    if (-not (Test-DiagStateCompatible -State $parsed)) {
        $version = Get-DiagPropValue -Object $parsed -Name 'schema_version' -Default 'none'
        return (Set-DiagStateAside -Path $Path -Reason ('incompatible schema_version ' + [string]$version))
    }

    return $parsed
}

function New-DiagState {
    <#
      Builds the version 1 state object from a snapshot. Every catalog counter is
      present; a counter whose query failed is null, never 0 (section 7.3).
    #>
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    $meta = $Snapshot.meta

    $counters = [ordered]@{}
    foreach ($row in (Get-DiagEventCatalog)) {
        $value = $null
        if ($null -ne $Snapshot.events -and $null -ne $Snapshot.events.Counters) {
            $entry = $null
            try { $entry = $Snapshot.events.Counters[$row.Key] } catch { $entry = $null }
            if ($null -ne $entry) {
                $total = $null
                if ($entry -is [System.Collections.IDictionary]) {
                    if ($entry.Contains('total')) { $total = $entry['total'] }
                } else {
                    $total = Get-DiagPropValue -Object $entry -Name 'total' -Default $null
                }
                if ($null -ne $total) { $value = [int]$total }
            }
        }
        $counters[$row.Key] = $value
    }

    $signatures = New-Object System.Collections.ArrayList
    if ($null -ne $Snapshot.wer) {
        foreach ($sig in @($Snapshot.wer.signatures)) {
            if ($null -eq $sig) { continue }
            $first = Get-DiagPropValue -Object $sig -Name 'first_seen' -Default $null
            $last = Get-DiagPropValue -Object $sig -Name 'last_seen' -Default $null
            $firstText = $null
            $lastText = $null
            if ($null -ne $first) { try { $firstText = Get-DiagTimestamp -Date ([datetime]$first) } catch { $firstText = $null } }
            if ($null -ne $last) { try { $lastText = Get-DiagTimestamp -Date ([datetime]$last) } catch { $lastText = $null } }
            [void]$signatures.Add([pscustomobject]@{
                signature  = [string]$sig.signature
                kind       = [string]$sig.kind
                count      = [int]$sig.count
                first_seen = $firstText
                last_seen  = $lastText
                app        = $(if ([string]::IsNullOrWhiteSpace([string]$sig.app)) { $null } else { [string]$sig.app })
            })
        }
    }

    $volumes = New-Object System.Collections.ArrayList
    if ($null -ne $Snapshot.volumes) {
        foreach ($v in @($Snapshot.volumes.Volumes)) {
            if ($null -eq $v) { continue }
            [void]$volumes.Add([pscustomobject]@{
                mount    = [string]$v.Mount
                free_pct = $(if ($null -ne $v.FreePct) { [double]$v.FreePct } else { $null })
                free_gb  = $(if ($null -ne $v.FreeGB) { [double]$v.FreeGB } else { 0.0 })
                size_gb  = $(if ($null -ne $v.SizeGB) { [double]$v.SizeGB } else { 0.0 })
            })
        }
    }

    $nvme = New-Object System.Collections.ArrayList
    if ($null -ne $Snapshot.storage) {
        foreach ($d in @($Snapshot.storage.Disks)) {
            if ($null -eq $d) { continue }
            if ($d.BusType -ne 'NVMe') { continue }
            $smart = $d.Smart
            [void]$nvme.Add([pscustomobject]@{
                model              = $(if ([string]::IsNullOrWhiteSpace([string]$d.FriendlyName)) { $null } else { [string]$d.FriendlyName })
                firmware           = $(if ([string]::IsNullOrWhiteSpace([string]$d.FirmwareVersion)) { $null } else { [string]$d.FirmwareVersion })
                temperature_c      = $(if ($null -ne $smart -and $null -ne $smart.TemperatureC) { [int]$smart.TemperatureC } else { $null })
                wear_pct           = $(if ($null -ne $smart -and $null -ne $smart.PercentageUsed) { [int]$smart.PercentageUsed } else { $null })
                media_errors       = $(if ($null -ne $smart -and $null -ne $smart.MediaErrors) { [long]$smart.MediaErrors } else { $null })
                unsafe_shutdowns   = $(if ($null -ne $smart -and $null -ne $smart.UnsafeShutdowns) { [long]$smart.UnsafeShutdowns } else { $null })
                power_on_hours     = $(if ($null -ne $smart -and $null -ne $smart.PowerOnHours) { [long]$smart.PowerOnHours } else { $null })
                critical_warning   = $(if ($null -ne $smart -and $null -ne $smart.CriticalWarning) { [int]$smart.CriticalWarning } else { $null })
                available_spare_pct = $(if ($null -ne $smart -and $null -ne $smart.AvailableSparePct) { [int]$smart.AvailableSparePct } else { $null })
            })
        }
    }

    $cleanBoots = 0
    $dirtyBoots = 0
    if ($null -ne $Snapshot.boots) {
        $c = Get-DiagPropValue -Object $Snapshot.boots -Name 'Clean' -Default 0
        $d = Get-DiagPropValue -Object $Snapshot.boots -Name 'Dirty' -Default 0
        if ($null -ne $c) { $cleanBoots = [int]$c }
        if ($null -ne $d) { $dirtyBoots = [int]$d }
    }

    $fastStartup = $null
    if ($null -ne $Snapshot.power) {
        $token = [string](Get-DiagPropValue -Object $Snapshot.power -Name 'FastStartup' -Default '')
        if ($token -eq 'enabled') { $fastStartup = $true }
        elseif ($token -eq 'disabled') { $fastStartup = $false }
    }

    $lighting = $null
    if ($null -ne $Snapshot.lighting) {
        $token = [string](Get-DiagPropValue -Object $Snapshot.lighting -Name 'DynamicLighting' -Default '')
        if ($token -eq 'enabled' -or $token -eq 'disabled' -or $token -eq 'not_present') { $lighting = $token }
    }

    $caption = ''
    $build = ''
    if ($null -ne $Snapshot.system) {
        $caption = [string](Get-DiagPropValue -Object $Snapshot.system -Name 'Caption' -Default '')
        $build = [string](Get-DiagPropValue -Object $Snapshot.system -Name 'Build' -Default '')
    }

    $lastRunAt = $null
    if ($null -ne $meta) { $lastRunAt = Get-DiagPropValue -Object $meta -Name 'Timestamp' -Default $null }
    if ([string]::IsNullOrWhiteSpace([string]$lastRunAt)) { $lastRunAt = Get-DiagTimestamp }

    $mode = 'Full'
    if ($null -ne $meta) { $mode = [string](Get-DiagPropValue -Object $meta -Name 'Mode' -Default 'Full') }

    $windowDays = 30
    if ($null -ne $meta) { $windowDays = [int](Get-DiagPropValue -Object $meta -Name 'WindowDays' -Default 30) }

    $elevated = $false
    if ($null -ne $meta) { $elevated = [bool](Get-DiagPropValue -Object $meta -Name 'Elevated' -Default $false) }

    $offProvider = 0
    if ($null -ne $meta) { $offProvider = [int](Get-DiagPropValue -Object $meta -Name 'OffProviderDropped' -Default 0) }

    $hostName = ''
    if ($null -ne $meta) { $hostName = [string](Get-DiagPropValue -Object $meta -Name 'Host' -Default '') }

    $werSeen = 0
    $werDumps = 0
    $werParams = 0
    $werUnidentified = 0
    $werRepeats = 0
    if ($null -ne $Snapshot.wer) {
        $werSeen = [int](Get-DiagPropValue -Object $Snapshot.wer -Name 'events_seen' -Default 0)
        $werDumps = [int](Get-DiagPropValue -Object $Snapshot.wer -Name 'unique_dumps' -Default 0)
        $werParams = [int](Get-DiagPropValue -Object $Snapshot.wer -Name 'unique_params' -Default 0)
        $werUnidentified = [int](Get-DiagPropValue -Object $Snapshot.wer -Name 'unidentified' -Default 0)
        $werRepeats = [int](Get-DiagPropValue -Object $Snapshot.wer -Name 'repeats' -Default 0)
    }

    return [pscustomobject]@{
        schema_version      = $script:DiagStateSchemaVersion
        last_run_at         = [string]$lastRunAt
        last_run_mode       = $mode
        host                = $hostName
        window_days         = $windowDays
        elevated            = $elevated
        off_provider_dropped = $offProvider
        counters            = $counters
        wer                 = [pscustomobject]@{
            events_seen   = $werSeen
            unique_dumps  = $werDumps
            unique_params = $werParams
            unidentified  = $werUnidentified
            repeats       = $werRepeats
            signatures    = @($signatures.ToArray())
        }
        volumes             = @($volumes.ToArray())
        nvme                = @($nvme.ToArray())
        boots               = [pscustomobject]@{ clean = $cleanBoots; dirty = $dirtyBoots }
        fast_startup        = $fastStartup
        dynamic_lighting    = $lighting
        windows             = [pscustomobject]@{ caption = $caption; build = $build }
    }
}

function Write-DiagState {
    <#
      Writes state.json atomically: state.json.tmp then a forced move over the
      target (RF-30). UTF-8 without a byte order mark, invariant numbers, JSON
      null for unavailable values. A write failure is non-fatal for the caller.
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $json = ConvertTo-Json -InputObject $State -Depth 10
    $tmp = $Path + '.tmp'
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $json, $encoding)
    Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
}

function Compare-DiagState {
    <#
      Compares the current snapshot with a previously persisted state.

        new_signatures  - WER signatures present now and absent before, so a
                          re-report of a known dump cannot raise the crash delta
                          (RF-29)
        since_last_run  - per-counter change between the two persisted totals

      The authoritative per-counter delta for the current run comes from
      Get-EventCounters, which counts events strictly newer than last_run_at in
      the same query pass as the totals (AD-05). This map is only for comparing
      two files, and is $null for any counter that is not a number in both.

      baseline_usable is false when the two states come from different hosts or
      the previous run is dated in the future; the caller additionally checks the
      window (EC-13).
    #>
    param($Current, $Previous)

    $sinceMap = [ordered]@{}
    $newValues = New-Object System.Collections.ArrayList
    $removed = 0

    if ($null -eq $Previous) {
        return [pscustomobject]@{
            new_signatures      = $null
            new_signature_values = @()
            removed_signatures  = $null
            since_last_run      = $sinceMap
            baseline_usable     = $false
            reason              = 'no previous state'
        }
    }

    # New signature set.
    $previousSignatures = @{}
    $previousWer = Get-DiagPropValue -Object $Previous -Name 'wer' -Default $null
    if ($null -ne $previousWer) {
        foreach ($sig in @(Get-DiagPropValue -Object $previousWer -Name 'signatures' -Default @())) {
            if ($null -eq $sig) { continue }
            $key = [string](Get-DiagPropValue -Object $sig -Name 'signature' -Default '')
            if (-not [string]::IsNullOrEmpty($key)) { $previousSignatures[$key] = $true }
        }
    }

    $currentSignatures = @{}
    $currentWer = Get-DiagPropValue -Object $Current -Name 'wer' -Default $null
    if ($null -ne $currentWer) {
        foreach ($sig in @(Get-DiagPropValue -Object $currentWer -Name 'signatures' -Default @())) {
            if ($null -eq $sig) { continue }
            $key = [string](Get-DiagPropValue -Object $sig -Name 'signature' -Default '')
            if ([string]::IsNullOrEmpty($key)) { continue }
            $currentSignatures[$key] = $true
            if (-not $previousSignatures.ContainsKey($key)) { [void]$newValues.Add($key) }
        }
    }
    foreach ($key in $previousSignatures.Keys) {
        if (-not $currentSignatures.ContainsKey($key)) { $removed = $removed + 1 }
    }

    # Per-counter change between the two files.
    $previousCounters = Get-DiagPropValue -Object $Previous -Name 'counters' -Default $null
    $currentCounters = Get-DiagPropValue -Object $Current -Name 'counters' -Default $null
    foreach ($row in (Get-DiagEventCatalog)) {
        $now = $null
        $before = $null
        if ($null -ne $currentCounters) {
            if ($currentCounters -is [System.Collections.IDictionary]) {
                if ($currentCounters.Contains($row.Key)) { $now = $currentCounters[$row.Key] }
            } else {
                $now = Get-DiagPropValue -Object $currentCounters -Name $row.Key -Default $null
            }
        }
        if ($null -ne $previousCounters) {
            if ($previousCounters -is [System.Collections.IDictionary]) {
                if ($previousCounters.Contains($row.Key)) { $before = $previousCounters[$row.Key] }
            } else {
                $before = Get-DiagPropValue -Object $previousCounters -Name $row.Key -Default $null
            }
        }
        if ($null -eq $now -or $null -eq $before) {
            $sinceMap[$row.Key] = $null
        } else {
            $sinceMap[$row.Key] = [int]$now - [int]$before
        }
    }

    $baselineUsable = $true
    $reason = $null

    $previousHost = [string](Get-DiagPropValue -Object $Previous -Name 'host' -Default '')
    $currentHost = [string](Get-DiagPropValue -Object $Current -Name 'host' -Default '')
    if (-not [string]::IsNullOrEmpty($previousHost) -and -not [string]::IsNullOrEmpty($currentHost) -and $previousHost -ne $currentHost) {
        $baselineUsable = $false
        $reason = 'host changed (' + $previousHost + ' -> ' + $currentHost + ')'
    }

    $lastRunText = Get-DiagPropValue -Object $Previous -Name 'last_run_at' -Default $null
    if (-not [string]::IsNullOrWhiteSpace([string]$lastRunText)) {
        try {
            $lastRun = [datetime]$lastRunText
            if ($lastRun -gt (Get-Date)) {
                $baselineUsable = $false
                $reason = 'previous last_run_at is in the future'
            }
        } catch {
            $baselineUsable = $false
            $reason = 'previous last_run_at is unparsable'
        }
    }

    return [pscustomobject]@{
        new_signatures       = $newValues.Count
        new_signature_values = @($newValues.ToArray())
        removed_signatures   = $removed
        since_last_run       = $sinceMap
        baseline_usable      = $baselineUsable
        reason               = $reason
    }
}
