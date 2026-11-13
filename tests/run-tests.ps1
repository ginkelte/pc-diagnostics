# tests/run-tests.ps1
#
# Self-contained test runner (RT-01). No Pester, no module, no network, no
# registry, no Windows: it runs on pwsh 7 on Linux because every Windows
# dependency is served by tests/stubs.ps1.
#
#   pwsh -File tests/run-tests.ps1                 # everything
#   pwsh -File tests/run-tests.ps1 -Filter T04     # a subset
#
# Output: one "PASS <name>" or "FAIL <name> :: <expected/actual>" line per test,
# then "TOTAL <n> PASSED <n> FAILED <n> DURATION <s>s". Exit 0 only when every
# test passed and the suite stayed inside its 60 s budget (RT-06).
#
# What the suite deliberately does NOT do:
#   * it never dot-sources Invoke-PcDiagnostics.ps1 (RT-02): the entry point
#     parses parameters, validates them and exits, which is not testable by
#     dot-sourcing and would run a real collection on import;
#   * it never calls a real Windows cmdlet (all of them are stubbed);
#   * it writes only inside a temporary directory it creates and deletes (RT-07).

[CmdletBinding()]
param(
    [string]$Filter = '',
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'

$script:TestsRoot = $PSScriptRoot
$script:RepoRoot = Split-Path -Parent -Path $PSScriptRoot
$script:SuiteStarted = Get-Date

function Write-Line {
    param([string]$Text = '')
    [Console]::Out.WriteLine([string]$Text)
}

# ---------------------------------------------------------------------------
# Load: library first (in the entry point's order), then stubs so a stub can
# shadow a library function such as Get-NvmeHealthLog, then the harness.
# ---------------------------------------------------------------------------
$script:LibFiles = @(
    'Common.ps1',
    'Collect-Hardware.ps1',
    'Collect-Storage.ps1',
    'Collect-Events.ps1',
    'Collect-Config.ps1',
    'State.ps1',
    'Report.ps1'
)

foreach ($name in $script:LibFiles) {
    $path = Join-Path -Path (Join-Path -Path $script:RepoRoot -ChildPath 'lib') -ChildPath $name
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Line ('FATAL: missing library file: ' + $path)
        exit 1
    }
    . $path
}

. (Join-Path -Path $PSScriptRoot -ChildPath 'asserts.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'stubs.ps1')
. (Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'fixtures') -ChildPath 'snapshot-builder.ps1')

# ---------------------------------------------------------------------------
# Temp workspace (RT-07): the only directory this suite writes to.
# ---------------------------------------------------------------------------
$script:TempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('pcdiag-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
[void](New-Item -ItemType Directory -Path $script:TempRoot -Force)

$script:TempCounter = 0
function New-TestTempDir {
    <#
      A fresh directory per test that needs one, so a state file left behind by
      one test cannot change the result of the next.
    #>
    $script:TempCounter = [int]$script:TempCounter + 1
    $path = Join-Path -Path $script:TempRoot -ChildPath ('case-' + [string]$script:TempCounter)
    [void](New-Item -ItemType Directory -Path $path -Force)
    return $path
}

function Reset-TestEnvironment {
    <#
      Order independence (RT-07): no fixture, no stub mode, no recorded call and
      no accumulated problem survives into the next test.
    #>
    Reset-PcDiagStubs
    Reset-DiagProblems
    Reset-DiagOffProviderDropped
    Set-DiagProgressSink -Sink { param($progressLine) }
}

# ===========================================================================
# RT-01 / RT-02 / RT-03 - the harness itself
# ===========================================================================

function Test-RunnerSelfContained {
    <#
      RT-01: the runner imports nothing, calls no Invoke-Pester, and does not
      dot-source the entry point. Read from disk rather than assumed.
    #>
    $runnerPath = Join-Path -Path $script:TestsRoot -ChildPath 'run-tests.ps1'
    Assert-True (Test-Path -LiteralPath $runnerPath) 'tests/run-tests.ps1 exists'

    # Comments are stripped first: the header of this very file explains what is
    # forbidden, and a scan that cannot tell a comment from a call would either
    # fail on documentation or force the documentation to lie. Both comment
    # shapes are removed - a <# #> block keeps its interior lines (they do not
    # start with #) and would otherwise be scanned as if it were code. The
    # forbidden tokens are assembled at run time so this check does not match
    # itself, and the failure messages do the same.
    $pesterToken = 'Invoke' + '-Pester'
    $entryToken = 'Invoke' + '-PcDiagnostics' + '.ps1'

    $suiteText = ''
    $callText = ''
    $scanned = 0
    foreach ($file in (Get-ChildItem -LiteralPath $script:TestsRoot -Filter '*.ps1' -File -Recurse)) {
        $raw = [System.IO.File]::ReadAllText($file.FullName)
        $noBlocks = [regex]::Replace($raw, '(?s)<#.*?#>', '')
        $codeLines = @()
        foreach ($line in ($noBlocks -split "`r?`n")) {
            if ($line.TrimStart().StartsWith('#')) { continue }
            $codeLines = $codeLines + @($line)
        }
        $scanned = $scanned + 1
        $fileCode = ($codeLines -join "`n")
        $suiteText = $suiteText + "`n" + $fileCode
        # The library defines the assertions; only the OTHER files can prove that
        # a test actually calls them (a definition would pass this check alone).
        if ($file.Name -ne 'asserts.ps1') { $callText = $callText + "`n" + $fileCode }
    }
    Assert-GreaterOrEqual $scanned 1 'the scan read the suite files from disk'
    Assert-NotMatch $callText ([regex]::Escape($pesterToken)) ('no suite file calls ' + $pesterToken)

    Assert-NotMatch $suiteText ([regex]::Escape($pesterToken)) ('no suite file calls ' + $pesterToken)
    Assert-NotMatch $suiteText '(?m)^\s*Import-Module\b' 'no suite file imports a module'
    Assert-NotMatch $suiteText ([regex]::Escape($entryToken)) 'no suite file references the entry point'

    # The harness must be its own: the assertions live in this repository, and a
    # test body (not a list of names) really calls every one of them. The needle
    # carries the trailing space of a call site, so the registry line below can
    # never satisfy it on its own.
    foreach ($assertion in @('Assert-Equal', 'Assert-True', 'Assert-Match', 'Assert-Null', 'Assert-Contains', 'Assert-Throws', 'Assert-LessOrEqual')) {
        Assert-GreaterOrEqual (@([regex]::Matches($callText, [regex]::Escape($assertion) + '\s')).Count) 1 ('the suite calls ' + $assertion)
    }
    Assert-True ($null -ne (Get-Command 'Assert-Equal' -ErrorAction SilentlyContinue)) 'Assert-Equal is defined'
    Assert-True ($null -ne (Get-Command 'Get-WinEvent' -CommandType Function -ErrorAction SilentlyContinue)) 'Get-WinEvent resolves to the stub function, not a cmdlet'
}

function Test-StubRecordsArguments {
    <#
      RT-03: the stub records HOW it was called (non-empty provider, non-empty Id
      array, a StartTime) and refuses an incomplete filter, mirroring RF-14.
    #>
    Reset-TestEnvironment
    $fixture = Set-PcDiagFixture -Name 'whea-mixed-system-log'
    $since = Get-TestFixtureSince -Fixture $fixture -LogName 'System'

    $events = @(Get-DiagEvent -LogName 'System' -ProviderName 'Microsoft-Windows-WHEA-Logger' -Id @(17) -Since $since)
    Assert-Equal 2 $events.Count 'the stub served the two WHEA 17 events'

    $call = Get-PcDiagLastCall -Cmdlet 'Get-WinEvent'
    Assert-NotNull $call 'the stub recorded the call'
    Assert-Equal 'System' $call.Arguments.LogName 'LogName is recorded'
    Assert-GreaterOrEqual (@($call.Arguments.ProviderName).Count) 1 'ProviderName is recorded'
    Assert-Equal 'Microsoft-Windows-WHEA-Logger' (@($call.Arguments.ProviderName)[0]) 'the exact provider name is recorded, not a pattern'
    Assert-GreaterOrEqual (@($call.Arguments.Id).Count) 1 'the Id array is recorded'
    Assert-NotNull $call.Arguments.StartTime 'StartTime is recorded'
    Assert-True ($call.Arguments.StartTime -is [datetime]) 'StartTime is a datetime, not a string'

    $missingProvider = {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = @(19); StartTime = (Get-Date).AddDays(-1) }
    }
    Assert-Throws -Script $missingProvider -Code 'STUB_PROVIDER_FILTER_REQUIRED' -Message 'a filter without a provider is rejected by the stub'

    $missingId = {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk'; StartTime = (Get-Date).AddDays(-1) }
    }
    Assert-Throws -Script $missingId -Code 'STUB_ID_FILTER_REQUIRED' -Message 'a filter without an Id is rejected by the stub'

    $missingSince = {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk'; Id = @(51) }
    }
    Assert-Throws -Script $missingSince -Code 'STUB_STARTTIME_FILTER_REQUIRED' -Message 'a filter without a StartTime is rejected by the stub'
}

