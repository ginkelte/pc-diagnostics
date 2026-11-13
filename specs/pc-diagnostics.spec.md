---
id: SPEC-PCDIAG-001
title: PC Diagnostics Toolkit - Full Report and Quick Delta Monitor
status: draft
layer: infrastructure
tags: [powershell, windows, diagnostics, event-log, storage, crash-forensics, sdd]
acceptance: specs/pc-diagnostics.feature
depends_on: []
owner: ginkelte
created: 2026-11-13
updated: 2026-11-13
version: 1.0.0
---

# PC Diagnostics Toolkit - Specification

> Requirement identifiers use four prefixes: **RF** (functional), **RNF**
> (non-functional), **RS** (security), **RT** (test). Every requirement is
> individually verifiable and is referenced by at least one Gherkin scenario in
> `specs/pc-diagnostics.feature` (see section 13, Traceability).

## 1. Context and Problem

### 1.1 Origin

This specification formalises a PowerShell script that was written and used in
the field to diagnose a Windows 11 desktop whose games crashed with
`EXCEPTION_ACCESS_VIOLATION`, whose NVMe device reset itself, and whose system
drive was 2 % free. The script produced a report that led to the actual root
causes, but it also produced two categories of **false numbers** that misdirected
the first hours of diagnosis, and one **unbounded output** that made the report
unusable for sharing.

The toolkit is being reimplemented from scratch. This spec is the contract. The
two defects below are not "nice to have" polish: they are the reason the spec
exists, and an implementation that reproduces either defect is non-compliant.

### 1.2 Defect 1 - Event counts inflated by filtering on Event ID only

Windows event IDs are **per provider**. The same numeric ID means different
things under different providers. The original script queried the `System` log
for IDs `18, 19, 47` and reported 317 "machine checks". The events were:

- `WindowsUpdateClient` ID 19 (Windows Update agent activity),
- `TPM` ID 18 (TPM operational events),

and the true count of hardware errors was **0**.

Consequence: a healthy machine looked catastrophically broken, and real signals
were buried under noise. The query was syntactically valid, returned real events,
and was semantically meaningless.

**Closure rule:** every event query MUST filter on provider name *and* event ID.
There is no code path that queries by ID alone (RF-13, RF-14, RT-04).

### 1.3 Defect 2 - WER re-reports counted as crashes

`Application` log ID 1001 is a Windows Error Reporting (WER) bucket event. When
WER cannot upload a dump it re-reports the **same dump** repeatedly over days.
The original script counted 6,915 "crashes" in a 30-day window and emitted a 3 MB
text file. The machine had **12 unique minidumps**, each re-reported up to 173
times.

Consequence: the crash count was meaningless, the report could not be pasted or
mailed, and the actual pattern (one game crashing repeatedly, not twelve things
crashing) was invisible.

**Closure rule:** WER events MUST be deduplicated by dump signature; the report
MUST state unique dumps and re-report count separately, and MUST bound every
event listing (RF-15, RF-16, RT-05, RT-06).

### 1.4 Field case the report must explain

The reference machine presented all of the following simultaneously. Each item
below maps to a requirement; the report is useless if it omits any of them.

| Observation | Why it mattered | Requirement |
|---|---|---|
| Games crashing, stack 100 % inside the game binary | Looked like an application bug; was environmental | RF-15 |
| `stornvme` ID 129 "device reset", 6 times in 6 days | Storage controller resetting under load | RF-13 |
| `disk` ID 51 paging errors, 35 times | Paging I/O failing | RF-13 |
| `WHEA-Logger` ID 17 (corrected PCIe AER), 58 times | Bus-level correctable errors | RF-13 |
| Bugchecks `0x1E`, `0x154` (UNEXPECTED_STORE_EXCEPTION), `0xBE` | Store/paging related, matches disk 51 | RF-18 |
| System volume at 2 % free | Primary root cause | RF-10, RF-11 |
| DDR4-3600 modules on an i7-11700 (rated 3200) | Running out of spec, XMP state unclear | RF-07 |
| Four RGB suites fighting (Armoury Crate, MSI LEDKeeper2, G HUB) | Device contention, keyboard enumerating blank | RF-23 |
| SSD firmware update never applied | Fast Startup made "shutdown" a hibernation | RF-09, RF-19 |

## 2. Goals and Non-Goals

### 2.1 Goals

- **G1** Produce one complete, shareable text report of a Windows 10/11 machine's
  hardware, storage health, power configuration and crash history, in under three
  minutes, with visible progress.
- **G2** Make every number in that report attributable: a count always answers
  "which provider, which ID, which window, which log".
- **G3** Answer "did the errors come back since last time?" in under three
  seconds from a console-only monitor mode, by diffing against a persisted state
  file.
- **G4** Run read-only, offline, with no dependencies, on a machine owned by a
  non-technical user, launched by double-clicking a `.bat`.
- **G5** Be verifiable on Linux with `pwsh` and stub collectors, with a
  self-contained test suite that requires neither Pester nor Windows.

### 2.2 Non-goals

- **NG1** No remediation. The toolkit never disables a service, uninstalls an RGB
  suite, edits the registry, or resizes a volume. It reports and stops.
- **NG2** No upload, telemetry, or cloud call of any kind (RS-02).
- **NG3** No HTML, JSON, or PDF report. Plain text only, plus `state.json`.
- **NG4** No scheduled task, service, or installer. Distribution is "copy the
  folder".
- **NG5** No live process/CPU/memory profiling, no benchmarks, no stress tests.
- **NG6** No non-Windows targets: the collectors are Windows-only by design; only
  the *test suite* must run cross-platform (RT-02).
- **NG7** No Pester, no PowerShell Gallery modules, no external binaries other
  than what ships with Windows (`fsutil`, `dxdiag`).

## 3. CLI Contract

### 3.1 Entry point

```
pwsh -File .\Invoke-PcDiagnostics.ps1 [-Mode <Full|Quick>] [-Days <Int>]
    [-OutputDir <String>] [-MaxEventsPerCategory <Int>] [-TopFolders <Int>]
    [-SkipDxDiag]
```

Windows PowerShell 5.1 and PowerShell 7.x are both supported (RNF-04).

### 3.2 Parameters

| Parameter | Type | Default | Validation | Semantics |
|---|---|---|---|---|
| `-Mode` | `ValidateSet('Full','Quick')` | `Full` | exact set | `Full` writes a report artifact; `Quick` prints a console table only |
| `-Days` | `[int]` | `30` | `1..365` | Lookback window for every event query and every count |
| `-OutputDir` | `[string]` | `.\reports` | non-empty; created if missing | Sole write location for all artifacts (RS-03) |
| `-MaxEventsPerCategory` | `[int]` | `20` | `0..1000` | Max listing lines per event category; `0` = counts only, no listing |
| `-TopFolders` | `[int]` | `10` | `>= 1` | Number of largest folders and largest files per volume |
| `-SkipDxDiag` | `[switch]` | off | - | Skips the `dxdiag` step; total progress steps drops from 12 to 11 |

Rules:

- Unknown parameters, unparsable values, or out-of-range values MUST exit with
  code `1` and print the offending parameter name (RF-02).
- `-OutputDir` is resolved to an absolute path once, at start, and echoed in the
  report header. All artifacts use it; nothing is written outside it (RS-03).
- No parameter changes the set of collected *facts* except `-Days`,
  `-MaxEventsPerCategory`, `-TopFolders` and `-SkipDxDiag`, each of which changes
  only its own dimension.

### 3.3 Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed. Full mode wrote a report; Quick mode printed a table. Degraded data (EC-01) is still `0`. |
| `1` | Invalid invocation (unknown parameter, bad range, `-Mode` outside the set). |
| `2` | Fatal: output directory not writable, or the report artifact could not be written. |

A failed *collector* is never fatal: it degrades one section to `unavailable`
(RF-27) and the run continues.

## 4. Repository Structure and Module Seams

### 4.1 Required layout

```
pc-diagnostics/
├── README.md                      # existing; not owned by this spec
├── Run-PcDiagnostics.bat          # UAC launcher (RF-31)
├── Invoke-PcDiagnostics.ps1       # entry point: params, orchestration, exit code
├── lib/
│   ├── Common.ps1                 # Get-DiagEvent, Invoke-DiagStep, Test-DiagElevation, formatting helpers
│   ├── Collect-Hardware.ps1       # system, CPU, memory, display adapters
│   ├── Collect-Storage.ps1        # disks, NVMe SMART, volumes, largest folders
│   ├── Collect-Events.ps1         # event catalog, counters, boots, WER dedupe
│   ├── Collect-Config.ps1         # power, Fast Startup, lighting, Windows Update, drivers, startup, TRIM, pagefile
│   ├── Report.ps1                 # section renderers, quick table
│   └── State.ps1                  # Read/Write/Compare state.json
├── specs/
│   ├── pc-diagnostics.spec.md     # this file
│   └── pc-diagnostics.feature     # Gherkin acceptance criteria
└── tests/
    ├── run-tests.ps1              # self-contained runner (RT-01)
    ├── asserts.ps1                # Assert-Equal / Assert-True / Assert-Match / Assert-Throws
    ├── stubs.ps1                  # Windows cmdlet stubs backed by fixtures (RT-03)
    └── fixtures/*.json            # recorded/synthetic inputs
```

### 4.2 Invariants over the layout

- `Invoke-PcDiagnostics.ps1` MUST contain only: `param` block, parameter
  validation, dot-sourcing of `lib/*.ps1`, step orchestration, progress calls,
  artifact writing, exit code. **Zero collection logic** may live there.
