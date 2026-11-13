# pc-diagnostics

A read-only Windows diagnostic toolkit that produces a report you can trust.

One command collects hardware, storage health, event-log evidence and
configuration state, and writes a plain-text report you can send to someone
else for a second opinion. A second mode prints an 18-line summary and tells you
whether anything came back since the last run.

---

## Why this exists

This tool was written after a real diagnostic where a home-made script got the
answer wrong in two expensive ways.

**It reported 6,915 program crashes in 30 days.** The real number was 12.
Windows Error Reporting had re-reported the same 12 crash dumps 173 times each
because it could not upload them. The output file was 3 MB of duplicates, and
the actual signal - twelve distinct crashes - was buried in it.

**It reported 317 CPU and memory machine-check errors.** The real number was 0.
The script had counted every event with ID 18, 19 and 47 in the System log.
Event IDs in Windows are scoped **per provider**, so it had silently absorbed
Windows Update events and TPM events and labelled them as hardware failures.

Both bugs pointed at the wrong hardware. Both are now impossible by
construction, and both are covered by fixtures in the test suite.

---

## The two guarantees

**1. No count is ever reported without its provider.**
Every event query names the log, the provider, and the event ID, and every
count in the output is printed next to the provider it came from. Asking for a
count without a provider raises an error instead of returning a number.

**2. Missing data is never rendered as a number.**
A collector that fails - no administrator rights, a command that is absent, a
timeout - renders `unavailable` with the reason. It never renders `0`, and it
never renders an empty string. A degraded run is labelled `DEGRADED RUN` at the
top of the report, so whoever reads it knows what is missing rather than
assuming nothing was found.

The toolkit is also **read-only and offline**: no network calls, no registry
writes, no installs, no service changes. The only files it creates are the
artifacts inside its output directory.

---

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- Administrator rights for the complete dataset. Without elevation the run
  still completes, but storage reliability counters and some WMI classes are
  unavailable and are marked as such.

No modules, no installation, no dependencies.

---

## Quick start

Double-click **`Run-PcDiagnostics.bat`**. It asks for elevation once, runs the
full diagnostic, and leaves the window open so you can read the report path.

Or from a terminal:

```powershell
.\Invoke-PcDiagnostics.ps1                      # full report, last 30 days
.\Invoke-PcDiagnostics.ps1 -Days 7              # narrower window
.\Invoke-PcDiagnostics.ps1 -Mode Quick          # 18-line summary, 24 max
.\Invoke-PcDiagnostics.ps1 -SkipDxDiag          # 11 steps instead of 12
```

Artifacts land in `.\reports\` by default:

```
reports/
  pc-diagnostics-<host>-<timestamp>.txt    the report
  dxdiag-<host>-<timestamp>.xml            dxdiag /x output, when not skipped
  state.json                               baseline for the next run
```

---

## What it collects

| Section | Contents |
|---|---|
| System | Host, OS build, install date, uptime, elevation state |
| CPU | Name, cores, threads, clock, load |
| Memory | Per module: manufacturer, part number, declared vs configured speed, configured voltage, slot, total slots |
| GPU | Every display adapter: name, driver version, driver date, VRAM |
| Storage | Disks, firmware, bus, health, plus NVMe SMART: critical warning, available spare, percentage used, media integrity errors, unsafe shutdowns, power-on hours, temperature |
| Volumes | Size and free space per volume in GB **and percent** |
| Largest folders / files | Top N directories and top N individual files per volume, with a time and file budget and a `PARTIAL` marker when it is hit |
| Event summary | 19 counter rows, each with provider and ID |
| WER | Unique dumps, unique parameter signatures, unidentified, re-reports - as four separate numbers |
| Boots | Last 10 boots classified clean vs dirty |
| Power | Fast Startup (`HiberbootEnabled`), power plan, page file configuration |
| Lighting | Windows Dynamic Lighting state, with the probe path that was tested |
| Windows Update | Installed KBs and whether an update is pending |
| Drivers | The oldest signed drivers by driver date |
| Misc | TRIM status, RGB and lighting services, startup entries |
| Failures | Not a section of its own: a collector that cannot deliver renders `unavailable (<reason>)` inline, in the section that needed it |

---

## Reading the report

Each event counter renders one line plus an audit line:

```
whea_17  Microsoft-Windows-WHEA-Logger 17  total=4  since_last_run=0
  label: WHEA 17 correctable error, PCIe AER (Microsoft-Windows-WHEA-Logger)
  query: LogName=System ProviderName=Microsoft-Windows-WHEA-Logger Id=17 since=2026-10-14T00:00:00