# ===========================================================================
# Defect 1.2 - provider filter (the "317 false machine checks")
# ===========================================================================

function Test-T01WheaProviderFilter {
    <#
      T01-whea-provider-filter (RT-04, normative name).

      Fixture: System log with 2 real WHEA-Logger 17, 3 WindowsUpdateClient 19,
      2 TPM 18 and 1 disk 51. A filter on the Id alone counts 3 + 2 + 1 events
      that have nothing to do with WHEA; the provider column is what prevents it.
    #>
    Reset-TestEnvironment
    $fixture = Set-PcDiagFixture -Name 'whea-mixed-system-log'
    $since = Get-TestFixtureSince -Fixture $fixture -LogName 'System'

    $pass = Get-DiagEventPass -Since $since
    $counters = $pass.Counters

    Assert-Equal 2 (Get-TestCounterValue -Counters $counters -Key 'whea_17') 'whea_17 counts only Microsoft-Windows-WHEA-Logger 17'
    Assert-Equal 0 (Get-TestCounterValue -Counters $counters -Key 'whea_18') 'the two TPM 18 events are not WHEA 18'
    Assert-Equal 0 (Get-TestCounterValue -Counters $counters -Key 'whea_19') 'the three WindowsUpdateClient 19 events are not WHEA 19'
    Assert-Equal 0 (Get-TestCounterValue -Counters $counters -Key 'whea_47') 'no WHEA 47 event exists in the fixture'
    Assert-Equal 1 (Get-TestCounterValue -Counters $counters -Key 'disk_51') 'the disk 51 event is counted under its own provider'

    # The structural half of the fix: no counter is keyed by a bare event Id.
    $keys = @($counters.Keys)
    Assert-NotContains $keys '19' 'no counter is named after a bare Id'
    Assert-NotContains $keys '18' 'no counter is named after a bare Id'
    Assert-NotContains $keys '17' 'no counter is named after a bare Id'

    # No counter anywhere reports 3: that is the false positive the defect shipped.
    $threes = @()
    foreach ($key in $keys) {
        if ((Get-TestCounterValue -Counters $counters -Key $key) -eq 3) { $threes = $threes + @($key) }
    }
    Assert-Count $threes 0 'no counter reports 3, the count of WindowsUpdateClient 19 events'

    # Nothing was dropped after the fact: the filter did its job server-side.
    Assert-Equal 0 (Get-DiagOffProviderDropped) 'meta.off_provider_dropped is 0 (the source honoured the filter)'

    # And the query really carried the provider.
    $wheaCalls = @(Get-PcDiagCalls -Cmdlet 'Get-WinEvent' | Where-Object { @($_.Arguments.Id) -contains 17 })
    Assert-GreaterOrEqual $wheaCalls.Count 1 'the WHEA 17 query reached the event source'
    Assert-Equal 'Microsoft-Windows-WHEA-Logger' (@($wheaCalls[0].Arguments.ProviderName)[0]) 'the WHEA query carried the exact provider'
}

function Test-T02ProviderGuard {
    <#
      T02-provider-guard (RT-04, normative name): an Id-only or provider-only
      query is a programming error, not an empty result.
    #>
    Reset-TestEnvironment

    $noProvider = { Get-DiagEvent -LogName 'System' -Id @(19) -Since (Get-Date).AddDays(-30) }
    Assert-Throws -Script $noProvider -Code 'PROVIDER_FILTER_REQUIRED' -Message 'Get-DiagEvent without -ProviderName'

    $noId = { Get-DiagEvent -LogName 'System' -ProviderName 'disk' -Since (Get-Date).AddDays(-30) }
    Assert-Throws -Script $noId -Code 'ID_FILTER_REQUIRED' -Message 'Get-DiagEvent without -Id'

    $emptyProvider = { Get-DiagEvent -LogName 'System' -ProviderName '  ' -Id @(19) -Since (Get-Date).AddDays(-30) }
    Assert-Throws -Script $emptyProvider -Code 'PROVIDER_FILTER_REQUIRED' -Message 'a whitespace provider is not a provider'

    # The guard fires before the query, so a rejected call never reaches the source.
    Assert-Count @(Get-PcDiagCalls -Cmdlet 'Get-WinEvent') 0 'no event query was issued by a rejected call'
}

function Test-T03OffProviderDrop {
    <#
      T03-offprovider-drop (RT-04, normative name): when the source ignores the
      filter, the collector drops the off-provider events and counts them; the
      counter stays 0 instead of inheriting someone else's event.
    #>
    Reset-TestEnvironment
    $fixture = Set-PcDiagFixture -Name 'offprovider-source'
    $since = Get-TestFixtureSince -Fixture $fixture -LogName 'System'

    # A source that returns a WindowsUpdateClient 19 event for a stornvme 129 query.
    Set-PcDiagStubMode -Mode 'ignore-provider'
    $dropped = @(Get-DiagEvent -LogName 'System' -ProviderName 'stornvme' -Id @(129) -Since $since)
    Assert-Equal 0 $dropped.Count 'the off-provider event is not returned as a stornvme 129 event'
    Assert-Equal 1 (Get-DiagOffProviderDropped) 'the drop is counted, not hidden'

    # Same fixture, an honest source: the counter is a real, attributable zero.
    Reset-DiagOffProviderDropped
    Set-PcDiagStubMode -Mode 'normal'
    $pass = Get-DiagEventPass -Since $since
    Assert-Equal 0 (Get-TestCounterValue -Counters $pass.Counters -Key 'stornvme_129') 'stornvme_129 is 0 for this fixture'
}

# ===========================================================================
# Defect 1.3 - WER dedupe
# ===========================================================================