- All collectors, aggregators, formatters and state functions MUST live in
  `lib/` and be dot-sourceable without side effects (no collection at load time).
- No `lib/` file may be dot-sourced more than once per run; functions MUST be
  idempotent on repeat dot-source.
- Script files are UTF-8 without BOM, ASCII-only content (RNF-05); `Run-PcDiagnostics.bat`
  is ASCII with CRLF line endings (RF-31).

### 4.3 Public function contract (test seams)

These names, parameter names and return shapes are normative. Tests bind to them;
renaming one is a spec change.

| Function | Parameters | Returns |
|---|---|---|
| `Get-DiagEvent` | `-LogName <string>`, `-ProviderName <string>`, `-Id <int[]>`, `-Since <datetime>`, `-MaxEvents <int>` (optional) | `[pscustomobject[]]` with `TimeCreated`, `Id`, `ProviderName`, `Level`, `Message`, `Data` (ordered hashtable of EventData name/value) |
| `Get-EventCounters` | `-Since <datetime>`, `-SinceLastRun <datetime or $null>` | ordered hashtable `counter_key -> @{ total; since_last_run }` |
| `Get-WerSignature` | `-Event <pscustomobject>` | `[pscustomobject]` with `Kind` in `dump|params|none` and `Value` |
| `Get-WerSummary` | `-Events <pscustomobject[]>` | object with `events_seen`, `unique_dumps`, `unique_params`, `unidentified`, `repeats`, `signatures[]` |
| `Get-VolumeSpace` | none | `[pscustomobject[]]` with `Mount`, `SizeGB`, `FreeGB`, `FreePct`, `FileSystem` |
| `Get-LargestFolders` | `-Volume <string>`, `-Top <int>`, `-TimeBudgetSeconds <int>` | `[pscustomobject[]]` with `Path`, `SizeGB`, `Partial` |
| `Get-NvmeHealthLog` | `-DiskNumber <int>` | `[byte[]]` or `$null` |
| `New-DiagSnapshot` | `-Days <int>`, `-TopFolders <int>`, `-MaxEventsPerCategory <int>`, `-SkipDxDiag <switch>` | aggregate object (section 4.4) |
| `New-FullReport` | `-Snapshot`, `-Path <string>` | `[void]`, writes the report |
| `Format-QuickReport` | `-Snapshot`, `-Previous <object or $null>` | `[string[]]`, one line per console row |
| `Read-DiagState` | `-Path <string>` | state object, or `$null` when absent/unreadable |
| `Write-DiagState` | `-State`, `-Path <string>` | `[void]` |
| `Compare-DiagState` | `-Current`, `-Previous` | delta object with `new_signatures`, `since_last_run` map |
| `Test-DiagElevation` | none | `[bool]` |
| `Invoke-DiagStep` | `-Index <int>`, `-Total <int>`, `-Label <string>`, `-Script <scriptblock>`, `-Sink <scriptblock>` (optional) | scriptblock result; emits exactly one progress line |

Notes on the seams:

- NVMe health-log retrieval is isolated in `Get-NvmeHealthLog` (single
  implementation point, may use `IOCTL_STORAGE_QUERY_PROPERTY`/`DeviceIoControl`);
  it MUST NOT throw, and returns `$null` when unavailable.
- Event-listing truncation happens in the snapshot builder, not in the renderers:
  the omitted count is stored as
  `events.ListingsMeta[counter_key] = @{ shown; omitted }` so that RF-16's
  `... <N> more not listed` line can be rendered without re-querying.
- The default `-Sink` of `Invoke-DiagStep` writes to the host; a test-supplied
  `-Sink` captures the lines verbatim (this is what makes T13 possible).
- Progress is emitted through `Invoke-DiagStep` only; no other `Write-Host` in
  `lib/`.

### 4.4 Snapshot object (aggregate seam)

`New-DiagSnapshot` returns a single object with these keys. It is the only
structure `New-FullReport` and `Format-QuickReport` consume, so both renderers
are testable without touching Windows.

| Key | Shape |
|---|---|
| `meta` | `Timestamp`, `Host`, `Mode`, `WindowDays`, `Elevated`, `Version`, `SectionsSkipped[]`, `OffProviderDropped` (int, default 0) |
| `system` | OS caption/version/build/install date/uptime, manufacturer, model, BIOS vendor/version/date |
| `cpu` | name, cores, threads, socket, base MHz, max MHz |
| `gpu` | `Adapters[]` with `Name`, `DriverVersion`, `DriverDate`, `VramGB`, plus current resolution/refresh when reported (RF-08b) |
| `memory` | `Modules[]` (manufacturer, part number, capacity GB, type, speed MHz, configured MHz, voltage, locator, bank) + `TotalSlots`, `PopulatedSlots`, `TotalGB` |
| `storage` | `Disks[]` (model, firmware, bus, media, size GB, health, operational status, `Smart` sub-object or `$null`) |
| `volumes` | `Volumes[]` (as `Get-VolumeSpace`) |
| `largest_folders` | map `Mount -> Folder[]` |
| `largest_files` | map `Mount -> File[]`, ordered size descending then path ascending |
| `events` | `Counters` (hashtable), `Catalog[]` (one row per queried provider+ID), `Listings` (map `counter_key -> Event[]` truncated), `ListingsMeta` (map `counter_key -> @{ shown; omitted }`) |
| `wer` | as `Get-WerSummary` |
| `boots` | `Entries[]` with `Kind` in `clean|dirty|shutdown|unknown` |
| `power` | `FastStartup`, `Pagefile`, `BugcheckCodes[]` |
| `lighting` | `DynamicLighting` (`enabled|disabled|not_present|unavailable`), `Services[]`, `StartupCommands[]` |
| `update` | `LatestKbs[]`, `Pending` (`$null` or `{ Title; Date }`) |
| `drivers` | `OldestDrivers[]` (name, provider, version, date, age days) |
| `misc` | `Trim`, `UptimeHours`, `WindowsBuild` |
| `dxdiag` | `KeyLines[]`, `File` or `$null` |
| `problems` | `Problems[]` with `Collector`, `Reason` (feeds the `unavailable` markers, RF-27) |

## 5. Functional Requirements

### 5.1 Invocation and modes

**RF-01 — Mode selection.**
`-Mode Full` (default) produces a report artifact per RF-03. `-Mode Quick`
produces console output only per RF-28 and MUST NOT write a report or dxdiag
file. Both modes write `state.json` (RF-30). An omitted `-Mode` MUST behave
exactly like `-Mode Full`.

**RF-02 — Parameter validation.**
Out-of-range or unparsable values MUST terminate before any collection starts,
print `Invalid parameter: <name> (expected <rule>, got <value>)` to stderr, print
the usage block to stdout, and exit `1`. No partial artifact may be created on a
validation failure.

**RF-03 — Full-mode artifacts.**
Full mode writes exactly three kinds of file into `-OutputDir`:

| File | Name pattern | Content |
|---|---|---|
| Report | `pc-diagnostics-<host>-<yyyyMMdd-HHmmss>.txt` | Sections 01-14 (section 8) |
| DxDiag | `dxdiag-<host>-<yyyyMMdd-HHmmss>.txt` | Raw `dxdiag /t` output (RF-12) |
| State | `state.json` | Section 7 |

The report MUST be written even when one or more collectors failed (degraded
run): a degraded report is a valid artifact and MUST contain the `unavailable`
markers of RF-27. A zero-byte report is a defect. If the report cannot be
written at all, exit `2`.

**RF-04 — Quick-mode artifacts.**
Quick mode writes only `state.json`. It MUST NOT create a report file, MUST NOT
run `dxdiag`, MUST NOT scan folder sizes, and MUST NOT enumerate installed
drivers (RNF-02). Quick mode MUST NOT print progress lines (RF-28 prints the
table only).

### 5.2 Collection requirements (Full mode)

**RF-05 — System identity.**
Report, in section `01 SYSTEM`: OS caption, version, build (with UBR when
available), edition, install date, uptime in hours with one decimal, computer
manufacturer and model, baseboard product, BIOS vendor, `SMBIOSBIOSVersion`,
BIOS release date. Uptime MUST be derived from `Win32_OperatingSystem.LastBootUpTime`
and MUST be rendered as `51.2 h`, not as a raw `TimeSpan`.

**RF-06 — CPU.**
Report, in section `02 CPU`: name, physical cores, logical processors, socket
designation, base clock MHz, max clock MHz, and the derived
`cores/threads` string.

**RF-07 — Memory modules.**
One line per populated slot plus a totals block, in section `03 MEMORY`. Fields
per module: manufacturer, part number, capacity GB, SMBIOS memory type name
(e.g. `DDR4`, `DDR5`, `unknown(<n>)`), **rated speed MHz** (`Win32_PhysicalMemory.Speed`),
**running speed MHz** (`ConfiguredClockSpeed`), configured voltage in volts
(`ConfiguredVoltage / 1000`, one decimal), device locator, bank label. Totals:
sum of capacities, populated slots, total slots (`Win32_PhysicalMemoryArray.MemoryDevices`).

The two clock fields MUST be labelled unambiguously: `rated (SPD/XMP)` and
`running`. The report MUST contain an explicit line when `running < rated`:
`memory running below module rating: <module> rated <X> MT/s, running <Y> MT/s`.
A run where these two fields are merged into a single `Speed` column is
non-compliant (this hides the DDR4-3600-on-a-3200-part case in 1.4).

