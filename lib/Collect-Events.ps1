# lib/Collect-Events.ps1
#
# Event catalog, counters, boot classification and WER deduplication.
#
# This file owns the ONE constant catalog (RF-13). Every counter in the report,
# in state.json and in the quick table is derived from it; no other file builds
# an event filter. That is the structural fix for defect 1.2: a query that
# filters on an event Id without its provider is indistinguishable from a
# correct one when the queries are scattered, but a missing provider column in a
# single table is visible.
#
# Defect 1.3 is closed here too: WER Id 1001 events are reduced to a dump
# signature and reported as unique dumps / unique parameter signatures /
# unidentified / re-reports, as four separate numbers (RF-15).

# ---------------------------------------------------------------------------
# The event catalog (RF-13). Adding a category is a one-row change.
#   Key      - counter key used in the report, the state and the quick table
#   Log      - event log name
#   Provider - exact provider name, never a pattern
#   Ids      - one or more event Ids, always evaluated with the provider
#   Label    - human label used by the report; carries the provider name so a
#              bare "19: 317" cannot be printed, and states the WHEA severity
#              per Id. Id 18 is a FATAL hardware error; 17, 19 and 47 are the
#              corrected/correctable ones. An event that is fatal must never be
#              labelled corrected: that is the kind of misleading datum this
#              toolkit exists to avoid.
# ---------------------------------------------------------------------------
if ($null -eq $script:DiagEventCatalog) {
    $script:DiagEventCatalog = @(
        @{ Key = 'whea_17'; Log = 'System'; Provider = 'Microsoft-Windows-WHEA-Logger'; Ids = @(17); Label = 'WHEA 17 correctable error, PCIe AER (Microsoft-Windows-WHEA-Logger)' },
        @{ Key = 'whea_18'; Log = 'System'; Provider = 'Microsoft-Windows-WHEA-Logger'; Ids = @(18); Label = 'WHEA 18 FATAL hardware error (Microsoft-Windows-WHEA-Logger)' },
        @{ Key = 'whea_19'; Log = 'System'; Provider = 'Microsoft-Windows-WHEA-Logger'; Ids = @(19); Label = 'WHEA 19 corrected machine check (Microsoft-Windows-WHEA-Logger)' },
        @{ Key = 'whea_47'; Log = 'System'; Provider = 'Microsoft-Windows-WHEA-Logger'; Ids = @(47); Label = 'WHEA 47 corrected machine check, memory (Microsoft-Windows-WHEA-Logger)' },
        @{ Key = 'stornvme_129'; Log = 'System'; Provider = 'stornvme'; Ids = @(129); Label = 'NVMe controller reset (stornvme)' },
        @{ Key = 'disk_7'; Log = 'System'; Provider = 'disk'; Ids = @(7); Label = 'Bad block (disk)' },
        @{ Key = 'disk_11'; Log = 'System'; Provider = 'disk'; Ids = @(11); Label = 'Controller error (disk)' },
        @{ Key = 'disk_51'; Log = 'System'; Provider = 'disk'; Ids = @(51); Label = 'Paging I/O error (disk)' },
        @{ Key = 'disk_153'; Log = 'System'; Provider = 'disk'; Ids = @(153); Label = 'I/O retry (disk)' },
        @{ Key = 'tdr_4101'; Log = 'System'; Provider = 'Display'; Ids = @(4101); Label = 'Display driver reset (Display)' },
        @{ Key = 'tdr_4104'; Log = 'System'; Provider = 'Display'; Ids = @(4104); Label = 'Display driver recovery (Display)' },
        @{ Key = 'kernel_power_41'; Log = 'System'; Provider = 'Microsoft-Windows-Kernel-Power'; Ids = @(41); Label = 'Unexpected shutdown (Microsoft-Windows-Kernel-Power)' },
        @{ Key = 'eventlog_6005'; Log = 'System'; Provider = 'EventLog'; Ids = @(6005); Label = 'Event log service start (EventLog)' },
        @{ Key = 'eventlog_6006'; Log = 'System'; Provider = 'EventLog'; Ids = @(6006); Label = 'Event log service stop (EventLog)' },
        @{ Key = 'eventlog_6008'; Log = 'System'; Provider = 'EventLog'; Ids = @(6008); Label = 'Unexpected shutdown (EventLog)' },
        @{ Key = 'app_error_1000'; Log = 'Application'; Provider = 'Application Error'; Ids = @(1000); Label = 'Application crash (Application Error)' },
        @{ Key = 'wer_1001'; Log = 'Application'; Provider = 'Windows Error Reporting'; Ids = @(1001); Label = 'Windows Error Reporting bucket (Windows Error Reporting)' },
        @{ Key = 'app_hang_1002'; Log = 'Application'; Provider = 'Application Hang'; Ids = @(1002); Label = 'Application hang (Application Hang)' },
        @{ Key = 'dotnet_1026'; Log = 'Application'; Provider = '.NET Runtime'; Ids = @(1026); Label = 'Runtime error (.NET Runtime)' }
    )
}