function Get-WerFromFixture {
    <#
      Runs the real pipeline: stub query -> Get-DiagEvent -> Get-WerSummary.
      Bypassing Get-DiagEvent would leave the EventData parsing untested, and the
      P1..P10 fallback depends on it.
    #>
    param([Parameter(Mandatory = $true)][string]$FixtureName)

    $fixture = Set-PcDiagFixture -Name $FixtureName
    $since = Get-TestFixtureSince -Fixture $fixture -LogName 'Application'
    $events = @(Get-DiagEvent -LogName 'Application' -ProviderName 'Windows Error Reporting' -Id @(1001) -Since $since)
    return (Get-WerSummary -Events $events)
}

function Get-SignatureByValue {
    param($Summary, [string]$Value)
    foreach ($signature in @($Summary.signatures)) {
        if ([string]$signature.signature -eq $Value) { return $signature }
    }
    return $null
}

function Test-T04WerDedupeDump {
    <#
      T04-wer-dedupe-dump (RT-04, normative name).

      Fixture: one .dmp path repeated 173 times plus 11 distinct dumps.
      events_seen = 173 + 11 = 184, unique_dumps = 1 + 11 = 12,
      repeats = 184 - 12 = 172 (the 172 re-reports of dump A).
    #>
    Reset-TestEnvironment
    $summary = Get-WerFromFixture -FixtureName 'wer-repeated-dump'

    Assert-Equal 184 $summary.events_seen 'every WER event in the window is seen: 173 + 11'
    Assert-Equal 12 $summary.unique_dumps 'unique_dumps: 12 (A plus 11 distinct dumps)'
    Assert-Equal 0 $summary.unique_params 'no event needed the P1..P10 fallback'
    Assert-Equal 0 $summary.unidentified 'every event carried a dump path'
    Assert-Equal 172 $summary.repeats 'repeats = events_seen - unique_dumps - unique_params - unidentified = 184 - 12'
    Assert-Equal 184 ([int]$summary.events_seen) 'no event was dropped in silence (173 + 11 = 184)'

    $top = @($summary.signatures)[0]
    Assert-Equal 173 $top.count 'the most repeated dump carries all 173 reports'
    Assert-Equal 'dump' $top.kind 'the signature kind is dump'
    Assert-Match $top.signature '\.dmp$' 'the signature is the dump path'
    Assert-Null (Get-SignatureByValue -Summary $summary -Value '') 'no empty signature exists'

    # The accounting identity: the four numbers must add up to the events seen.
    $sum = 0
    foreach ($signature in @($summary.signatures)) { $sum = $sum + [int]$signature.count }
    Assert-Equal 184 $sum 'the per-signature counts add up to events_seen'

    # Dump precedence: these events also carry P1..P10, and must still group by dump.
    $withParams = @($summary.signatures | Where-Object { $_.kind -eq 'params' })
    Assert-Count $withParams 0 'a dump path wins over the P fields'
}

function Test-T04bWerDedupeMatrix {
    <#
      T04b: the RT-04 matrix shape (A x173, B x2, C x1, D x1) so the normative
      numbers of the specification are asserted as well as the 11-distinct case.
    #>
    Reset-TestEnvironment
    $summary = Get-WerFromFixture -FixtureName 'wer-repeated-dump-matrix'

    Assert-Equal 177 $summary.events_seen 'events_seen = 173 + 2 + 1 + 1'
    Assert-Equal 4 $summary.unique_dumps 'unique_dumps = 4'
    Assert-Equal 173 $summary.repeats 'repeats = 177 - 4'
    Assert-Equal 0 $summary.unidentified 'no unidentified event'
    Assert-Equal 173 (@($summary.signatures)[0]).count 'dump A carries 173 reports'
}

function Test-T05WerParamsFallback {
    <#
      T05-wer-params-fallback (RT-04, normative name): no dump path, so the
      signature is the P1..P10 values; two distinct groups, six events.
    #>
    Reset-TestEnvironment
    $summary = Get-WerFromFixture -FixtureName 'wer-params-only'

    Assert-Equal 6 $summary.events_seen 'six WER events'
    Assert-Equal 0 $summary.unique_dumps 'no dump path exists in this fixture'
    Assert-Equal 2 $summary.unique_params 'two distinct P1..P10 signatures'
    Assert-Equal 4 $summary.repeats 'repeats = events_seen - unique_params = 6 - 2'
    Assert-Equal 0 $summary.unidentified 'a P1..P10 signature is a usable signature'

    foreach ($signature in @($summary.signatures)) {
        Assert-Equal 'params' $signature.kind 'the fallback kind is params'
        Assert-NotMatch $signature.signature '\.dmp' 'a params signature is not a dump path'
        Assert-Match $signature.signature 'alpha\.exe|beta\.exe' 'the signature starts with P1'
    }
    Assert-Equal 4 (@($summary.signatures)[0]).count 'the dominant group has four reports'
}

function Test-T06WerUnidentified {
    <#
      T06-wer-unidentified (RT-04, normative name): an event with neither a dump
      path nor a P field is counted as unidentified - surfaced, never dropped and
      never counted as a crash.
    #>
    Reset-TestEnvironment
    $summary = Get-WerFromFixture -FixtureName 'wer-no-signature'

    Assert-Equal 3 $summary.events_seen 'three WER events'
    Assert-Equal 0 $summary.unique_dumps 'no dump'
    Assert-Equal 0 $summary.unique_params 'no params'
    Assert-Equal 3 $summary.unidentified 'all three are unidentified'
    Assert-Equal 0 $summary.repeats 'an unidentified event is not a re-report'
    Assert-Count @($summary.signatures) 0 'no signature object is fabricated for an unidentified event'
}

function Test-T06bWerAccounting {
    <#
      The invariant that ties the three buckets together on a mixed set: nothing
      is lost and nothing is double counted.
    #>
    Reset-TestEnvironment
    $summary = Get-WerFromFixture -FixtureName 'wer-mixed-signatures'

    Assert-Equal 5 $summary.events_seen 'five events'
    Assert-Equal 1 $summary.unique_dumps 'one dump signature'
    Assert-Equal 1 $summary.unique_params 'one params signature'
    Assert-Equal 1 $summary.unidentified 'one unidentified event' 
    Assert-Equal 2 $summary.repeats 'repeats = 5 - 1 - 1 - 1'
    Assert-Equal $summary.events_seen ([int]$summary.unique_dumps + [int]$summary.unique_params + [int]$summary.unidentified + [int]$summary.repeats) 'the four numbers add up to events_seen'
}