**RF-08 — Storage device inventory.**
Section `04 STORAGE DEVICES`, one block per physical disk: friendly name, serial
(when available), firmware version, bus type, media type, size GB, health status,
operational status, partition style, disk number. Bus type MUST be rendered as a
name (`NVMe`, `SATA`, `RAID`, `USB`, `unknown(<n>)`), never as the raw enum
integer.

**RF-08b — Display adapters.**
Section `01 SYSTEM` carries a `GPU (display adapters)` block with one line per
adapter reported by `Get-CimInstance Win32_VideoController`: adapter name, driver
version, driver date (`yyyy-MM-dd`), VRAM in GB with one decimal, and the current
resolution and refresh rate when the adapter reports them. A field the adapter
does not report renders `unavailable (<reason>)` (RF-27), never `0`. Adapters are
listed ordered by name ascending.

This block is collected independently of `dxdiag`: `-SkipDxDiag` MUST NOT remove
it, and a machine where no adapter can be enumerated renders
`gpu: unavailable (<reason>)` rather than omitting the block.

**RF-09 — NVMe SMART.**
For every disk whose bus type is `NVMe`, report the following fields, each
independently:

| Field | Primary source | Secondary source |
|---|---|---|
| `critical_warning` | `Get-NvmeHealthLog` byte 0 | none |
| `available_spare_pct` | `Get-NvmeHealthLog` byte 3 | none |
| `percentage_used` | `Get-NvmeHealthLog` byte 5 | `Get-StorageReliabilityCounter.Wear` |
| `temperature_c` | `Get-NvmeHealthLog` bytes 1-2 (Kelvin, 0-based, minus 273) | `.Temperature` |
| `power_on_hours` | `Get-NvmeHealthLog` bytes 128-143 (128-bit LE) | `.PowerOnHours` |
| `unsafe_shutdowns` | `Get-NvmeHealthLog` bytes 144-159 (128-bit LE) | none |
| `media_errors` | `Get-NvmeHealthLog` bytes 160-175 (128-bit LE) | sum of uncorrected read+write errors |
| `predict_failure` | `MSStorageDriver_FailurePredictStatus.PredictFailure` (`root\wmi`) | none |

Rules:

- The health-log byte offsets MUST live in a single commented constant block in
  `lib/Collect-Storage.ps1`, citing the NVMe base specification SMART/Health
  Information log layout.
- If `Get-NvmeHealthLog` returns `$null`, a byte array shorter than 176 bytes, or
  no byte array for the device, every byte-derived field MUST render
  `unavailable (no NVMe health log)` (RF-27). Rendering `0` for a missing health
  log is a defect of the same class as defect 1.3.
- `percentage_used` MUST be rendered as `<n> %` and MUST NOT be converted into a
  "health %" by subtracting from 100.
- Firmware version MUST be reported (it is the field that explains why a pending
  SSD firmware update never applied, see RF-19).

**RF-10 — Volume free space.**
Section `05 VOLUMES`, one line per **fixed** volume (drive type `Fixed`; network,
removable, CD-ROM and unmounted volumes are excluded). Each line MUST carry
mount point, file system, total GB, free GB and **free percent**, each with one
decimal, plus the marker `LOW` when free percent is below 10. Format:

```
C:  NTFS   448.0 GB total   9.4 GB free   2.1 % free  LOW
```

Free percent MUST be computed as `round(FreeGB / SizeGB * 100, 1)`. A volume
line that shows only GB, or only percent, is non-compliant.

**RF-11 — Largest folders.**
Section `06 LARGEST FOLDERS`, per fixed volume, the top `-TopFolders` immediate
child directories of the volume root, sorted by total recursive file size
descending, rendered as `<path>  <size> GB  <file count>`. Bounds (mandatory,
because an unbounded scan on a full 448 GB volume is a hang):

- reparse points / junctions / symlinks are skipped, never followed;
- a hard time budget of 30 s per volume;
- a hard cap of 200,000 files per volume;
- every file is counted in the folder total regardless of size; only the listing
  is capped by the rules above;
- if the budget or the cap is hit, the rendered line MUST end with
  `PARTIAL (scan stopped: <time budget|file cap>)` and the folder MUST still be
  listed with the size accumulated so far.

The section MUST also render one line per volume stating scanned bytes vs volume
used bytes so a partial scan is detectable from the numbers alone.

After the folder list, the section MUST render the top `-TopFolders` individual
**files** per volume by recursive size, each as `<path>  <size> GB`, ordered by
size descending then path ascending. The file listing runs under the same 30 s
per-volume time budget and the same 200,000-file cap, and a file whose size was
accumulated from a stopped scan MUST end its line with the same
`PARTIAL (scan stopped: <time budget|file cap>)` marker.

**RF-12 — Optional dxdiag.**
Unless `-SkipDxDiag` is passed, the run executes `dxdiag /t <OutputDir>\dxdiag-<host>-<stamp>.txt`
with a 90 s timeout, waits for the file size to stabilise for two consecutive
1 s polls, and extracts at most 40 key lines into section `01 SYSTEM` under a
`DXDIAG (key lines)` block. Key lines are selected by a fixed label allowlist
(`Operating System:`, `System Model:`, `BIOS:`, `Processor:`, `Memory:`,
`Card name:`, `Driver Version:`, `Driver Date:`, `Display Memory:`).

When `-SkipDxDiag` is passed the block renders `dxdiag: skipped (-SkipDxDiag)`.
When `dxdiag` is missing or times out the block renders `dxdiag: unavailable (<reason>)`
and the run continues with exit `0`.

### 5.3 Defect-closure requirements (non-negotiable)

These four requirements close 1.2 and 1.3. They are the acceptance bar for the
reimplementation; an implementation that satisfies everything else and fails
these is rejected.

**RF-13 — Every event query filters by provider AND ID.**
The set of event queries is a single constant catalog. Each row is a counter key,
a log, an exact provider name and one or more IDs:

| Counter key | Log | ProviderName (exact match) | ID(s) |
|---|---|---|---|
| `whea_17` | System | `Microsoft-Windows-WHEA-Logger` | 17 |
| `whea_18` | System | `Microsoft-Windows-WHEA-Logger` | 18 |
| `whea_19` | System | `Microsoft-Windows-WHEA-Logger` | 19 |
| `whea_47` | System | `Microsoft-Windows-WHEA-Logger` | 47 |
| `stornvme_129` | System | `stornvme` | 129 |
| `disk_7` | System | `disk` | 7 |
| `disk_11` | System | `disk` | 11 |
| `disk_51` | System | `disk` | 51 |
| `disk_153` | System | `disk` | 153 |
| `tdr_4101` | System | `Display` | 4101 |
| `tdr_4104` | System | `Display` | 4104 |
| `kernel_power_41` | System | `Microsoft-Windows-Kernel-Power` | 41 |
| `eventlog_6005` | System | `EventLog` | 6005 |
| `eventlog_6006` | System | `EventLog` | 6006 |
| `eventlog_6008` | System | `EventLog` | 6008 |
| `app_error_1000` | Application | `Application Error` | 1000 |
| `wer_1001` | Application | `Windows Error Reporting` | 1001 |
| `app_hang_1002` | Application | `Application Hang` | 1002 |
| `dotnet_1026` | Application | `.NET Runtime` | 1026 |

Rules:

- Counters are derived from this catalog and nowhere else. Adding a category is a
  one-row change; no other file may build a `FilterHashtable`.
- Every count **in the report** MUST be labelled with its provider and ID: counts
  MUST be rendered in the section-07 format of section 8.2, which carries
  provider and ID on the same line. A bare `19: 317` is non-compliant. In
  `state.json` the catalog key (`stornvme_129`) is the label and the catalog
  table is the provider mapping, so the file stays compact and unambiguous.
- The term `machine check` MUST NOT be used for WHEA corrected-error counts. The
  label is `WHEA correctable errors (Microsoft-Windows-WHEA-Logger)`.
- Each catalog row in the report MUST print the query it ran, in the form
  `query: LogName=System ProviderName=stornvme Id=129 since=2026-10-14T00:00:00`,
  so a reader can audit the filter without reading source.

**RF-14 — Query guard and defense in depth.**
`Get-DiagEvent` is the only function allowed to call `Get-WinEvent`, and it MUST:

1. throw a terminating error with code `PROVIDER_FILTER_REQUIRED` when
   `-ProviderName` is null, empty or whitespace;
2. throw a terminating error with code `ID_FILTER_REQUIRED` when `-Id` is null or
   empty;
3. pass `LogName`, `ProviderName`, `Id` and `StartTime` in a single
   `-FilterHashtable` (server-side filtering; `Where-Object` post-filtering is
   not a substitute);
4. after materialisation, **drop** any returned event whose `ProviderName` does
   not equal the requested provider, and increment
   `meta.off_provider_dropped` by the number dropped. A non-zero value is a
   warning in the report header;
5. never classify an event by its message text (see EC-05). The single permitted
   text read is the `.dmp` path regex of RF-15.

Step 4 exists because a stub, a shim, or a future Windows change can return
events that ignore the provider filter. The guard makes the *count* correct even
when the *source* is wrong.

**RF-15 — WER deduplication by dump signature.**
Every `wer_1001` event is reduced to a signature by this fixed precedence:

1. **`Kind=dump`** — the last match of `(?i)[A-Z]:\\[^\r\n"]*?\.dmp\b` in the
   event message. `Value` = the matched path, lowercased and trimmed.