```

The `query:` line is the point. It prints exactly what was asked of the event
log, so a reader can verify the number instead of trusting it. If someone hands
you a report with machine-check counts, you can check which provider produced
them.

Event classification is done by provider and ID, and by the `Data[@Name]`
attributes in the event XML - never by matching message text. On a Spanish or
German Windows the messages are localised; the IDs are not.

---

## Quick mode and deltas

`-Mode Quick` prints a fixed table and nothing else: 24 lines maximum, four
volume lines, four NVMe lines, and one delta per counter against the previous
run.

```
PC DIAGNOSTICS - QUICK
Host workstation | Win 11 Pro 26200 | uptime 3.2 h | window 30 d
baseline: 2026-11-10 18:22 (71.5 h ago)

stornvme 129 (device reset)                6             +0
disk 51 (paging error)                     35            +0
WHEA 17 (PCIe AER corrected)               58            +0
WHEA 18 fatal, 19/47 corrected             0             +0
Kernel-Power 41 (bugcheck)                 12            +0
EventLog 6008 (dirty shutdown)             5             +0
App Error 1000                             72            +0
App Hang 1002                              unavailable   -
WER unique dumps                           12            +0
WER re-reports                             172           +0

C: 21.2 % free (197.1 GB)
state: C:\diag\reports\state.json
```

The second column is the count inside the window; the third is what arrived
since the baseline - `+0` means nothing new, `-` means there is no usable
baseline for that counter, and `unavailable` means the query itself failed.
This is the mode to run after a change: it answers "did the errors come back" in
three seconds without reading a report.

A volume below 10% free is flagged with ` !`. NVMe disks add one line each,
and both blocks are capped at four lines so the ceiling always holds.

`state.json` is the baseline. It records every counter, the WER signatures, the
volumes and the firmware-relevant fields. It is read on the next run and
rewritten. If it is missing the run reports `baseline: none (first run)`; if it
is older than the window the delta column renders `-` and the baseline line
says `baseline: out of window (<date>)` - it does not silently under-count. An
unusable state file is set aside as `state.json.corrupt-<timestamp>` rather than
deleted.

*Example output above; values vary by machine.*

---

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-Mode` | `Full` | `Full` writes a report; `Quick` prints the summary table |
| `-Days` | `30` | Lookback window, 1 to 365 |
| `-OutputDir` | `.\reports` | Artifact directory, created if missing |
| `-MaxEventsPerCategory` | `20` | Listing lines per event category. `0` = counts only |
| `-TopFolders` | `10` | Largest folders and files per volume |
| `-SkipDxDiag` | off | Skip dxdiag; 11 progress steps instead of 12 |

Exit codes: `0` completed (a degraded run is still 0), `1` invalid invocation,
`2` fatal - output directory not writable or report could not be written.

Full runs print numbered progress with per-step timings, so a slow step such as
dxdiag never looks like a hang:

```
[7/11] Scanning largest folders ... done (2.4s)
[8/11] Querying event logs ... done (1.1s)
```

---

## Tests

```powershell
pwsh -File .\tests\run-tests.ps1
```

The suite is self-contained: no Pester, no modules, no Windows required. It
stubs every Windows cmdlet, so it runs on Linux under `pwsh` as well, which is
how it is developed.

Fixtures cover both historical bugs directly: a System log containing
`WindowsUpdateClient` ID 19 and TPM ID 18 events that must **not** be counted as
machine checks, and a crash-dump fixture of 184 WER events - one dump repeated
173 times alongside eleven distinct dumps - which must count as 12 unique dumps
with 172 re-reports.

---

## Scope and versioning

The specification lives in `specs/` and is the source of truth for behaviour:
`pc-diagnostics.spec.md` holds the requirements and `pc-diagnostics.feature` the
Gherkin acceptance criteria.

Deliberately **not** in v1: a findings engine that scores a machine and prints
verdicts. Severity thresholds are judgement calls that belong to whoever reads
the report, not to the tool that produced the numbers.

---

## License

MIT. See `LICENSE`.