function Test-T07ListingCapAndSize {
    <#
      T07-listing-cap-and-size (RT-04, normative name; RT-06): 10,000 WER events
      across 4 signatures, default -MaxEventsPerCategory = 20. The report must
      stay under 512 KiB, list at most 20 events per category and state how many
      it omitted.
    #>
    Reset-TestEnvironment
    $events = @(New-TestWerEvents -Count 10000 -SignatureCount 4)
    Assert-Equal 10000 $events.Count 'the generator produced 10,000 events'

    $summary = Get-WerSummary -Events $events
    Assert-Equal 4 $summary.unique_dumps 'four dump signatures'
    Assert-Equal 9996 $summary.repeats 'repeats = 10000 - 4'

    $counters = New-TestCounters -Values @{ wer_1001 = @{ total = 10000; since_last_run = $null; error = $null } }
    $listings = @{ wer_1001 = @($events | Select-Object -First 20) }
    $listingsMeta = @{ wer_1001 = @{ shown = 20; omitted = 9980; cap = 20 } }

    $snapshot = New-TestSnapshot -Full -Counters $counters -Listings $listings -ListingsMeta $listingsMeta -Wer $summary
    $lines = @(New-FullReport -Snapshot $snapshot -Path 'C:\temp\reports\pc-diagnostics-test-host.txt')
    Assert-GreaterOrEqual $lines.Count 20 'the report has content'

    # Byte size, not line count: RT-06 is explicit about that.
    $text = ($lines -join "`r`n") + "`r`n"
    $bytes = [System.Text.Encoding]::UTF8.GetByteCount($text)
    Assert-LessOrEqual $bytes 524288 ('the report is ' + [string]$bytes + ' bytes')

    $section = @(Get-DiagReportSection07 -Snapshot $snapshot)
    $listingLines = @($section | Where-Object { $_ -match '^      \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}  Windows Error Reporting  1001 ' })
    Assert-LessOrEqual $listingLines.Count 20 'at most 20 WER listing lines'
    Assert-Equal 20 $listingLines.Count 'exactly the cap is listed'
    # $section is a list of lines, so it has to be joined before a substring
    # assertion: Assert-Contains does exact membership on a collection and
    # ordinal substring search on a string, by design.
    $sectionText = ($section -join "`n")
    Assert-Contains $sectionText '      ... 9980 more not listed (see counts above)' 'the omitted count is stated'
    Assert-Match $sectionText '(?m)^\s+wer_1001\s+Windows Error Reporting 1001\s+total=10000\s+since_last_run=-$' 'the total still reports all 10,000 events, not the 20 that were listed'

    # The 10,000-event set also has to fit the dedupe step, not only the renderer.
    Assert-Equal 20 (@($snapshot.events.Listings['wer_1001']).Count) 'the snapshot holds only the capped listing'
}

# ===========================================================================
# Renderers (RF-27, RF-16, RF-28)
# ===========================================================================

function Test-T10UnavailableNotZero {
    <#
      A counter that could not be read renders "unavailable", never 0 (RF-27).
      This is the same class of defect as the false machine-check count: a 0 that
      means "not measured" is a lie.
    #>
    Reset-TestEnvironment

    Assert-Match (Format-DiagReportNumber -Value $null -Reason 'no health log') '^unavailable \(no health log\)$' 'a null number is unavailable'
    Assert-NotEqual '0' (Format-DiagReportNumber -Value $null) 'a null number is never 0'
    Assert-Equal '0' (Format-DiagReportNumber -Value 0 -Decimals 0) 'a real zero is still 0'

    $counters = New-TestCounters -Values @{ whea_17 = @{ total = $null; since_last_run = $null; error = 'access denied' } }
    $snapshot = New-TestSnapshot -Counters $counters

    $section = @(Get-DiagReportSection07 -Snapshot $snapshot)
    $wheaLine = @($section | Where-Object { $_ -match '^\s+whea_17\s+' })
    Assert-Count $wheaLine 1 'the whea_17 counter line exists'
    Assert-Match $wheaLine[0] 'total=unavailable \(access denied\)' 'a failed query renders unavailable with its reason'
    Assert-NotMatch $wheaLine[0] 'total=0\b' 'a failed query does not render 0'
    Assert-Match $wheaLine[0] 'since_last_run=-' 'an unknown delta renders -, not +0'

    # NVMe fields with no health log: unavailable per field, and null in state.
    $disk = New-TestDisk -Number 0 -FriendlyName 'Test NVMe Device' -Smart $null
    $nvmeSnapshot = New-TestSnapshot -Disks @($disk) -StorageAvailable
    $storageSection = @(Get-DiagReportSection04 -Snapshot $nvmeSnapshot)
    $joined = ($storageSection -join "`n")
    Assert-Match $joined 'NVMe temperature\s+: unavailable \(no NVMe health log\)' 'a missing health log is named as the reason'
    Assert-NotMatch $joined 'NVMe temperature\s+: 0\b' 'a missing health log does not render 0'

    $state = New-DiagState -Snapshot $nvmeSnapshot -StatePath 'C:\temp\reports\state.json'
    Assert-Null $state.nvme[0].temperature_c 'state.json stores null for an unread temperature'
    Assert-Null $state.nvme[0].wear_pct 'state.json stores null for an unread wear value'
    Assert-Equal 0 $state.counters['whea_18'] 'a successful query with no event stores a real 0'
}

function Test-T11ListingTruncation {
    <#
      RF-16: a truncated listing prints the exact omitted count, and a zero count
      prints no listing at all.
    #>
    Reset-TestEnvironment

    $events = @(New-TestWerEvents -Count 250 -SignatureCount 2)
    $listings = @{ wer_1001 = @($events | Select-Object -First 20) }
    $listingsMeta = @{ wer_1001 = @{ shown = 20; omitted = 230; cap = 20 } }
    $snapshot = New-TestSnapshot -Listings $listings -ListingsMeta $listingsMeta

    $section = @(Get-DiagReportSection07 -Snapshot $snapshot)
    $listingLines = @($section | Where-Object { $_ -match '^      \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}  ' })
    Assert-Equal 20 $listingLines.Count 'twenty listing lines are printed'
    # Joined first: Assert-Contains is exact membership on a collection and an
    # ordinal substring search only on a string, and $section is a list of lines.
    $sectionText = ($section -join "`n")
    Assert-Contains $sectionText '      ... 230 more not listed (see counts above)' 'the overflow line carries the exact count'

    # Counts-only mode (cap 0): no listing lines, not even an overflow line.
    $zeroMeta = @{ wer_1001 = @{ shown = 0; omitted = 250; cap = 0 } }
    $zeroSnapshot = New-TestSnapshot -ListingsMeta $zeroMeta
    $zeroSection = @(Get-DiagReportSection07 -Snapshot $zeroSnapshot)
    $zeroText = ($zeroSection -join "`n")
    Assert-Match $zeroText '(?m)^\s+wer_1001\s+Windows Error Reporting 1001\s+total=0\s+since_last_run=-$' 'the counter is still printed in counts-only mode'
    Assert-Equal 0 (@($zeroSection | Where-Object { $_ -match '^      \d{4}-\d{2}-\d{2} ' }).Count) 'counts-only mode prints no listing line'
    Assert-NotMatch $zeroText 'more not listed' 'counts-only mode prints no overflow line either'

    # A missing listing metadata is stated, never silently skipped.
    $noMeta = New-TestSnapshot
    $noMeta.events.ListingsMeta = @{}
    $noMetaSection = @(Get-DiagReportSection07 -Snapshot $noMeta)
    Assert-Contains ($noMetaSection -join "`n") 'listing: unavailable (no listing metadata)' 'missing metadata is stated'
}