2. **`Kind=params`** — otherwise, if the event's EventData contains any field
   named `P1`..`P10`, `Value` = the non-empty values of `P1`..`P10` joined with
   `|` in numeric order.
3. **`Kind=none`** — otherwise. Such an event has no usable signature.

Aggregation over the window produces exactly these numbers, all of which MUST
appear in section `08 CRASHES / WER`:

| Field | Definition |
|---|---|
| `events_seen` | count of `wer_1001` events in the window |
| `unique_dumps` | count of distinct `Kind=dump` signatures |
| `unique_params` | count of distinct `Kind=params` signatures |
| `unidentified` | count of `Kind=none` events |
| `repeats` | `events_seen - unique_dumps - unique_params - unidentified` |
| `signatures[]` | per signature: `signature`, `kind`, `count`, `first_seen`, `last_seen`, `app` (AppName when present) |

Rules:

- `repeats` MUST be reported as its own number, labelled `re-reports`, never
  added to the crash count.
- The headline crash number in the report and in Quick mode is `unique_dumps`.
  The string `crashes: 6915` MUST NOT appear anywhere; the compliant headline is
  the section-08 format of section 8.2, i.e.
  `WER events: 6915 | unique dumps: 12 | signature-only (params): 0 | unidentified: 0 | re-reports: 6903`.
- `Kind=none` events MUST NOT be counted as unique dumps. They are surfaced in
  `unidentified` so the gap is visible instead of silently inflating the crash
  count in either direction.
- Signature listing is ordered by `count` descending, then signature ascending,
  and is bounded by RF-16.
- `P1..P10` MUST be read from EventData **by field name**, never by splitting
  the localised message (EC-05).

**RF-16 — Bounded listings and report size.**
Every event listing in the report is capped at `-MaxEventsPerCategory` lines
(default 20). When a listing is truncated, the next line MUST read
`... <N> more not listed (see counts above)`. Each listed event renders on
exactly one line as
`<yyyy-MM-dd HH:mm:ss>  <provider>  <id>  <level>  <message>`, fields separated by
two spaces (no column alignment is required, so a provider name containing
spaces cannot break the layout), where `<message>` is the raw message with CR/LF
collapsed to spaces and truncated to 160 characters plus `...` when longer.

`-MaxEventsPerCategory 0` renders counts only and no listing at all (not even
the overflow line).

The complete report MUST stay at or below 512 KB for a window containing up to
10,000 event records (RNF-03). This is the direct closure of the 3 MB output in
1.3 and is verified by RT-06.

### 5.4 Remaining collectors

**RF-17 — Boot classification.**
Section `09 BOOTS` lists the last 10 `eventlog_6005` / `eventlog_6006` /
`eventlog_6008` events, newest first, each classified by this algorithm over the
window sorted ascending:

- `6006` -> `clean shutdown`;
- `6008` -> `dirty shutdown (unexpected)`;
- `6005` -> `clean boot` when the immediately preceding event of the three IDs is
  a `6006`, otherwise `dirty boot (unclean start)`.

The section MUST print `clean boots: <n>` and `dirty boots: <n>` totals for the
window. Boot count MUST NOT be derived from uptime or from Kernel-Power 41.

**RF-18 — Kernel-Power 41 and bugcheck codes.**
Section `10 POWER` extracts, for each `kernel_power_41` event, the EventData
fields `BugcheckCode`, `BugcheckParameter1`..`BugcheckParameter4`, **looked up by
name** in the event XML (`Data[@Name='...']`), never by array index and never
from the message text. Each is rendered as `0x` plus 8 hex digits
(e.g. `0x00000154`), with a friendly name appended when the code is in the known
list (`0x0000001E`, `0x000000BE`, `0x0000009C`, `0x0000007A`, `0x000000EF`,
`0x00000154`), otherwise `(unknown bugcheck)`. `BugcheckCode = 0` renders
`no bugcheck (power loss or hard reset)`.

**RF-19 — Fast Startup.**
Section `10 POWER` reports Fast Startup state read from
`HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power` value
`HiberbootEnabled` (DWORD):

- `1` -> `ENABLED`, followed by the fixed consequence sentence: *"Shutdown is a
  partial hibernation: pending storage/firmware updates will not activate, and
  'shut down' does not reset device state."* and the remediation hint
  *"Disable with: powercfg /h off (or use Restart instead of Shutdown)."*
- `0` -> `DISABLED`;
- value or key missing -> `not_present`;
- access denied -> `unavailable (access denied)` (RF-27).

**RF-20 — Windows Dynamic Lighting.**
Section `11 LIGHTING` reports Dynamic Lighting state as one of
`enabled`, `disabled`, `not_present`, `unavailable (<reason>)`. The registry
probe path and value name MUST be isolated in one constant so it can be corrected
without touching logic (see OQ-01). When the state is `enabled`, the report MUST
add: *"Windows Dynamic Lighting is enabled: OS-level lighting control supersedes
third-party RGB profiles for supported devices."* Absence of the key MUST render
`not_present` (Windows 10 and pre-22H2 builds), which is not an error.

**RF-21 — Windows Update.**
Section `12 WINDOWS UPDATE` reports the last 5 installed hotfixes
(`HotFixID`, `InstalledOn`, newest first) and pending-update state:

- the pending search MUST run against the **local** update datastore only, i.e.
  `IUpdateSearcher.Online = $false`; a networked search violates RS-02;
- the block renders `pending: <title> (<date>)` when a pending update exists, or
  `pending: none`;
- the date is the local last-successful-search time when available, otherwise
  `unknown`;
- the search is bounded to 15 s; on timeout or COM failure the block renders
  `pending: unavailable (<reason>)` and the run continues.

**RF-22 — Oldest drivers.**
Section `13 DRIVERS` lists the 15 oldest signed drivers by `DriverDate` ascending
from `Win32_PnPSignedDriver`, rendered as
`<yyyy-MM-dd>  <age years with one decimal> y  <device name>  <provider>  <version>`.
Entries with a null or unparsable `DriverDate` are excluded from the ranking and
counted in a `no driver date: <n>` line.

**RF-23 — RGB / lighting software contention.**
Section `11 LIGHTING` MUST detect competing lighting software in two places and
report both:

1. **Services** — every service whose name or display name matches the constant
   pattern list `ArmouryCrate`, `LightingService`, `LEDKeeper`, `MSI_`, `LGHUB`,
   `Razer`, `iCUE`, `NZXT`, `OpenRGB`, `SignalRgb` (case-insensitive), rendered
   with state and start mode, plus a total count.
2. **Autostart entries** — every `Win32_StartupCommand` entry (name, command,
   location, user) whose name or command matches the same pattern list, plus the
   total number of autostart entries.

The section MUST print the fixed sentence when two or more lighting services are
running: *"Multiple lighting services are running; they can contend for the same
HID devices and reset device profiles."*

**RF-24 — TRIM.**
Section `14 MISC` reports TRIM state by running
`fsutil behavior query DisableDeleteNotify` and parsing with the
locale-independent regex `DisableDeleteNotify\s*=\s*(\d)` per line. `0` renders
`enabled`, `1` renders `disabled`, other values render the raw number. When the
command is unavailable or returns no match, render
`unavailable (<reason>)` — never `enabled` by default.

**RF-25 — Pagefile.**
Section `14 MISC` reports pagefile configuration: each pagefile name, allocated
size GB, current usage GB, peak usage GB, and whether the pagefile is
system-managed (`Win32_ComputerSystem.AutomaticManagedPagefile`). Render
`pagefile: system managed` when automatic management is on. No pagefile at all
renders `pagefile: none configured`.

**RF-27 — Unavailable discipline (no false zeros).**
Every value that could not be collected MUST render as `unavailable (<reason>)`
in the report and as JSON `null` in `state.json`. Specifically:

- a query that succeeded and returned no events renders `0`, **followed on the
  same or next line by the query that produced the zero** (RF-13), so a reader
  can distinguish "no events" from "query broken";
- a query that failed renders `unavailable (<exception message, single line>)`
  and MUST NOT render `0`;
- a skipped collector adds its name to `meta.SectionsSkipped` and to
  `problems[]`, and the affected section prints
  `SECTION UNAVAILABLE: <collector> (<reason>)`;
- the report header prints `Elevated: yes|no` and, when `no`, the first line of
  the body is `DEGRADED RUN: not elevated, some collectors require administrator.`

### 5.5 Quick mode

**RF-28 — Quick table content.**
Quick mode prints a table with exactly this row order, one line per row, three
columns (`label`, `total`, `delta`), no progress lines, no sections, no file
paths other than the state path:

| Row label | Source |
|---|---|
| `stornvme 129 (device reset)` | `stornvme_129` |
| `disk 51 (paging error)` | `disk_51` |
| `WHEA 17 (PCIe AER corrected)` | `whea_17` |
| `WHEA 18/19/47 (corrected)` | sum of the three |
| `Kernel-Power 41 (bugcheck)` | `kernel_power_41` |
| `EventLog 6008 (dirty shutdown)` | `eventlog_6008` |
| `App Error 1000` | `app_error_1000` |
| `App Hang 1002` | `app_hang_1002` |
| `WER unique dumps` | `wer.unique_dumps` |
| `WER re-reports` | `wer.repeats` |

Layout, in this exact order: title line; header line carrying host, build,
uptime and window length; baseline line carrying the previous run timestamp and
its age (`baseline: none (first run)` when there is none); the 10-row table; then
one line per fixed volume with its free space (`C: 2.1 % free (9.4 GB)`), one
line per NVMe disk (`Samsung SSD 980 PRO 1TB | FW 5B2QGXA7 | 41 C | wear 3 %`),
and a final `state: <path>` line. Blank separator lines are allowed.