function Get-DiagEventCatalog {
    <#
      The single source of truth for event categories. Returns one object per
      catalog row with Key, Log, Provider, Ids and Label.
    #>
    $rows = New-Object System.Collections.ArrayList
    foreach ($row in $script:DiagEventCatalog) {
        [void]$rows.Add([pscustomobject]@{
            Key      = [string]$row.Key
            Log      = [string]$row.Log
            Provider = [string]$row.Provider
            Ids      = @($row.Ids)
            Label    = [string]$row.Label
        })
    }
    return @($rows.ToArray())
}

function Get-DiagEventCatalogRow {
    param([string]$Key)
    foreach ($row in $script:DiagEventCatalog) {
        if ($row.Key -eq $Key) { return $row }
    }
    return $null
}

function Get-DiagQueryText {
    <#
      The audit line required by RF-13:
        query: LogName=System ProviderName=stornvme Id=129 since=2026-10-14T00:00:00
      Rendering it next to every count is what makes a zero attributable.
    #>
    param($Row, [datetime]$Since)
    $ids = @($Row.Ids) -join ','
    return 'query: LogName=' + $Row.Log + ' ProviderName=' + $Row.Provider + ' Id=' + $ids + ' since=' + $Since.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DiagEventPass {
    <#
      One query per catalog row, reused for totals, deltas and listings (RF-29:
      "no second query, no double counting").

      Total      - events in the whole window (Since = window start)
      Delta      - events strictly newer than -SinceLastRun, counted from the
                   same materialised set, and only when the baseline lies inside
                   the window (EC-13). Otherwise $null, which renders as "-".
      Unavailable- a failed query yields total = $null plus an Error string, so
                   the renderer prints "unavailable (<reason>)" and never 0.

      Budgets (RNF-01): a 10 s per-query and a 30 s total budget. Get-WinEvent
      cannot be interrupted mid-call, so the budget is enforced between queries:
      rows that would start after the budget is spent are recorded as
      unavailable (timeout) instead of starting.
    #>
    param(
        [Parameter(Mandatory = $true)][datetime]$Since,
        $SinceLastRun = $null,
        [int]$TotalBudgetSeconds = 30,
        [int]$QueryTimeoutSeconds = 10
    )

    $baselineUsable = $false
    $baselineTime = $null
    if ($null -ne $SinceLastRun) {
        try {
            $baselineTime = [datetime]$SinceLastRun
            if ($baselineTime -ge $Since) { $baselineUsable = $true }
        } catch {
            $baselineTime = $null
            $baselineUsable = $false
        }
    }

    $counters = [ordered]@{}
    $events = @{}
    $budget = New-Object System.Diagnostics.Stopwatch
    $budget.Start()

    foreach ($row in $script:DiagEventCatalog) {
        $key = [string]$row.Key
        $events[$key] = @()

        if ($budget.Elapsed.TotalSeconds -ge $TotalBudgetSeconds) {
            $counters[$key] = @{
                total          = $null
                since_last_run = $null
                error          = 'timeout'
            }
            Add-DiagProblem -Collector ('events:' + $key) -Reason ('timeout after ' + [string]$TotalBudgetSeconds + ' s')
            continue
        }

        $querySw = New-Object System.Diagnostics.Stopwatch
        $querySw.Start()
        try {
            $evs = @(Get-DiagEvent -LogName $row.Log -ProviderName $row.Provider -Id $row.Ids -Since $Since)
        } catch {
            $reason = Get-DiagErrorText -ErrorRecord $_
            $counters[$key] = @{
                total          = $null
                since_last_run = $null
                error          = $reason
            }
            Add-DiagProblem -Collector ('events:' + $key) -Reason $reason
            $querySw.Stop()
            continue
        }
        $querySw.Stop()

        if ($querySw.Elapsed.TotalSeconds -gt $QueryTimeoutSeconds) {
            # The query completed after its budget. The count is still real, so it
            # is kept, but the overrun is recorded instead of being hidden.
            Add-DiagProblem -Collector ('events:' + $key) -Reason ('query exceeded ' + [string]$QueryTimeoutSeconds + ' s budget')
        }

        $events[$key] = $evs
        $delta = $null
        if ($baselineUsable) {
            $delta = 0
            foreach ($ev in $evs) {
                $t = Get-DiagPropValue -Object $ev -Name 'TimeCreated' -Default $null
                if ($null -eq $t) { continue }
                if ([datetime]$t -gt $baselineTime) { $delta = $delta + 1 }
            }
        }
        $counters[$key] = @{
            total          = $evs.Count
            since_last_run = $delta
            error          = $null
        }
    }

    $budget.Stop()

    return [pscustomobject]@{
        Counters        = $counters
        Events          = $events
        BaselineUsable  = $baselineUsable
        BaselineTime    = $baselineTime
        WindowStart     = $Since
    }
}

function Get-EventCounters {
    <#
      Ordered counter map: counter_key -> @{ total; since_last_run; error }.
      total is $null when the query failed (renders as unavailable, never 0);
      since_last_run is $null when there is no usable baseline (renders as "-").
    #>
    param(
        [Parameter(Mandatory = $true)][datetime]$Since,
        $SinceLastRun = $null,
        [int]$TotalBudgetSeconds = 30
    )
    $pass = Get-DiagEventPass -Since $Since -SinceLastRun $SinceLastRun -TotalBudgetSeconds $TotalBudgetSeconds
    return $pass.Counters
}

# ---------------------------------------------------------------------------
# WER deduplication (RF-15, defect 1.3)
# ---------------------------------------------------------------------------

if ([string]::IsNullOrEmpty([string]$script:DiagWerDumpRegex)) {
    # The single permitted read of message text anywhere in the toolkit: a dump
    # path is not localised (EC-05). Case-insensitive, absolute path, .dmp suffix.
    $script:DiagWerDumpRegex = '(?i)[A-Z]:\\[^\r\n"]*?\.dmp\b'
}

function Get-WerSignature {
    <#
      Reduces one WER 1001 event to a signature by fixed precedence:
        dump   - last .dmp path in the message, lowercased and trimmed
        params - otherwise the non-empty P1..P10 EventData values, read by field
                 name and joined with "|" in numeric order
        none   - otherwise; the event has no usable signature
      Returns an object with Kind in dump|params|none and Value.
    #>
    param($Event)

    $kind = 'none'
    $value = $null

    $message = [string](Get-DiagPropValue -Object $Event -Name 'Message' -Default '')
    if (-not [string]::IsNullOrEmpty($message)) {
        $found = [regex]::Matches($message, $script:DiagWerDumpRegex)
        if ($found.Count -gt 0) {
            $last = $found[$found.Count - 1].Value
            $value = $last.Trim().ToLowerInvariant()
            $kind = 'dump'
        }
    }

    if ($kind -eq 'none') {
        $data = Get-DiagPropValue -Object $Event -Name 'Data' -Default $null
        if ($null -ne $data) {
            $parts = New-Object System.Collections.ArrayList
            $i = 1
            while ($i -le 10) {
                $fieldName = 'P' + [string]$i
                $v = $null
                if ($data -is [System.Collections.IDictionary]) {
                    if ($data.Contains($fieldName)) { $v = $data[$fieldName] }
                } else {
                    $p = $null
                    try { $p = $data.PSObject.Properties[$fieldName] } catch { $p = $null }
                    if ($null -ne $p) { $v = $p.Value }
                }
                if ($null -ne $v) {
                    $text = [string]$v
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        [void]$parts.Add($text.Trim())
                    }
                }
                $i = $i + 1
            }
            if ($parts.Count -gt 0) {
                $kind = 'params'
                $value = ($parts.ToArray() -join '|')
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        return [pscustomobject]@{ Kind = 'none'; Value = $null }
    }
    return [pscustomobject]@{ Kind = $kind; Value = $value }
}

function Get-WerSummary {
    <#
      Aggregates WER 1001 events into the five numbers that must never be merged
      (defect 1.3):
        events_seen   - every event in the window
        unique_dumps  - distinct dump-path signatures  <- the headline crash number
        unique_params - distinct P1..P10 signatures
        unidentified  - events with no usable signature (surfaced, never counted
                        as dumps)
        repeats       - events_seen - unique_dumps - unique_params - unidentified
      signatures[] is ordered by count descending, then signature ascending.
    #>
    param($Events)

    $list = @($Events)
    $groups = @{}
    $unidentified = 0

    foreach ($ev in $list) {
        if ($null -eq $ev) { continue }
        $sig = Get-WerSignature -Event $ev
        if ($sig.Kind -eq 'none') {
            $unidentified = $unidentified + 1
            continue
        }
        $groupKey = [string]$sig.Kind + '|' + [string]$sig.Value
        if (-not $groups.ContainsKey($groupKey)) {
            $groups[$groupKey] = [pscustomobject]@{
                signature  = [string]$sig.Value
                kind       = [string]$sig.Kind
                count      = 0
                first_seen = $null
                last_seen  = $null
                app        = $null
            }
        }
        $g = $groups[$groupKey]
        $g.count = $g.count + 1

        $t = Get-DiagPropValue -Object $ev -Name 'TimeCreated' -Default $null
        if ($null -ne $t) {
            $t = [datetime]$t
            if ($null -eq $g.first_seen -or $t -lt $g.first_seen) { $g.first_seen = $t }
            if ($null -eq $g.last_seen -or $t -gt $g.last_seen) { $g.last_seen = $t }
        }
        if ([string]::IsNullOrWhiteSpace([string]$g.app)) {
            $app = Get-DiagEventDataValue -Event $ev -Name 'AppName'
            if (-not [string]::IsNullOrWhiteSpace([string]$app)) { $g.app = [string]$app }
        }
    }

    $signatures = @($groups.Values | Sort-Object -Property @{ Expression = 'count'; Descending = $true }, @{ Expression = 'signature'; Descending = $false })

    $uniqueDumps = 0
    $uniqueParams = 0
    foreach ($s in $signatures) {
        if ($s.kind -eq 'dump') { $uniqueDumps = $uniqueDumps + 1 }
        if ($s.kind -eq 'params') { $uniqueParams = $uniqueParams + 1 }
    }

    $repeats = $list.Count - $uniqueDumps - $uniqueParams - $unidentified
    if ($repeats -lt 0) { $repeats = 0 }

    return [pscustomobject]@{
        events_seen   = $list.Count
        unique_dumps  = $uniqueDumps
        unique_params = $uniqueParams
        unidentified  = $unidentified
        repeats       = $repeats
        signatures    = $signatures
    }
}

# ---------------------------------------------------------------------------
# Boot classification (RF-17)
# ---------------------------------------------------------------------------

function Get-DiagBoots {
    <#
      Classifies EventLog 6005/6006/6008 events over the window, sorted
      ascending:
        6006 -> clean shutdown
        6008 -> dirty shutdown (unexpected)
        6005 -> clean boot when the immediately preceding event of the three Ids
                is a 6006, otherwise dirty boot (unclean start)

      Kind is one of clean|dirty|shutdown|unknown; Label carries the exact report
      text. Boot counts come from these events only, never from uptime and never
      from Kernel-Power 41 (RF-17).
    #>
    param($Events6005, $Events6006, $Events6008)

    $all = New-Object System.Collections.ArrayList
    foreach ($e in @($Events6005)) { if ($null -ne $e) { [void]$all.Add($e) } }
    foreach ($e in @($Events6006)) { if ($null -ne $e) { [void]$all.Add($e) } }
    foreach ($e in @($Events6008)) { if ($null -ne $e) { [void]$all.Add($e) } }

    $sorted = @($all.ToArray() | Sort-Object -Property @{ Expression = { $_.TimeCreated } })

    $entries = New-Object System.Collections.ArrayList
    $cleanBoots = 0
    $dirtyBoots = 0

    $i = 0
    while ($i -lt $sorted.Count) {
        $ev = $sorted[$i]
        $id = [int](Get-DiagPropValue -Object $ev -Name 'Id' -Default 0)
        $kind = 'unknown'
        $label = 'unknown'
        if ($id -eq 6006) {
            # Kind carries the clean/dirty dimension; Label carries the exact
            # report text, so "clean boot" and "clean shutdown" stay distinct.
            $kind = 'clean'
            $label = 'clean shutdown'
        } elseif ($id -eq 6008) {
            $kind = 'dirty'
            $label = 'dirty shutdown (unexpected)'
        } elseif ($id -eq 6005) {
            $previousId = 0
            if ($i -gt 0) {
                $previousId = [int](Get-DiagPropValue -Object $sorted[$i - 1] -Name 'Id' -Default 0)
            }
            if ($previousId -eq 6006) {
                $kind = 'clean'
                $label = 'clean boot'
                $cleanBoots = $cleanBoots + 1
            } else {
                $kind = 'dirty'
                $label = 'dirty boot (unclean start)'
                $dirtyBoots = $dirtyBoots + 1
            }
        }
        [void]$entries.Add([pscustomobject]@{
            TimeCreated  = (Get-DiagPropValue -Object $ev -Name 'TimeCreated' -Default $null)
            Id           = $id
            ProviderName = [string](Get-DiagPropValue -Object $ev -Name 'ProviderName' -Default 'EventLog')
            Kind         = $kind
            Label        = $label
        })
        $i = $i + 1
    }

    # Newest first for the report listing; counts cover the whole window.
    $newestFirst = @($entries.ToArray() | Sort-Object -Property @{ Expression = { $_.TimeCreated }; Descending = $true })

    return [pscustomobject]@{
        Entries = $newestFirst
        Clean   = $cleanBoots
        Dirty   = $dirtyBoots
    }
}