function Test-T12QuickCeiling {
    <#
      RF-28: the quick table never exceeds 24 lines, even with ten volumes and ten
      NVMe devices, and the state path is always the last line.
    #>
    Reset-TestEnvironment

    $volumes = @()
    $i = 0
    while ($i -lt 10) {
        $letter = [string][char](67 + $i)
        $volumes = $volumes + @(New-TestVolume -Mount ($letter + ':\') -FreePct (12.0 + $i) -FreeGB (100.0 + $i) -SizeGB 900.0)
        $i = $i + 1
    }
    $disks = @()
    $i = 0
    while ($i -lt 10) {
        $disks = $disks + @(New-TestDisk -Number $i -FriendlyName ('Test NVMe ' + [string]$i) -Smart (New-TestSmart))
        $i = $i + 1
    }

    $snapshot = New-TestSnapshot -Volumes $volumes -Disks $disks -StorageAvailable -StatePath 'C:\temp\reports\state.json'
    $lines = @(Format-QuickReport -Snapshot $snapshot -Previous $null)

    Assert-LessOrEqual $lines.Count 24 ('the quick table is ' + [string]$lines.Count + ' lines')
    Assert-Match $lines[$lines.Count - 1] '^state: ' 'the last line is the state path'
    Assert-Contains $lines 'baseline: none (first run)' 'a first run says so'

    $volumeLines = @($lines | Where-Object { $_ -match '^[A-Z]: \d' })
    Assert-LessOrEqual $volumeLines.Count 3 'the volume block keeps at most three device lines plus the marker'
    Assert-Contains $lines '+ 7 more volumes not listed' 'the volume overflow is stated'
    Assert-Contains $lines '+ 7 more NVMe devices not listed' 'the NVMe overflow is stated'

    # The ten fixed rows are all present and in order.
    $labels = @('stornvme 129 (device reset)', 'disk 51 (paging error)', 'WHEA 17 (PCIe AER corrected)', 'WHEA 18 fatal, 19/47 corrected', 'Kernel-Power 41 (bugcheck)', 'EventLog 6008 (dirty shutdown)', 'App Error 1000', 'App Hang 1002', 'WER unique dumps', 'WER re-reports')
    foreach ($label in $labels) {
        $found = @($lines | Where-Object { $_.StartsWith($label) })
        Assert-Count $found 1 ('the quick table has the row ' + $label)
    }
}

function Test-T12bQuickNeverRunsDxDiag {
    <#
      RF-04: Quick mode writes only state.json, so it must not run dxdiag at all
      (90 s and a stray dxdiag-<host>-<stamp>.txt in OutputDir). The guard is on
      $Mode, not only on -SkipDxDiag: both modes run the real collection
      function, Start-Process is the stub that records a launch, and the progress
      sink records which steps actually existed.
    #>
    Reset-TestEnvironment
    Set-PcDiagFixture -Name 'whea-mixed-system-log' | Out-Null

    $script:PcDiagTestStepLines = New-Object System.Collections.ArrayList
    Set-DiagProgressSink -Sink { param($progressLine) [void]$script:PcDiagTestStepLines.Add([string]$progressLine) }

    $quickDir = New-TestTempDir
    $quick = New-DiagSnapshot -Days 30 -TopFolders 3 -MaxEventsPerCategory 20 -Mode Quick `
        -OutputDir $quickDir -StatePath (Join-Path -Path $quickDir -ChildPath 'state.json')
    $quickLines = @($script:PcDiagTestStepLines.ToArray())

    Assert-Count @(Get-PcDiagCalls -Cmdlet 'Start-Process') 0 'Quick mode never launches a process (dxdiag)'
    Assert-Count @(Get-ChildItem -LiteralPath $quickDir -Filter 'dxdiag-*' -File -Recurse -ErrorAction SilentlyContinue) 0 'Quick mode writes no dxdiag artifact'
    Assert-Count @($quickLines | Where-Object { $_ -match 'dxdiag' }) 0 'Quick mode has no dxdiag step at all'
    Assert-NotNull $quick.dxdiag 'the snapshot still carries a dxdiag block'
    Assert-True $quick.dxdiag.Skipped 'the Quick-mode dxdiag block is marked skipped, not failed'
    Assert-Equal 'skipped (Quick mode)' $quick.dxdiag.State 'the skip names its cause instead of blaming a collector failure'

    # Control: Full mode does have the step and does reach the collector. Without
    # this the assertions above would also pass on a build where dxdiag was
    # removed outright.
    Reset-PcDiagStubs
    Set-PcDiagFixture -Name 'whea-mixed-system-log' | Out-Null
    $null = $script:PcDiagTestStepLines.Clear()
    $fullDir = New-TestTempDir
    $full = New-DiagSnapshot -Days 30 -TopFolders 3 -MaxEventsPerCategory 20 -Mode Full `
        -OutputDir $fullDir -StatePath (Join-Path -Path $fullDir -ChildPath 'state.json') -FolderBudgetSeconds 2
    $fullLines = @($script:PcDiagTestStepLines.ToArray())

    Assert-Count @($fullLines | Where-Object { $_ -match 'Running dxdiag' }) 1 'Full mode runs the dxdiag step'
    Assert-Match $full.dxdiag.State '^unavailable \(' 'Full mode reaches the collector (which degrades on a host without dxdiag.exe)'
    Assert-NotEqual 'skipped (Quick mode)' $full.dxdiag.State 'Full mode is not reported as a Quick-mode skip'
}

function Test-T13BaselineOutOfWindow {
    <#
      EC-13 / RF-29: a previous run older than the window is not a baseline. The
      line names the date and no delta is fabricated from it.
    #>
    Reset-TestEnvironment

    $windowStart = (Get-Date).Date.AddDays(-30)
    $snapshot = New-TestSnapshot -WindowDays 30 -WindowStart $windowStart
    $oldRun = (Get-Date).AddDays(-100)
    $previous = [pscustomobject]@{
        schema_version = 1
        host           = 'TEST-HOST'
        last_run_at    = (Get-DiagTimestamp -Date $oldRun)
        counters       = (New-TestCounters)
    }

    $baseline = Get-DiagReportBaseline -Snapshot $snapshot -Previous $previous
    Assert-False $baseline.usable 'an out-of-window baseline is not usable'
    Assert-Match $baseline.text ('^baseline: out of window \(' + $oldRun.ToString('yyyy-MM-dd HH:mm') + '\)$') 'the line names the out-of-window date'

    $lines = @(Format-QuickReport -Snapshot $snapshot -Previous $previous)
    Assert-Contains $lines $baseline.text 'the quick table prints that baseline line'
    $rowLine = @($lines | Where-Object { $_.StartsWith('stornvme 129 (device reset)') })
    Assert-Count $rowLine 1 'the first row is printed'
    # The delta column is separated from the total by a variable amount of
    # padding, so anchor on the column value rather than on a fixed indent.
    Assert-Match $rowLine[0] '  0\s+-$' 'the row reads "0 -" without a usable baseline'
    Assert-NotMatch $rowLine[0] '\+\d' 'no delta is fabricated from an out-of-window baseline'

    # A usable baseline inside the window still works (regression guard).
    $recent = [pscustomobject]@{ schema_version = 1; host = 'TEST-HOST'; last_run_at = (Get-DiagTimestamp -Date ((Get-Date).AddHours(-24))); counters = (New-TestCounters) }
    $recentBaseline = Get-DiagReportBaseline -Snapshot $snapshot -Previous $recent
    Assert-True $recentBaseline.usable 'a run inside the window is usable'
    Assert-Match $recentBaseline.text '^baseline: \d{4}-\d{2}-\d{2} \d{2}:\d{2} \(2[34]\.\d h ago\)$' 'the age is rendered'
}

function Test-T14WheaSeverityLabels {
    <#
      The label defect: WHEA 18 is a FATAL hardware error, not a corrected one.
      The catalog and the quick table must both say so, because a fatal error
      labelled corrected is exactly the misleading datum this toolkit exists to
      prevent.
    #>
    Reset-TestEnvironment

    $catalog = Get-DiagEventCatalog
    $row17 = @($catalog | Where-Object { $_.Key -eq 'whea_17' })
    $row18 = @($catalog | Where-Object { $_.Key -eq 'whea_18' })
    $row19 = @($catalog | Where-Object { $_.Key -eq 'whea_19' })
    $row47 = @($catalog | Where-Object { $_.Key -eq 'whea_47' })

    Assert-Count $row17 1 'the whea_17 row exists'
    Assert-Count $row18 1 'the whea_18 row exists'
    Assert-Count $row19 1 'the whea_19 row exists'
    Assert-Count $row47 1 'the whea_47 row exists'

    Assert-Match $row17[0].Label 'correctable' 'WHEA 17 is a correctable error'
    Assert-Match $row17[0].Label 'PCIe' 'WHEA 17 is the PCIe AER error'

    Assert-Match $row18[0].Label 'FATAL' 'WHEA 18 is labelled FATAL'
    Assert-NotMatch $row18[0].Label '(?i)corrected|correctable' 'WHEA 18 is never labelled corrected'

    Assert-Match $row19[0].Label 'corrected machine check' 'WHEA 19 is a corrected machine check'
    Assert-Match $row47[0].Label 'corrected machine check' 'WHEA 47 is a corrected machine check'
    Assert-Match $row47[0].Label 'memory' 'WHEA 47 is the memory-level corrected error'

    foreach ($row in @($row17[0], $row18[0], $row19[0], $row47[0])) {
        Assert-Contains $row.Label 'Microsoft-Windows-WHEA-Logger' 'every WHEA label carries its provider'
    }

    # Section 07 prints the label under its counter line.
    $counters = New-TestCounters -Values @{ whea_18 = @{ total = 1; since_last_run = $null; error = $null } }
    $snapshot = New-TestSnapshot -Counters $counters
    $section = @(Get-DiagReportSection07 -Snapshot $snapshot)
    $wheaLine = @($section | Where-Object { $_ -match '^\s+whea_18\s+' })
    Assert-Count $wheaLine 1 'the whea_18 counter line exists'
    Assert-Contains $wheaLine[0] 'total=1' 'the fatal event is counted'
    $labelLine = @($section | Where-Object { $_ -match '^\s+label: WHEA 18 ' })
    Assert-Count $labelLine 1 'the whea_18 label line exists'
    Assert-Match $labelLine[0] 'FATAL' 'the rendered label says FATAL'

    # And the quick table row must not claim everything in it is corrected.
    $quickLines = @(Format-QuickReport -Snapshot $snapshot -Previous $null)
    $row = @($quickLines | Where-Object { $_.StartsWith('WHEA 18') })
    Assert-Count $row 1 'the quick table has the WHEA 18 row'
    Assert-Match $row[0] '(?i)fatal' 'the quick row says fatal'
    Assert-NotMatch $row[0] '^WHEA 18/19/47 \(corrected\)' 'the quick row no longer labels a fatal error as corrected'
}

function Test-T15LocaleIndependent {
    <#
      EC-05: classification uses log name, provider name, event Id and EventData
      field names only. The Spanish fixture has the same providers and Ids as the
      English one, so every counter must be identical.
    #>
    Reset-TestEnvironment

    $english = Set-PcDiagFixture -Name 'whea-mixed-system-log'
    $englishSince = Get-TestFixtureSince -Fixture $english -LogName 'System'
    $englishPass = Get-DiagEventPass -Since $englishSince

    Reset-TestEnvironment
    $spanish = Set-PcDiagFixture -Name 'whea-spanish-messages'
    $spanishSince = Get-TestFixtureSince -Fixture $spanish -LogName 'System'
    $spanishPass = Get-DiagEventPass -Since $spanishSince

    foreach ($row in (Get-DiagEventCatalog)) {
        $key = [string]$row.Key
        Assert-Equal (Get-TestCounterValue -Counters $englishPass.Counters -Key $key) (Get-TestCounterValue -Counters $spanishPass.Counters -Key $key) ('counter ' + $key + ' is identical in both locales')
    }
    Assert-Equal 2 (Get-TestCounterValue -Counters $spanishPass.Counters -Key 'whea_17') 'the Spanish fixture is not empty'
}

# ===========================================================================
# State (section 7, EC-11, EC-13)
# ===========================================================================

function Test-T20StateRoundTripEmptyVolumes {
    <#
      write -> read with volumes[] empty must be accepted. The value test that
      used to live in Test-DiagStateCompatible rejected a state this very build
      wrote, because PowerShell unrolls an empty collection on a property read:
      presence of the key, not truthiness of the value, is the contract.
    #>
    Reset-TestEnvironment
    $dir = New-TestTempDir
    $path = Join-Path -Path $dir -ChildPath 'state.json'

    $snapshot = New-TestSnapshot
    $state = New-DiagState -Snapshot $snapshot -StatePath $path
    Assert-Count @($state.volumes) 0 'the snapshot has no volume'
    Assert-Count @($state.nvme) 0 'the snapshot has no NVMe disk'

    Write-DiagState -State $state -Path $path
    $text = Get-Content -LiteralPath $path -Raw
    Assert-Match $text '"volumes": \[\]' 'an empty volumes array is written as []'
    Assert-Match $text '"nvme": \[\]' 'an empty nvme array is written as []'

    $read = Read-DiagState -Path $path
    Assert-NotNull $read 'a state with empty volumes reads back'
    Assert-Equal 1 $read.schema_version 'the schema version round-trips'
    Assert-Equal 0 (@($read.volumes).Count) 'volumes is present and empty'
    Assert-Equal 0 (@($read.nvme).Count) 'nvme is present and empty'

    # Every catalog counter must survive: a missing key makes the next delta wrong.
    $counterNames = @($read.counters.PSObject.Properties.Name)
    foreach ($row in (Get-DiagEventCatalog)) {
        Assert-Contains $counterNames $row.Key ('the state carries the counter ' + $row.Key)
    }

    $backups = @(Get-ChildItem -LiteralPath $dir -Filter 'state.json.corrupt-*' -ErrorAction SilentlyContinue)
    Assert-Count $backups 0 'a valid state is not set aside'
    Assert-True (Test-Path -LiteralPath $path) 'the state file is still in place'

    # A second write over an existing file must also be read back (atomic move).
    Write-DiagState -State $state -Path $path
    $again = Read-DiagState -Path $path
    Assert-NotNull $again 'an overwritten state still reads back'
}

function Test-T21StateMissingKey {
    <#
      A state with the volumes KEY ABSENT is unusable: a half-read baseline is
      worse than none, so the file is set aside and the run continues as a first
      run (RF-30, EC-11).
    #>
    Reset-TestEnvironment
    $dir = New-TestTempDir
    $path = Join-Path -Path $dir -ChildPath 'state.json'
    Copy-Item -LiteralPath (Join-Path -Path (Get-PcDiagFixtureDirectory) -ChildPath 'state-missing-volumes.json') -Destination $path

    $read = $null
    $threw = $false
    try { $read = Read-DiagState -Path $path } catch { $threw = $true }
    Assert-False $threw 'Read-DiagState never throws on a bad state'
    Assert-Null $read 'a state without the volumes key is rejected'

    $backups = @(Get-ChildItem -LiteralPath $dir -Filter 'state.json.corrupt-*' -ErrorAction SilentlyContinue)
    Assert-Count $backups 1 'the rejected file is set aside'
    Assert-False (Test-Path -LiteralPath $path) 'the unusable file is moved out of the way'

    $baseline = Get-DiagReportBaseline -Snapshot (New-TestSnapshot) -Previous $read
    Assert-Equal 'baseline: none (first run)' $baseline.text 'a rejected state renders as a first run'
}

function Test-T22StateLastRunShapes {
    <#
      last_run_at arrives as an ISO string (built in memory) or as a [datetime]
      (ConvertFrom-Json materialises it). Both must produce the same baseline and
      the same deltas; a culture-sensitive [string] cast would silently disable
      every delta.

      counters.<key> in the state is a scalar int|null (section 7.1/7.2), not the
      snapshot shape ({ total; since_last_run; error }); New-TestStateCounters
      builds the persisted shape, New-TestCounters the snapshot one.
    #>
    Reset-TestEnvironment

    $current = [pscustomobject]@{
        schema_version = 1
        host           = 'TEST-HOST'
        last_run_at    = (Get-DiagTimestamp)
        counters       = (New-TestStateCounters -Values @{ disk_51 = 5 })
        wer            = [pscustomobject]@{ repeats = 10; signatures = @() }
    }

    $lastRun = (Get-Date).AddHours(-24)
    $asString = [pscustomobject]@{
        schema_version = 1
        host           = 'TEST-HOST'
        last_run_at    = (Get-DiagTimestamp -Date $lastRun)
        counters       = (New-TestStateCounters -Values @{ disk_51 = 2 })
        wer            = [pscustomobject]@{ repeats = 4; signatures = @() }
    }
    $asDate = [pscustomobject]@{
        schema_version = 1
        host           = 'TEST-HOST'
        last_run_at    = $lastRun
        counters       = (New-TestStateCounters -Values @{ disk_51 = 2 })
        wer            = [pscustomobject]@{ repeats = 4; signatures = @() }
    }

    $fromString = Compare-DiagState -Current $current -Previous $asString
    $fromDate = Compare-DiagState -Current $current -Previous $asDate

    Assert-True $fromString.baseline_usable 'an ISO string baseline is usable'
    Assert-True $fromDate.baseline_usable 'a DateTime baseline is usable'
    Assert-Equal 3 $fromString.since_last_run['disk_51'] 'the string shape yields a delta of 3'
    Assert-Equal 3 $fromDate.since_last_run['disk_51'] 'the DateTime shape yields the same delta of 3'
    Assert-Equal $fromString.since_last_run['disk_51'] $fromDate.since_last_run['disk_51'] 'both shapes agree'
    Assert-Equal $fromString.since_last_run['whea_17'] $fromDate.since_last_run['whea_17'] 'a counter present in both states but unchanged agrees in both shapes'

    # A previous counter that was null (a failed query, section 7.3) has no
    # delta: it must be null, never a number computed against a fabricated 0.
    $nullPrevious = [pscustomobject]@{
        schema_version = 1
        host           = 'TEST-HOST'
        last_run_at    = (Get-DiagTimestamp -Date $lastRun)
        counters       = (New-TestStateCounters -Values @{ disk_51 = $null })
        wer            = [pscustomobject]@{ repeats = 4; signatures = @() }
    }
    $fromNull = Compare-DiagState -Current $current -Previous $nullPrevious
    Assert-True $fromNull.baseline_usable 'a null counter does not make the baseline unusable'
    Assert-Null $fromNull.since_last_run['disk_51'] 'a null previous counter yields no delta, not a made-up one'

    # And the renderer shows "-" for it rather than "+0" (RF-27).
    $nullCounterSnapshot = New-TestSnapshot -Counters (New-TestCounters -Values @{ disk_51 = @{ total = 5; since_last_run = $null; error = $null } })
    $nullSection = @(Get-DiagReportSection07 -Snapshot $nullCounterSnapshot | Where-Object { $_ -match '^\s+disk_51\s+' })
    Assert-Count $nullSection 1 'the disk_51 counter line exists'
    Assert-Match $nullSection[0] 'total=5\s+since_last_run=-$' 'a counter with no previous value renders since_last_run=-'
    Assert-NotMatch $nullSection[0] 'since_last_run=\+0' 'a counter with no previous value never renders +0'

    $futureDate = [pscustomobject]@{ schema_version = 1; host = 'TEST-HOST'; last_run_at = ((Get-Date).AddDays(2)); counters = (New-TestStateCounters); wer = [pscustomobject]@{ repeats = 0; signatures = @() } }
    $futureString = [pscustomobject]@{ schema_version = 1; host = 'TEST-HOST'; last_run_at = (Get-DiagTimestamp -Date ((Get-Date).AddDays(2))); counters = (New-TestStateCounters); wer = [pscustomobject]@{ repeats = 0; signatures = @() } }
    $futureA = Compare-DiagState -Current $current -Previous $futureDate
    $futureB = Compare-DiagState -Current $current -Previous $futureString
    Assert-False $futureA.baseline_usable 'a DateTime in the future is rejected'
    Assert-False $futureB.baseline_usable 'a string in the future is rejected'
    Assert-Match $futureA.reason 'future' 'the reason names the cause'
    Assert-Match $futureB.reason 'future' 'the reason names the cause in both shapes'

    $unparsable = [pscustomobject]@{ schema_version = 1; host = 'TEST-HOST'; last_run_at = 'not-a-date'; counters = (New-TestStateCounters); wer = [pscustomobject]@{ repeats = 0; signatures = @() } }
    $bad = Compare-DiagState -Current $current -Previous $unparsable
    Assert-False $bad.baseline_usable 'an unparsable timestamp is not used as a baseline'
    Assert-Match $bad.reason 'unparsable' 'the reason names the cause'
}

function Test-T23StateCorruptAndVersion {
    <#
      EC-11: a truncated file and a newer schema are both set aside with one
      warning and the run continues as a first run. Nothing half-read is used.
    #>
    Reset-TestEnvironment
    $dir = New-TestTempDir
    $fixtureDir = Get-PcDiagFixtureDirectory

    $corruptPath = Join-Path -Path $dir -ChildPath 'state.json'
    Copy-Item -LiteralPath (Join-Path -Path $fixtureDir -ChildPath 'state-corrupt.json') -Destination $corruptPath
    $corrupt = $null
    $threw = $false
    try { $corrupt = Read-DiagState -Path $corruptPath } catch { $threw = $true }
    Assert-False $threw 'a truncated state does not throw'
    Assert-Null $corrupt 'a truncated state is not returned'
    Assert-Count @(Get-ChildItem -LiteralPath $dir -Filter 'state.json.corrupt-*' -ErrorAction SilentlyContinue) 1 'the truncated state is set aside'

    $versionDir = New-TestTempDir
    $versionPath = Join-Path -Path $versionDir -ChildPath 'state.json'
    Copy-Item -LiteralPath (Join-Path -Path $fixtureDir -ChildPath 'state-schema-2.json') -Destination $versionPath
    $newer = Read-DiagState -Path $versionPath
    Assert-Null $newer 'a newer schema is not half-read'
    Assert-Count @(Get-ChildItem -LiteralPath $versionDir -Filter 'state.json.corrupt-*' -ErrorAction SilentlyContinue) 1 'the incompatible state is set aside'

    $missing = Read-DiagState -Path (Join-Path -Path $dir -ChildPath 'does-not-exist.json')
    Assert-Null $missing 'an absent state is a first run, not an error'

    $validPath = Join-Path -Path $dir -ChildPath 'state-valid.json'
    Copy-Item -LiteralPath (Join-Path -Path $fixtureDir -ChildPath 'state-v1.json') -Destination $validPath
    $valid = Read-DiagState -Path $validPath
    Assert-NotNull $valid 'a valid v1 state is accepted'
    Assert-Equal 'TEST-HOST' $valid.host 'the parsed state carries its fields'
}

function Test-T24CatalogInvariants {
    <#
      RF-13 is structural: the catalog is the only place a filter is built, every
      row carries an exact provider and at least one Id, and no row can be
      queried by Id alone.
    #>
    Reset-TestEnvironment

    $catalog = Get-DiagEventCatalog
    Assert-GreaterOrEqual (@($catalog).Count) 19 'the catalog still has its 19 rows'

    $seenKeys = @{}
    foreach ($row in $catalog) {
        Assert-False ([string]::IsNullOrWhiteSpace([string]$row.Provider)) ('row ' + $row.Key + ' names a provider')
        Assert-GreaterOrEqual (@($row.Ids).Count) 1 ('row ' + $row.Key + ' names at least one Id')
        Assert-False ([string]::IsNullOrWhiteSpace([string]$row.Log)) ('row ' + $row.Key + ' names a log')
        Assert-False ([string]::IsNullOrWhiteSpace([string]$row.Label)) ('row ' + $row.Key + ' carries a label')
        Assert-False $seenKeys.ContainsKey([string]$row.Key) ('the key ' + $row.Key + ' is unique')
        $seenKeys[[string]$row.Key] = $true
    }

    $query = Get-DiagQueryText -Row (Get-DiagEventCatalogRow -Key 'whea_17') -Since ([datetime]'2026-10-14T00:00:00')
    Assert-Equal 'query: LogName=System ProviderName=Microsoft-Windows-WHEA-Logger Id=17 since=2026-10-14T00:00:00' $query 'the audit line carries log, provider, id and window start'
}

# ===========================================================================
# Registry, runner
# ===========================================================================

$script:TestCases = @(
    @{ Name = 'T00-runner-self-contained';     Run = { Test-RunnerSelfContained } },
    @{ Name = 'T00b-stub-records-arguments';   Run = { Test-StubRecordsArguments } },
    @{ Name = 'T01-whea-provider-filter';      Run = { Test-T01WheaProviderFilter } },
    @{ Name = 'T02-provider-guard';            Run = { Test-T02ProviderGuard } },
    @{ Name = 'T03-offprovider-drop';          Run = { Test-T03OffProviderDrop } },
    @{ Name = 'T04-wer-dedupe-dump';           Run = { Test-T04WerDedupeDump } },
    @{ Name = 'T04b-wer-dedupe-matrix';        Run = { Test-T04bWerDedupeMatrix } },
    @{ Name = 'T05-wer-params-fallback';       Run = { Test-T05WerParamsFallback } },
    @{ Name = 'T06-wer-unidentified';          Run = { Test-T06WerUnidentified } },
    @{ Name = 'T06b-wer-accounting';           Run = { Test-T06bWerAccounting } },
    @{ Name = 'T07-listing-cap-and-size';      Run = { Test-T07ListingCapAndSize } },
    @{ Name = 'T10-unavailable-not-zero';      Run = { Test-T10UnavailableNotZero } },
    @{ Name = 'T11-listing-truncation';        Run = { Test-T11ListingTruncation } },
    @{ Name = 'T12-quick-line-ceiling';        Run = { Test-T12QuickCeiling } },
    @{ Name = 'T12b-quick-never-runs-dxdiag';  Run = { Test-T12bQuickNeverRunsDxDiag } },
    @{ Name = 'T13-baseline-out-of-window';    Run = { Test-T13BaselineOutOfWindow } },
    @{ Name = 'T14-whea-severity-labels';      Run = { Test-T14WheaSeverityLabels } },
    @{ Name = 'T15-locale-independent';        Run = { Test-T15LocaleIndependent } },
    @{ Name = 'T20-state-roundtrip-empty-volumes'; Run = { Test-T20StateRoundTripEmptyVolumes } },
    @{ Name = 'T21-state-missing-key';         Run = { Test-T21StateMissingKey } },
    @{ Name = 'T22-state-last-run-shapes';     Run = { Test-T22StateLastRunShapes } },
    @{ Name = 'T23-state-corrupt-and-version'; Run = { Test-T23StateCorruptAndVersion } },
    @{ Name = 'T24-catalog-invariants';        Run = { Test-T24CatalogInvariants } }
)

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:FailureList = New-Object System.Collections.ArrayList

Write-Line ('PC DIAGNOSTICS - TEST SUITE (' + $PSVersionTable.PSVersion.ToString() + ')')

foreach ($case in $script:TestCases) {
    $name = [string]$case.Name
    if (-not [string]::IsNullOrWhiteSpace($Filter) -and $name.ToLowerInvariant().IndexOf($Filter.ToLowerInvariant()) -lt 0) {
        $script:Skipped = $script:Skipped + 1
        continue
    }

    Set-TestCurrentName -Name $name
    $before = Get-TestFailureCount

    try {
        # $null = ...: assertions return booleans for `if`-style use; without this
        # they would land on stdout and bury the one-line-per-test protocol.
        Reset-TestEnvironment | Out-Null
        $null = & $case.Run
    } catch {
        $reason = 'unhandled exception: '
        try { $reason = $reason + [string]$_.Exception.Message } catch { }
        Add-TestFailure -Message $reason
    }

    $failures = @(Get-TestFailures | Where-Object { $_.Test -eq $name })
    if ($failures.Count -eq 0) {
        $script:Passed = $script:Passed + 1
        Write-Line ('PASS ' + $name)
    } else {
        $script:Failed = $script:Failed + 1
        $first = $failures[0]
        Write-Line ('FAIL ' + $name + ' :: ' + [string]$first.Message)
        $i = 1
        while ($i -lt $failures.Count) {
            Write-Line ('     ' + [string]$failures[$i].Message)
            $i = $i + 1
            if ($i -gt 40) { break }
        }
        foreach ($failure in $failures) { [void]$script:FailureList.Add($failure) }
    }
}

# ---------------------------------------------------------------------------
# Cleanup (RT-07): the temp tree goes away unless -KeepTemp was passed.
# ---------------------------------------------------------------------------
try {
    if (-not $KeepTemp) { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    elseif ($script:Failed -gt 0 -or $true) { Write-Line ('temp: ' + $script:TempRoot) }
} catch { }

$duration = ((Get-Date) - $script:SuiteStarted).TotalSeconds
$durationText = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F1}', $duration)

Write-Line ('TOTAL ' + [string]($script:Passed + $script:Failed) + ' PASSED ' + [string]$script:Passed + ' FAILED ' + [string]$script:Failed + ' DURATION ' + $durationText + 's')
if ($script:Skipped -gt 0) { Write-Line ('skipped by -Filter: ' + [string]$script:Skipped) }

# RT-06: the suite itself has a budget. Overrunning it is a failure even when
# every assertion passed, because a suite nobody runs protects nothing.
if ($duration -ge 60) {
    Write-Line ('FAIL suite-duration :: expected under 60 s, took ' + $durationText + ' s')
    exit 1
}

if ($script:Failed -gt 0) { exit 1 }
exit 0