Markers: a row gets a trailing `!` when its delta is `> 0`; the volume line gets
`!` when free percent is `< 10`; the NVMe line gets `!` when temperature is
`>= 70 C`, wear is `>= 80 %`, or `critical_warning != 0`. Total output MUST NOT
exceed **24** lines, and volume and NVMe lines MUST be capped at 4 each
(`+ <n> more volumes not listed`, `+ <n> more NVMe devices not listed`). Colour is
optional and MUST NOT be required to read the table.

**RF-29 — Delta computation.**
With a readable previous state:

- `delta` per counter = number of catalog events with
  `TimeCreated > previous.last_run_at` (strictly greater), computed from the same
  single query pass used for totals (no second query, no double counting);
- `delta` for `WER unique dumps` = size of the current signature set minus the
  previous signature set (`new signatures only`), so a re-report of a known dump
  cannot raise the crash delta;
- `delta` for free space = `current FreeGB - previous FreeGB`, signed, one
  decimal;
- without a previous state, or when `previous.last_run_at` is in the future, or
  when host names differ: every delta renders `-` and the baseline line reads
  `baseline: none (first run)`.

If `previous.last_run_at` is **before** the window start, the delta column renders
`-` and the baseline line reads `baseline: out of window (<date>)`. The query pass
start is `max(window start, last_run_at)` for the delta branch and the window
start for totals; both come from one `Get-WinEvent` call per catalog row.

**RF-30 — State persistence.**
Both modes write `state.json` at the end of a successful run, atomically: write
`state.json.tmp` in `-OutputDir`, then `Move-Item -Force` over `state.json`.

Read rules:

- missing file -> no baseline, no warning;
- unreadable, invalid JSON, or `schema_version != 1` -> rename to
  `state.json.corrupt-<yyyyMMdd-HHmmss>`, print one warning line, continue as a
  first run, exit `0`;
- a write failure is non-fatal: print one warning, exit `0`.

The state MUST contain no absolute path outside the machine's own volume paths
(RF-15 signatures are dump paths — they are kept verbatim because they are the
deduplication key).

### 5.6 Launcher

**RF-31 — UAC launcher (`Run-PcDiagnostics.bat`).**
The launcher MUST let a non-technical operator start a Full run by
double-clicking one file, with a single UAC prompt and no console knowledge.

- Content: ASCII only (every byte `< 0x80`), CRLF line endings, no BOM.
- It MUST invoke `powershell.exe` (not `pwsh`) with `-NoProfile`,
  `-ExecutionPolicy Bypass`, `-File "%~dp0Invoke-PcDiagnostics.ps1"`, elevated
  via `Start-Process -Verb RunAs`.
- The elevated window MUST stay open after the run (`-NoExit`) so the operator
  can read the report path; closing it silently is a defect.
- It MUST pass no arguments and always run `-Mode Full` (parameterised runs are
  for technical users and go through the `.ps1` directly; documenting this is
  enough — the `.bat` stays single-purpose).
- If the operator declines the UAC prompt, the script MUST exit quietly with no
  artifact, no error dialog and no retry loop.

## 6. Non-Functional Requirements

**RNF-01 — Full-mode runtime.** A Full run MUST complete within 180 s on the
reference machine, including up to 90 s of `dxdiag`, excluding the folder-scan
budget (3 x 30 s worst case). Every slow collector MUST have an explicit timeout:
`dxdiag` 90 s, Windows Update search 15 s, folder scan 30 s per volume. Step 8
`Querying event logs` MUST complete within 30 s total for all 19 catalog queries
(per-query timeout 10 s; remaining queries render `unavailable (timeout)`). Quick
mode uses the same step with a 10 s total budget.

**RNF-02 — Quick-mode runtime.** A Quick run MUST complete within 20 s and MUST
NOT invoke `dxdiag`, folder-size scanning, or driver enumeration.

**RNF-03 — Report size.** The report MUST be at most 512 KB on a window with up
to 10,000 event records, with default parameters.

**RNF-04 — PowerShell compatibility.** The code MUST parse and run on Windows
PowerShell 5.1 and PowerShell 7.x. Forbidden constructs (5.1 lacks them):
ternary `? :` expressions, null-coalescing `??`/`??=`, `-Parallel`,
`ForEach-Object -Parallel`, `using namespace`, and class definitions with
initialisers. `Get-CimInstance` MUST be used instead of `Get-WmiObject`.

**RNF-05 — Encoding.** `.ps1` and `.bat` files are ASCII-only (every byte
`< 0x80`). The report is UTF-8 without BOM with CRLF line endings. `state.json`
is UTF-8 without BOM.

**RNF-06 — Zero dependencies.** No Pester, no modules outside
`Microsoft.PowerShell.*`, no PowerShell Gallery downloads, no third-party
binaries. The only external executables are `fsutil.exe` and `dxdiag.exe`, both
shipped with Windows.

## 7. State Contract (`state.json`)

### 7.1 Schema (version 1)

```json
{
  "schema_version": 1,
  "last_run_at": "2026-11-13T18:42:11-03:00",
  "last_run_mode": "Full",
  "host": "DESKTOP-ABC",
  "window_days": 30,
  "elevated": true,
  "off_provider_dropped": 0,
  "counters": {
    "whea_17": 58, "whea_18": 0, "whea_19": 0, "whea_47": 0,
    "stornvme_129": 6, "disk_7": 0, "disk_11": 0, "disk_51": 35, "disk_153": 0,
    "tdr_4101": 2, "tdr_4104": 0, "kernel_power_41": 3,
    "eventlog_6005": 12, "eventlog_6006": 12, "eventlog_6008": 4,
    "app_error_1000": 5, "wer_1001": 6915, "app_hang_1002": 1, "dotnet_1026": 0
  },
  "wer": {
    "events_seen": 6915,
    "unique_dumps": 12,
    "unique_params": 0,
    "unidentified": 0,
    "repeats": 6903,
    "signatures": [
      {
        "signature": "c:\\windows\\minidump\\110326-12345-01.dmp",
        "kind": "dump",
        "count": 173,
        "first_seen": "2026-10-18T21:04:12-03:00",
        "last_seen": "2026-11-12T23:51:07-03:00",
        "app": "game.exe"
      }
    ]
  },
  "volumes": [
    { "mount": "C:", "free_pct": 2.1, "free_gb": 9.4, "size_gb": 448.0 }
  ],
  "nvme": [
    {
      "model": "Samsung SSD 980 PRO 1TB",
      "firmware": "5B2QGXA7",
      "temperature_c": 41,
      "wear_pct": 3,
      "media_errors": 0,
      "unsafe_shutdowns": 12,
      "power_on_hours": 4210,
      "critical_warning": 0,
      "available_spare_pct": 100
    }
  ],
  "boots": { "clean": 12, "dirty": 4 },
  "fast_startup": true,
  "dynamic_lighting": "enabled",
  "windows": { "caption": "Microsoft Windows 11 Pro", "build": "22631.4460" }
}
```

### 7.2 Field types and nullability

| field | type | nullable | enum |
|---|---|---|---|
| `schema_version` | int | no | `1` |
| `last_run_at` | string (ISO 8601 + offset) | no | - |
| `last_run_mode` | string | no | `Full`, `Quick` |
| `host` | string | no | - |
| `window_days` | int | no | - |
| `elevated` | bool | no | - |
| `off_provider_dropped` | int | no (default `0`) | - |
| `counters.<key>` | int | yes | - |
| `wer.events_seen` | int | no | - |
| `wer.unique_dumps` | int | no | - |
| `wer.unique_params` | int | no | - |
| `wer.unidentified` | int | no | - |
| `wer.repeats` | int | no | - |
| `wer.signatures[]` | array | no (empty allowed) | - |
| `wer.signatures[].signature` | string | no | - |
| `wer.signatures[].kind` | string | no | `dump`, `params`, `none` |
| `wer.signatures[].count` | int | no | - |
| `wer.signatures[].first_seen` | string (ISO 8601 + offset) | no | - |
| `wer.signatures[].last_seen` | string (ISO 8601 + offset) | no | - |
| `wer.signatures[].app` | string | yes | - |
| `volumes[]` | array | no (empty allowed) | - |
| `volumes[].mount` | string | no | - |
| `volumes[].free_pct` | number | yes | - |
| `volumes[].free_gb` | number | no | - |
| `volumes[].size_gb` | number | no | - |
| `nvme[]` | array | no (empty allowed) | - |
| `nvme[].model` | string | yes | - |
| `nvme[].firmware` | string | yes | - |
| `nvme[].temperature_c` | int | yes | - |
| `nvme[].wear_pct` | int | yes | - |
| `nvme[].media_errors` | int | yes | - |
| `nvme[].unsafe_shutdowns` | int | yes | - |
| `nvme[].power_on_hours` | int | yes | - |
| `nvme[].critical_warning` | int | yes | - |
| `nvme[].available_spare_pct` | int | yes | - |
| `boots.clean` | int | no | - |
| `boots.dirty` | int | no | - |
| `fast_startup` | bool | yes | - |
| `dynamic_lighting` | string | yes | `enabled`, `disabled`, `not_present` |
| `windows.caption` | string | no | - |
| `windows.build` | string | no | - |

### 7.3 Rules

