# Invoke-PcDiagnostics.ps1
#
# Entry point: parameters, validation, dot-sourcing, orchestration, artifact
# writing and exit code. Zero collection logic lives here (section 4.2).
#
#   pwsh -File .\Invoke-PcDiagnostics.ps1 [-Mode <Full|Quick>] [-Days <Int>]
#       [-OutputDir <String>] [-MaxEventsPerCategory <Int>] [-TopFolders <Int>]
#       [-SkipDxDiag]
#
# Exit codes:
#   0  completed (a degraded run is still 0)
#   1  invalid invocation
#   2  fatal: output directory not writable, or the report could not be written
#
# Read-only and offline: the only files created are the artifacts inside
# -OutputDir. Elevation happens once, in Run-PcDiagnostics.bat (RS-04).

[CmdletBinding()]
param(
    [string]$Mode = 'Full',
    [int]$Days = 30,
    [string]$OutputDir = '.\reports',
    [int]$MaxEventsPerCategory = 20,
    [int]$TopFolders = 10,
    [switch]$SkipDxDiag
)

# Deliberately no ValidateSet/ValidateRange attributes: an out-of-range value has
# to produce the exact "Invalid parameter: <name> (expected <rule>, got <value>)"
# line of RF-02 plus the usage block, which attribute binding cannot do.
$ErrorActionPreference = 'Continue'

function Get-DiagUsage {
    return @(
        '',
        'PC Diagnostics Toolkit',
        '',
        'Usage:',
        '  pwsh -File .\Invoke-PcDiagnostics.ps1 [-Mode <Full|Quick>] [-Days <Int>]',
        '      [-OutputDir <String>] [-MaxEventsPerCategory <Int>] [-TopFolders <Int>]',
        '      [-SkipDxDiag]',
        '',
        '  -Mode                  Full (default) writes a report; Quick prints a table only.',
        '  -Days                  1..365. Lookback window for every event query. Default 30.',
        '  -OutputDir             Artifact directory, created if missing. Default .\reports',
        '  -MaxEventsPerCategory  0..1000. Listing lines per event category. 0 = counts only.',
        '  -TopFolders            >= 1. Largest folders and files per volume. Default 10.',
        '  -SkipDxDiag            Skip dxdiag; the run has 11 progress steps instead of 12.',
        '',
        'For a Full run with a single UAC prompt, double-click Run-PcDiagnostics.bat.',
        ''
    )
}

function Write-DiagFail {
    <#
      Writes to stderr only. Progress and the report body never go to stderr
      (section 9.2).
    #>
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = (Get-Location).Path
}

# ---------------------------------------------------------------------------
# 1. Parameter validation - before any collection, before any artifact (RF-02)
# ---------------------------------------------------------------------------
$invalidName = $null
$invalidRule = $null
$invalidValue = $null

if ($Mode -ne 'Full' -and $Mode -ne 'Quick') {
    $invalidName = 'Mode'
    $invalidRule = 'Full|Quick'
    $invalidValue = $Mode
} elseif ($Days -lt 1 -or $Days -gt 365) {
    $invalidName = 'Days'
    $invalidRule = '1..365'
    $invalidValue = $Days
} elseif ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $invalidName = 'OutputDir'
    $invalidRule = 'a non-empty path'
    $invalidValue = '""'
} elseif ($MaxEventsPerCategory -lt 0 -or $MaxEventsPerCategory -gt 1000) {
    $invalidName = 'MaxEventsPerCategory'
    $invalidRule = '0..1000'
    $invalidValue = $MaxEventsPerCategory
} elseif ($TopFolders -lt 1) {
    $invalidName = 'TopFolders'
    $invalidRule = '>= 1'
    $invalidValue = $TopFolders
}

if ($null -ne $invalidName) {
    Write-DiagFail ('Invalid parameter: ' + $invalidName + ' (expected ' + $invalidRule + ', got ' + [string]$invalidValue + ')')
    foreach ($line in (Get-DiagUsage)) { [Console]::Out.WriteLine($line) }
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Load the library once, in a fixed order (no globbing, no duplicates)
# ---------------------------------------------------------------------------
$libFiles = @(
    'Common.ps1',
    'Collect-Hardware.ps1',
    'Collect-Storage.ps1',
    'Collect-Events.ps1',
    'Collect-Config.ps1',
    'State.ps1',
    'Report.ps1'
)

foreach ($name in $libFiles) {
    $libPath = Join-Path -Path (Join-Path -Path $scriptRoot -ChildPath 'lib') -ChildPath $name
    if (-not (Test-Path -LiteralPath $libPath)) {
        Write-DiagFail ('FATAL: missing library file: ' + $libPath)
        exit 2
    }
    . $libPath
}

# ---------------------------------------------------------------------------
# 3. Resolve and prepare the output directory (EC-08)
# ---------------------------------------------------------------------------
$resolvedOutput = $null
try {
    $resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
} catch {
    Write-DiagFail ('Output directory is not writable: ' + $OutputDir)
    exit 2
}
if (-not [System.IO.Path]::IsPathRooted($resolvedOutput)) {
    try { $resolvedOutput = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $resolvedOutput)) } catch { }
}