| Rule | Requirement |
|---|---|
| `schema_version` | Integer, exactly `1`. Any other value is treated as incompatible (RF-30). |
| Timestamps | ISO 8601 with the local UTC offset (`2026-11-13T18:42:11-03:00`). Never epoch numbers, never culture-formatted dates. |
| Numbers | Invariant culture: `.` as decimal separator, no thousands separator, in both `state.json` and the report. A `2,1` in either artifact is a defect under any locale. |
| Unavailable values | JSON `null`. Never `0`, never `""`, never `"n/a"`. |
| `counters` | Every key of the RF-13 catalog MUST be present, even when `0`. A missing key is a defect (it makes the delta silently wrong). |
| `wer.signatures` | Ordered by `count` descending then `signature` ascending; bounded to the same cap as the report listing (RF-16). |
| `volumes` | Fixed volumes only, ordered by mount ascending. |
| `nvme` | One entry per NVMe disk; `null` fields allowed. |
| Growth | The file MUST stay below 256 KB. With RF-16's cap this is automatic. |

### 7.4 Consumers

`state.json` is read by `Read-DiagState`; Full-mode renderers may use **only**
`last_run_at` (to render `since_last_run`); all other report content reflects the
current run. Quick mode additionally uses `counters`, `wer.signatures` and
`volumes` for deltas.

## 8. Output Artifacts

### 8.1 File names

| Mode | Artifacts |
|---|---|
| `Full` | `pc-diagnostics-<host>-<yyyyMMdd-HHmmss>.txt`, `dxdiag-<host>-<yyyyMMdd-HHmmss>.txt` (unless `-SkipDxDiag`), `state.json` |
| `Quick` | `state.json` only |

`<host>` is `$env:COMPUTERNAME`, lowercased, with characters outside
`[a-z0-9-]` replaced by `-`. `<yyyyMMdd-HHmmss>` is local time. A second run in
the same second MUST NOT overwrite the previous artifact: on collision append
`-2`, `-3`, and so on.

### 8.2 Report layout (normative skeleton)

```
====================================================================
 PC DIAGNOSTICS REPORT
====================================================================
Generated      : 2026-11-13 18:42:11 -03:00
Host           : DESKTOP-ABC
Windows        : Microsoft Windows 11 Pro 10.0.22631.4460
Window         : last 30 days (since 2026-10-14 00:00:00)
Mode           : Full
Elevated       : yes
Output dir     : C:\Users\x\pc-diagnostics\reports
Script version : 1.0.0
Off-provider dropped: 0
--------------------------------------------------------------------

=== [01] SYSTEM ===
    DXDIAG (key lines)                    # only when dxdiag ran (RF-12)
    GPU (display adapters)                # always, independent of -SkipDxDiag (RF-08b)
=== [02] CPU ===
=== [03] MEMORY ===
=== [04] STORAGE DEVICES ===
=== [05] VOLUMES ===
=== [06] LARGEST FOLDERS ===
=== [07] EVENT SUMMARY ===
=== [08] CRASHES / WER ===
=== [09] BOOTS ===
=== [10] POWER ===
=== [11] LIGHTING ===
=== [12] WINDOWS UPDATE ===
=== [13] DRIVERS ===
=== [14] MISC ===
====================================================================
 END OF REPORT
====================================================================
```

Rules:

- The 14 sections appear in this order, always, even when a section is empty
  (`SECTION UNAVAILABLE: ...` or `no data`). Sections are never omitted or
  renumbered, so two reports from different versions stay diffable.
- A section body is never empty: at minimum it carries one `unavailable` or
  `no data` line with a reason (RF-27).
- Section `07 EVENT SUMMARY` lists every catalog row as
  `<counter_key>  <provider> <id>  total=<n>  since_last_run=<n|->` followed by
  the `query:` line of RF-13 and the capped listing of RF-16.
- Section `08 CRASHES / WER` starts with the single line
  `WER events: <events_seen> | unique dumps: <n> | signature-only (params): <n> | unidentified: <n> | re-reports: <n>`
  and then the signature table ordered per RF-15.
- Every list has a documented sort key: event lists time descending; modules
  device locator ascending; disks disk number ascending; volumes mount ascending;
  folders and largest files size descending then path ascending; drivers date
  ascending then name ascending; display adapters name ascending; WER signatures
  `count` descending then signature ascending.
- The report is plain text and contains no credentials; no transformation is
  applied.

### 8.3 Quick-mode layout (normative)

```
PC DIAGNOSTICS - QUICK
Host DESKTOP-ABC | Win 11 22631.4460 | uptime 51.2 h | window 30 d
baseline: 2026-11-12 21:10 (21.4 h ago)

stornvme 129 (device reset)          6   +2 !
disk 51 (paging error)              35   +0
WHEA 17 (PCIe AER corrected)        58   +3 !
WHEA 18/19/47 (corrected)            0   +0
Kernel-Power 41 (bugcheck)           3   +1 !
EventLog 6008 (dirty shutdown)       4   +1 !
App Error 1000                       5   +0
App Hang 1002                        1   +0
WER unique dumps                    12   +1
WER re-reports                    6903   +172 !

C: 2.1 % free (9.4 GB) !
Samsung SSD 980 PRO 1TB | FW 5B2QGXA7 | 41 C | wear 3 %
state: C:\Users\x\pc-diagnostics\reports\state.json
```

18 lines including blank separators, under the 24-line ceiling of RF-28.

## 9. Progress Protocol

### 9.1 Steps

Full mode reports exactly these steps, in this order. `N` is 12, or 11 when
`-SkipDxDiag` is passed (step 12 is dropped and the remaining indices are not
renumbered — the run simply has 11 steps in the same order):

| # | Label (literal) | Covers |
|---|---|---|
| 1 | `Collecting system identity` | RF-05, RF-08b |
| 2 | `Collecting CPU information` | RF-06 |
| 3 | `Collecting memory modules` | RF-07 |
| 4 | `Enumerating storage devices` | RF-08 |
| 5 | `Reading NVMe SMART counters` | RF-09 |
| 6 | `Measuring volume free space` | RF-10 |
| 7 | `Scanning largest folders` | RF-11 |
| 8 | `Querying event logs` | RF-13, RF-14 |
| 9 | `Grouping crashes (WER)` | RF-15 |
| 10 | `Reading power, lighting and driver configuration` | RF-17..RF-20, RF-22..RF-25 |
| 11 | `Reading Windows Update history` | RF-21 |
| 12 | `Running dxdiag (may take up to 90 s)` | RF-12 |

### 9.2 Line format

```
[<i>/<N>] <Label> ...
```

- Printed **before** the work starts, flushed immediately (no buffering: the line
  must appear even if the step then blocks for 90 s).
- On success the same line is completed with ` done (<elapsed>s)` where elapsed
  has one decimal, e.g. `[3/12] Collecting memory modules ... done (0.4s)`.
- On failure the same line is completed with ` unavailable (<reason>) (<elapsed>s)`.
- For any step that exceeds 2 s, a `.` is appended every 2 s to the same line
  (heartbeat) until the step finishes, so a 60 s `dxdiag` shows growing dots.
- `i` is strictly increasing 1..N, never repeated, never skipped.
- Progress goes to the host only. It MUST NOT appear in the report file, in
  `state.json`, or on stderr.
- Quick mode prints no progress lines (RF-04).

### 9.3 Rationale (why this is a requirement, not polish)

`dxdiag` blocks for up to 90 s and the folder scan for up to 30 s per volume. A
silent window is indistinguishable from a hung script, and a non-technical
operator kills it. The step counter also gives the operator a way to report
*where* a run failed.

## 10. Security Requirements

**RS-01 — Read-only execution.**
The toolkit MUST NOT modify system state. Forbidden, without exception:
`Set-ItemProperty`, `New-ItemProperty`, `Remove-ItemProperty`, `New-Item`,
`Remove-Item`, `Rename-Item`, `Set-Service`, `Start-Service`, `Stop-Service`,
`New-Service`, `Set-ExecutionPolicy`, `Install-Module`, `Install-Package`,
`Enable-WindowsOptionalFeature`, `Disable-WindowsOptionalFeature`,
`bcdedit`, `powercfg /h off`, `reg add`, `reg delete`, `schtasks`, `sc config`.
Remediation hints are **text only** (RF-19). `Remove-Item`, `Rename-Item` and
`Move-Item` are permitted solely on `state.json*` files inside `-OutputDir` (RF-30).

**RS-02 — Zero network.**
No network call of any kind. Forbidden: `Invoke-WebRequest`,
`Invoke-RestMethod`, `Test-NetConnection`, `Test-Connection`, `Resolve-DnsName`,
`[System.Net.WebClient]`, `[System.Net.Http.HttpClient]`, `curl`, `wget`,
`bitsadmin`, `winhttp`. The Windows Update probe MUST set
`IUpdateSearcher.Online = $false` (RF-21). A single outbound call is a blocking
defect: the report is generated on machines that may be offline, and an
unexpected connection is a trust violation for a read-only tool.

**RS-03 — Write containment.**
The only writes are `pc-diagnostics-*.txt`, `dxdiag-*.txt`, `state.json`,
`state.json.tmp` and `state.json.corrupt-*`, all inside `-OutputDir`. No writes to
`%TEMP%`, the user profile, `ProgramData`, the registry or the startup folder.
`Move-Item -Force` (RF-30) and `Rename-Item` are permitted only on
`state.json*` files inside `-OutputDir`.
`dxdiag /t` MUST be given a path inside `-OutputDir`.

**RS-04 — No persistence, no self-elevation.**
The `.ps1` MUST NOT create scheduled tasks, services, shortcuts or startup
entries, and MUST NOT call `Start-Process -Verb RunAs`. Elevation happens exactly
once, at the `.bat` (RF-31), and only for the duration of the run.

## 11. Test Requirements

**RT-01 — Self-contained runner.**
`tests/run-tests.ps1` implements its own harness: `Assert-Equal`, `Assert-Match`,
`Assert-True`, `Assert-Throws`, `Assert-Null`, `Assert-LessOrEqual`. No Pester,
no external module, no `Invoke-Pester`. It prints one `PASS <name>` or
`FAIL <name> :: <expected/actual>` line per test, a final
`TOTAL <n> PASSED <n> FAILED <n> DURATION <s>s`, and exits `0` only when every
test passed. It accepts an optional `-Filter <substring>` to run a subset.

**RT-02 — Cross-platform, no Windows needed.**
The suite MUST run to completion with `pwsh tests/run-tests.ps1` on Linux
(PowerShell 7), with no administrator rights, no registry access and no network.
Therefore every Windows dependency MUST sit behind a dot-sourceable function that
the stubs can shadow; `tests/run-tests.ps1` MUST NOT dot-source
`Invoke-PcDiagnostics.ps1`.

**RT-03 — Stub mechanism.**
`tests/stubs.ps1` defines functions named exactly like the cmdlets they replace
(`Get-WinEvent`, `Get-CimInstance` including `Win32_VideoController`,
`Get-PhysicalDisk`, `Get-Disk`, `Get-Volume`, `Get-StorageReliabilityCounter`,
`Get-NvmeHealthLog`, `Get-ItemProperty`, `Get-HotFix`,
`Get-Service`, `Get-ChildItem`, `Get-Content`) that read `tests/fixtures/*.json`
and are selected by an environment variable or parameter naming the fixture set
(e.g. `$env:PCDIAG_FIXTURE = 'wer-repeated-dump'`). Every stub appends its
arguments to `$global:PcDiagCallLog` so tests can assert *how* a cmdlet was
called, not only what came back. A stub MUST throw when a required filter
argument is missing, mirroring RF-14.

**RT-04 — Mandatory test cases.**
The following cases are required. Their names are normative so a reviewer can
check presence mechanically.

| Test name | Fixture | Assertion |
|---|---|---|
| `T01-whea-provider-filter` | `whea-mixed-system-log.json`: `System` log containing 2 real `Microsoft-Windows-WHEA-Logger` 17, 3 `WindowsUpdateClient` 19, 2 `TPM` 18, 1 `disk` 51 | `whea_17 == 2`, `whea_18 == 0`, `whea_19 == 0`; no counter named `19` carries 3; `meta.off_provider_dropped == 0` |
| `T02-provider-guard` | none | `Get-DiagEvent -LogName System -Id 19` throws `PROVIDER_FILTER_REQUIRED`; `Get-DiagEvent -LogName System -ProviderName 'disk'` throws `ID_FILTER_REQUIRED` |
| `T03-offprovider-drop` | stub returns a `WindowsUpdateClient` 19 event for a `stornvme` 129 query | `stornvme_129 == 0` and `meta.off_provider_dropped == 1` |
| `T04-wer-dedupe-dump` | `wer-repeated-dump.json`: dump A x173, B x2, C x1, D x1 | `events_seen == 177`, `unique_dumps == 4`, `repeats == 173`, `unidentified == 0`; A's `count == 173` |
| `T05-wer-params-fallback` | `wer-params-only.json`: no `.dmp` path, `P1..P10` repeated for 2 distinct groups | `unique_params == 2`, `unique_dumps == 0`, `repeats == (events_seen - 2)` |
| `T06-wer-unidentified` | `wer-no-signature.json`: 3 events with neither path nor `P*` | `unique_dumps == 0`, `unidentified == 3`, `repeats == 0` |
| `T07-listing-cap-and-size` | `wer-flood.json`: 10,000 `wer_1001` events across 4 signatures | report `<= 524288` bytes; `<= 20` WER listing lines; overflow line contains `9980 more not listed` |
| `T08-state-delta` | `state-v1.json` with counters and `last_run_at` 24 h ago | `since_last_run` equals only events strictly after that timestamp; `new_signatures` counts only unseen signatures |
| `T09-state-corrupt` | `state-corrupt.json` (truncated JSON) | no exception; backup file `state.json.corrupt-*` created; baseline renders `none (first run)`; exit `0` |
| `T10-unavailable-not-zero` | storage fixtures without NVMe health log | NVMe fields render `unavailable (no NVMe health log)`, state serialises `null`, and no `0` is emitted for them |
| `T11-locale-es` | `es-ES-messages.json`: Spanish message bodies, same providers/IDs | classification identical to the English fixture; `kernel_power_41` BugcheckCode `0x00000154` extracted by field name |
| `T12-security-scan` | source tree | no forbidden cmdlet/pattern of RS-01/RS-02 appears in `*.ps1`; no non-ASCII byte in `*.ps1`/`*.bat`; `.bat` has CRLF endings |
| `T13-progress-protocol` | full-mode snapshot, captured progress sink | exactly `N` progress lines, indices `1..N` strictly increasing, `N == 11` when `-SkipDxDiag` |

**RT-05 — Bug fixtures are mandatory.**
`T01`, `T03`, `T04`, `T05` and `T06` are the regression barrier for sections 1.2
and 1.3. Removing or weakening any of them is a spec violation. The fixtures MUST
be synthetic: no real hostnames, user names, serial numbers or dump paths from the
field machine.

**RT-06 — Size and time budgets are tested, not assumed.**
`T07` MUST assert on the byte size of the produced report (not on a line count)
and MUST use the default `-MaxEventsPerCategory`. The whole suite MUST finish in
under 60 s.

**RT-07 — Test-side hygiene.**
Tests write only under a temporary directory that they create and delete; they
never touch the registry, network, or the repository working tree; they are
order-independent and repeatable.

## 12. Edge Cases

Each case states the situation, the required behaviour, and the scenario that
verifies it. "Continue" always means exit code `0` with the affected section
degraded per RF-27 — never a silent zero.

**EC-01 — Not elevated.**
Situation: the process is not running as administrator, so `MSStorageDriver_*`,
some event logs and parts of `Win32_PnPSignedDriver` are unreadable.
Required: header shows `Elevated: no`; first body line is
`DEGRADED RUN: not elevated, some collectors require administrator.`; restricted
sections render `unavailable (access denied)`; collect everything that is still
readable; continue.

**EC-02 — No NVMe device.**
Situation: only SATA/USB disks, or no disks at all.
Required: the NVMe block renders `no NVMe device`; `state.json` stores `"nvme": []`;
Quick mode prints `no NVMe device` on the NVMe line; no collector throws.

**EC-03 — Event log is empty.**
Situation: the log exists but holds no event inside the window.
Required: every counter renders `0` **with its query line** (RF-27). This is a
successful query, not a failure, and MUST NOT render `unavailable`.

**EC-04 — `Get-WinEvent` throws the "no events" error.**
Situation: `Get-WinEvent` raises `No events were found that match the specified
selection criteria` (HRESULT `0x80070490`).
Required: treat as an empty result (counter `0`, query line printed). Any other
exception is a failure and renders `unavailable (<message>)`. The distinction is
by HRESULT, never by matching the localised exception text.

**EC-05 — Localised event messages.**
Situation: Spanish, Portuguese or any other Windows display language. Message
bodies, level names and `fsutil` output are translated.
Required: classification uses only log name, provider name, event ID and
EventData **field names**; `fsutil` is parsed with the token regex of RF-24; the
only message-text read permitted anywhere is the `.dmp` path regex of RF-15
(paths are not localised). Two fixtures with identical IDs and different
languages MUST produce identical counts.

**EC-07 — `dxdiag` missing or timing out.**
Situation: `dxdiag.exe` is absent (stripped Windows image) or takes longer than
90 s.
Required: render `dxdiag: unavailable (missing)` or `(timeout)`; the step
completes as `unavailable`; the remaining 13 sections are unaffected; the raw
dxdiag file is either complete or absent, never half-written into the report.

**EC-08 — Output directory not writable.**
Situation: `-OutputDir` is on a read-only or permission-denied path.
Required: fail fast with exit `2` and one error line naming the path, before any
collection starts. No partial report, no state file.

**EC-10 — Multiline and oversized event messages.**
Situation: a message contains CR/LF and thousands of characters (a stack trace,
a WER block).
Required: exactly one report line per event; CR/LF collapsed to spaces; message
truncated to 160 characters plus `...`. The 160-character cap is applied after
collapsing, so a message that is 1 line of 4000 characters and a message of 400
lines both produce one bounded line.

**EC-11 — Incompatible `state.json` version.**
Situation: `schema_version` 2 (written by a newer build) or a syntactically valid
JSON with missing keys.
Required: set the file aside as `state.json.corrupt-<timestamp>`, print one
warning, continue as a first run. Never partially read an incompatible file: a
half-read baseline is worse than no baseline.

**EC-13 — Baseline older than the window.**
Situation: `state.json` carries a `last_run_at` that is **before** the start of
the current `-Days` window (e.g. 40 days ago with `-Days 30`).
Required: the delta column renders `-` and the baseline line reads
`baseline: out of window (<date>)`; totals still cover the whole window; the query
pass starts at `max(window start, last_run_at)` for the delta branch and at the
window start for totals, from one `Get-WinEvent` call per catalog row. Never print
a delta that silently undercounts, never throw, exit `0`.