try {
    if (-not [System.IO.Directory]::Exists($resolvedOutput)) {
        [void][System.IO.Directory]::CreateDirectory($resolvedOutput)
    }
} catch {
    Write-DiagFail ('Output directory is not writable: ' + $resolvedOutput)
    exit 2
}

# Writability probe. state.json.tmp is one of the five permitted write targets
# (RS-03), so the probe stays inside the artifact allowlist.
$statePath = Join-Path -Path $resolvedOutput -ChildPath 'state.json'
$probePath = $statePath + '.tmp'
try {
    $probeEncoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($probePath, '', $probeEncoding)
    [System.IO.File]::Delete($probePath)
} catch {
    Write-DiagFail ('Output directory is not writable: ' + $resolvedOutput)
    exit 2
}

# ---------------------------------------------------------------------------
# 4. Baseline. A corrupt or incompatible state is set aside with one warning and
#    the run continues as a first run (RF-30, EC-11).
# ---------------------------------------------------------------------------
$previousState = Read-DiagState -Path $statePath

# ---------------------------------------------------------------------------
# 5. Orchestration. Quick mode prints no progress lines (RF-04) but still goes
#    through Invoke-DiagStep, so the step machinery is identical in both modes.
# ---------------------------------------------------------------------------
if ($Mode -eq 'Quick') {
    Set-DiagProgressSink -Sink { param($progressLine) }
}

$snapshot = New-DiagSnapshot `
    -Days $Days `
    -TopFolders $TopFolders `
    -MaxEventsPerCategory $MaxEventsPerCategory `
    -SkipDxDiag:$SkipDxDiag `
    -Mode $Mode `
    -OutputDir $resolvedOutput `
    -StatePath $statePath `
    -Previous $previousState

# ---------------------------------------------------------------------------
# 6. Artifacts
# ---------------------------------------------------------------------------
if ($Mode -eq 'Full') {
    $stamp = [string]$snapshot.meta.Stamp
    $reportName = 'pc-diagnostics-' + [string]$snapshot.meta.Host + '-' + $stamp + '.txt'
    $reportPath = Join-Path -Path $resolvedOutput -ChildPath $reportName
    $reportPath = Get-DiagUniquePath -Path $reportPath
    $snapshot.meta | Add-Member -NotePropertyName 'ReportPath' -NotePropertyValue $reportPath -Force

    # The renderer returns the lines; writing is the entry point's job (section
    # 4.2). UTF-8 without a BOM and CRLF line endings (RF-03, RNF-05), and a
    # zero-byte report is a defect, so an empty body exits 2 instead.
    try {
        $reportLines = @(New-FullReport -Snapshot $snapshot -Path $reportPath)
        if ($reportLines.Count -eq 0) {
            throw (New-Object System.Exception('renderer returned no lines'))
        }
        $reportText = ($reportLines -join "`r`n") + "`r`n"
        $reportEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($reportPath, $reportText, $reportEncoding)
        if ((Get-Item -LiteralPath $reportPath -ErrorAction Stop).Length -le 0) {
            throw (New-Object System.Exception('report file is empty'))
        }
    } catch {
        Write-DiagFail ('FATAL: could not write the report to ' + $reportPath + ': ' + (Get-DiagErrorText -ErrorRecord $_))
        exit 2
    }
}

if ($Mode -eq 'Quick') {
    $quickLines = @(Format-QuickReport -Snapshot $snapshot -Previous $previousState)
    foreach ($line in $quickLines) {
        [Console]::Out.WriteLine([string]$line)
    }
}

# State is written last, in both modes, atomically (RF-30, AD-08). A write
# failure is non-fatal: one warning, exit 0.
try {
    $stateObject = New-DiagState -Snapshot $snapshot -StatePath $statePath
    Write-DiagState -State $stateObject -Path $statePath
} catch {
    Write-Warning ('state file could not be written: ' + (Get-DiagErrorText -ErrorRecord $_) + '; the run itself completed.')
}

if ($Mode -eq 'Full') {
    [Console]::Out.WriteLine('report: ' + [string]$snapshot.meta.ReportPath)
}

exit 0