## 13. Traceability

Every requirement declared in this document is referenced by at least one
scenario tag in `specs/pc-diagnostics.feature`. Machine check:

```
grep -o '@[A-Z]\{2,3\}-[0-9]\{2\}[a-z]\?' specs/pc-diagnostics.feature | sort -u
```

Totals: 31 functional (RF), 6 non-functional (RNF), 4 security (RS), 7 test (RT),
10 edge cases (EC) = 58 requirements, 66 scenarios.

Identifiers retired by the v1 scope cut (`RF-26`, `RNF-07`, `RS-05`, `EC-06`,
`EC-09`, `EC-12`) are not reused, so the gaps in the sequence are intentional.

| Requirement | Scenarios | First scenario |
|---|---|---|
| `RF-01` | 2 | Full mode is the default and writes one report (+1 more) |
| `RF-02` | 1 | Invalid parameter value is rejected before any collection |
| `RF-03` | 3 | Quick mode writes no report file (+2 more) |
| `RF-04` | 1 | Quick mode skips the expensive collectors |
| `RF-05` | 1 | System identity section reports OS, firmware and uptime |
| `RF-06` | 1 | CPU section reports cores, threads and socket |
| `RF-07` | 1 | Memory section separates rated speed from running speed |
| `RF-08` | 1 | Storage inventory renders bus types by name |
| `RF-08b` | 1 | Display adapters are reported without depending on dxdiag |
| `RF-09` | 2 | NVMe SMART counters are reported per field (+1 more) |
| `RF-10` | 1 | Every volume reports free space in percent and in gigabytes |
| `RF-11` | 1 | Largest folders are bounded and marked partial |
| `RF-12` | 1 | dxdiag block reflects the run outcome |
| `RF-13` | 2 | WHEA counts ignore Windows Update and TPM events with the same IDs (+1 more) |
| `RF-14` | 2 | An event query without a full filter is rejected (+1 more) |
| `RF-15` | 4 | Repeated reports of one dump count as one unique dump (+3 more) |
| `RF-16` | 3 | Event listings are capped with an explicit overflow line (+2 more) |
| `RF-17` | 1 | Boots are classified clean or dirty from EventLog events |
| `RF-18` | 1 | Bugcheck code is read by field name under a non-English locale |
| `RF-19` | 1 | Enabled Fast Startup is reported with its consequence |
| `RF-20` | 1 | Dynamic Lighting state is reported without inventing a value |
| `RF-21` | 1 | Update history is read offline |
| `RF-22` | 1 | Oldest drivers are ranked by date |
| `RF-23` | 1 | Competing lighting software is detected in services and autostart |
| `RF-24` | 1 | TRIM state is parsed by token, not by language |
| `RF-25` | 1 | Pagefile configuration is reported |
| `RF-27` | 4 | A degraded run still produces a complete report (+3 more) |
| `RF-28` | 2 | Quick mode prints the fixed counter table (+1 more) |
| `RF-29` | 3 | Deltas count only events after the previous run (+2 more) |
| `RF-30` | 2 | Both modes persist a comparable state (+1 more) |
| `RF-31` | 1 | The launcher elevates once and keeps the window open |
| `RNF-01` | 1 | A full run stays inside its time budget |
| `RNF-02` | 1 | Quick mode skips the expensive collectors |
| `RNF-03` | 1 | A 10000-event window still produces a shareable report |
| `RNF-04` | 1 | The code parses and runs on Windows PowerShell 5.1 |
| `RNF-05` | 1 | Source and artifact encodings are fixed |
| `RNF-06` | 1 | The test runner is self-contained |
| `RS-01` | 1 | The toolkit never mutates the system |
| `RS-02` | 2 | Update history is read offline (+1 more) |
| `RS-03` | 1 | Writes stay inside the output directory |
| `RS-04` | 1 | The toolkit never mutates the system |
| `RT-01` | 1 | The test runner is self-contained |
| `RT-02` | 1 | The suite runs on Linux PowerShell with stubs |
| `RT-03` | 2 | The suite runs on Linux PowerShell with stubs (+1 more) |
| `RT-04` | 1 | The suite contains the two defect-regression cases |
| `RT-05` | 1 | The suite contains the two defect-regression cases |
| `RT-06` | 2 | A 10000-event window still produces a shareable report (+1 more) |
| `RT-07` | 1 | Size and duration budgets are asserted by the suite |
| `EC-01` | 1 | A non-elevated run degrades instead of failing |
| `EC-02` | 1 | A machine without NVMe still produces a complete report |
| `EC-03` | 1 | An empty log is reported as an attributable zero |
| `EC-04` | 1 | The no-events exception is treated as an empty result |
| `EC-05` | 2 | Bugcheck code is read by field name under a non-English locale (+1 more) |
| `EC-07` | 1 | A missing dxdiag binary does not abort the run |
| `EC-08` | 1 | An unwritable output directory is fatal and loud |
| `EC-10` | 1 | Event messages stay on one line and are truncated |
| `EC-11` | 2 | A corrupt state is set aside, not fatal (+1 more) |
| `EC-13` | 1 | An out-of-window baseline yields no delta |

## 14. Open Questions

Each question has a default resolution so implementation is never blocked. A
resolution that turns out wrong is a spec change, not an implementation
deviation.

**OQ-01 — Exact registry location of the Windows Dynamic Lighting state.**
The probe path and value name for `HKCU`/`HKLM` Dynamic Lighting vary between
Windows 11 builds and are not documented as a stable API. Default resolution:
isolate the probe in one constant `$DynamicLightingKey` in
`lib/Collect-Config.ps1`; absence of the key renders `not_present` (which is also
the correct answer on Windows 10 and pre-22H2 builds); the implementation MUST
record the exact path it probed in the section body as
`Dynamic Lighting: <state> (probe: <path>)` so the value is auditable. This
detail is cosmetic to the report's purpose (RF-23's service contention list
carries the real signal) and MUST NOT delay implementation.

**OQ-02 — Stability of the dxdiag key-line allowlist.**
`dxdiag` label text changes across Windows versions and languages. Default
resolution: match labels case-insensitively and fall back to
`dxdiag: no key lines matched` rather than failing the step; cap at 40 lines.
The raw file is always kept, so nothing is lost.

**OQ-03 — Should Quick mode also append a one-line history log?**
Not required by G1-G5 and it grows the write surface. Default resolution: no.
Quick writes only `state.json`; history is recoverable by diffing successive
states.

## 15. Design Decisions

Recorded here because each one is a choice a reviewer might otherwise challenge.

**AD-01 — One catalog constant instead of scattered queries.** Defect 1.2
happened because a query looked correct in isolation. Centralising log, provider
and IDs in a single table makes the omission of a provider a *visible* defect
(a column is empty) rather than an invisible one. RF-13.

**AD-02 — Defense in depth on the provider filter.** Filtering in
`-FilterHashtable` is correct but depends on the event source honouring it. A
post-filter that drops off-provider events and *counts them* turns a silent
wrong number into a reported anomaly (`Off-provider dropped: N`). RF-14.

**AD-03 — WER signatures are stored readable, not hashed.** A hashed key is
compact but undebuggable: when a count looks wrong, the operator can read the
path and check the file exists. State size is bounded by RF-16, so the space
saving buys nothing. RF-15.

**AD-04 — Events with no signature go to `unidentified`, not to a synthetic
bucket.** Grouping them under a constant key would either merge unrelated crashes
or inflate the unique count. Reporting them separately keeps both numbers honest
and makes the gap visible. RF-15.

**AD-05 — Deltas come from `last_run_at`, not from subtracting window counts.**
Subtracting two 30-day window totals is not "events since last run" — an event
leaving the window can cancel a new event entering it, showing a delta of 0 while
errors are happening. Counting events newer than the previous run timestamp is
exact. RF-29.

**AD-06 — `unavailable` is a first-class value, `0` is a measurement.** Both
defects were, at bottom, failures to distinguish "nothing happened" from "I could
not look". Requiring an explicit `unavailable (<reason>)` string and a JSON
`null` makes the distinction structural. RF-27, EC-03, EC-04.

**AD-07 — One snapshot object is the only seam.** Collection produces a plain
object; rendering consumes only that object. Renderers can therefore be tested on
Linux with fixtures, and a collector can be tested without a renderer.
Section 4.4, RT-02.

**AD-08 — Both modes write state.** Quick mode is the monitor, but a Full run is
the natural baseline. If only Quick wrote state, the first run after a Full report
would always be a first run. RF-30.

**AD-09 — Fixed 14 sections, fixed 12 progress steps.** Stable section numbering
keeps reports diffable across weeks and versions; stable step numbering makes the
progress contract testable (`N` is 11 or 12, nothing else). Section 8.2,
Section 9.1.

**AD-10 — 512 KB is an explicit contract, not a hope.** The incident output was
3 MB. A number that a test can assert (RT-06) is the only kind of size limit that
survives refactoring. RNF-03, RF-16.

**AD-12 — The launcher keeps its window open.** The target operator double-clicks
a `.bat` and reads the result; a window that closes on completion loses the
report path. `-NoExit` is a UX requirement, not an oversight.
RF-31.

**AD-13 — No remediation code, only remediation text.** Every fix (disable Fast
Startup, free disk space, turn off an RGB service) is destructive or at least
state-changing. A read-only tool that also "fixes" cannot be run on a machine
someone depends on. RS-01.

---

**Out of scope for v1:** a findings engine with severity thresholds.
