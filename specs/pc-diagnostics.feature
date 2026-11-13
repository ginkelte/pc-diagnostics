---
title: PC Diagnostics Toolkit - Acceptance Criteria
type: gherkin
spec: specs/pc-diagnostics.spec.md
created: 2026-11-13
updated: 2026-11-13
tags: [powershell, windows, diagnostics, event-log, storage, acceptance]
---

Feature: PC diagnostics toolkit
  As a support engineer facing a Windows machine that crashes games
  I want one read-only command that reports hardware, storage health, power configuration and a correctly counted crash history
  So that I can find the real cause instead of chasing inflated event counts

  # ════════════════════════════════════════════════════════════
  # INVOCATION AND MODES - RF-01 .. RF-04
  # ════════════════════════════════════════════════════════════

  # ── RF-01: Mode selection ──

  @RF-01
  Scenario: Full mode is the default and writes one report
    Given a Windows host with events inside the default 30-day window
    When the operator runs the script with no parameters
    Then the effective mode is Full
    And exactly one file matching "pc-diagnostics-*-*.txt" exists in the output directory
    And the run exits with code 0

  @RF-01 @RF-03
  Scenario: Quick mode writes no report file
    Given an output directory containing only a previous "state.json"
    When the operator runs the script with "-Mode Quick"
    Then the console shows the quick table
    And no file matching "pc-diagnostics-*.txt" exists in the output directory
    And no file matching "dxdiag-*.txt" exists in the output directory

  # ── RF-02: Parameter validation ──

  @RF-02
  Scenario Outline: Invalid parameter value is rejected before any collection
    Given no previous state file exists
    When the operator runs the script with "<invocation>"
    Then the run exits with code 1
    And stderr names the parameter "<parameter>"
    And no report file and no state file are created

    Examples:
      | invocation                      | parameter              |
      | -Mode Verbose                   | Mode                   |
      | -Days 0                         | Days                   |
      | -Days 400                       | Days                   |
      | -MaxEventsPerCategory -1        | MaxEventsPerCategory   |
      | -TopFolders 0                   | TopFolders             |
      | -NoSuchSwitch                   | NoSuchSwitch           |

  # ── RF-03: Full-mode artifacts ──

  @RF-03
  Scenario: Report file carries host and timestamp and never overwrites
    Given two Full runs start within the same second on host "DESKTOP-ABC"
    When both runs finish
    Then the output directory contains "pc-diagnostics-desktop-abc-<timestamp>.txt"
    And the second run creates a distinct file name rather than overwriting the first

  @RF-03 @RF-27
  Scenario: A degraded run still produces a complete report
    Given the NVMe SMART collector fails with "access denied"
    When a Full run finishes
    Then the report file exists and is larger than 0 bytes
    And the report contains a "SECTION UNAVAILABLE" line for that collector
    And all 14 sections are present
    And the run exits with code 0

  # ── RF-04: Quick-mode artifacts ──

  @RF-04 @RNF-02
  Scenario: Quick mode skips the expensive collectors
    Given a fixture where folder scanning and dxdiag would each take 60 seconds
    When the operator runs the script with "-Mode Quick"
    Then no folder-size scan is performed
    And "dxdiag" is never executed
    And no installed-driver enumeration is performed
    And the run finishes in under 20 seconds

  # ════════════════════════════════════════════════════════════
  # COLLECTION - RF-05 .. RF-12
  # ════════════════════════════════════════════════════════════

  # ── RF-05: System identity ──

  @RF-05
  Scenario: System identity section reports OS, firmware and uptime
    Given a host whose last boot was 51.2 hours ago on build "22631.4460"
    When a Full run finishes
    Then section "01 SYSTEM" contains the OS caption, version and build "22631.4460"
    And section "01 SYSTEM" contains the BIOS vendor, SMBIOS version and release date
    And section "01 SYSTEM" contains "uptime 51.2 h"
    And no raw TimeSpan such as "2.03:11:44" appears in the section

  # ── RF-06: CPU ──

  @RF-06
  Scenario: CPU section reports cores, threads and socket
    Given a host with a "11th Gen Intel Core i7-11700" with 8 cores, 16 threads and socket "LGA1200"
    When a Full run finishes
    Then section "02 CPU" contains "8 cores / 16 threads"
    And section "02 CPU" contains "LGA1200"
    And section "02 CPU" contains the base and max clock in MHz

  # ── RF-07: Memory modules ──

  @RF-07
  Scenario: Memory section separates rated speed from running speed
    Given two DDR4 modules rated at 3600 MT/s running at 3200 MT/s in slots DIMM_A1 and DIMM_B1
    When a Full run finishes
    Then every module line contains "rated (SPD/XMP)" and "running"
    And the report contains "memory running below module rating"
    And the report contains "rated 3600 MT/s, running 3200 MT/s"
    And the totals line reports 2 populated slots out of 4 total slots

  # ── RF-08: Storage inventory ──

  @RF-08
  Scenario: Storage inventory renders bus types by name
    Given one NVMe disk and one SATA disk
    When a Full run finishes
    Then section "04 STORAGE DEVICES" contains the firmware version of both disks
    And the bus type is rendered as "NVMe" and "SATA"
    And no line renders a raw bus-type integer such as "BusType=17"

  # ── RF-08b: Display adapters ──

  @RF-08b
  Scenario: Display adapters are reported without depending on dxdiag
    Given a host with one display adapter "NVIDIA GeForce RTX 3070", driver version "31.0.15.3699", driver date "2024-04-11" and 8 GB of VRAM
    When a Full run finishes with "-SkipDxDiag"
    Then section "01 SYSTEM" contains a "GPU (display adapters)" block
    And the block reports the adapter name, driver version, driver date and VRAM in GB
    And the block reports the current resolution and refresh rate when the adapter provides them
    And the block is present even though dxdiag was skipped

  # ── RF-09: NVMe SMART ──

  @RF-09
  Scenario: NVMe SMART counters are reported per field
    Given an NVMe disk with temperature 41 C, wear 3 percent, 12 unsafe shutdowns and 0 media errors
    When a Full run finishes
    Then section "04 STORAGE DEVICES" contains "temperature 41 C"
    And it contains "percentage_used 3 %"
    And it contains "unsafe_shutdowns 12"
    And it contains "media_errors 0"
    And the firmware version is printed on the same block

  @RF-09 @RF-27
  Scenario: A missing NVMe health log yields unavailable, never zero
    Given an NVMe disk whose health log byte array is absent
    When a Full run finishes
    Then the byte-derived SMART fields render "unavailable (no NVMe health log)"
    And "state.json" stores null for those fields
    And no byte-derived field renders "0"

  # ── RF-10: Volume free space ──

  @RF-10
  Scenario: Every volume reports free space in percent and in gigabytes
    Given a fixed volume "C:" of 448.0 GB with 9.4 GB free
    When a Full run finishes
    Then section "05 VOLUMES" contains "448.0 GB total"
    And it contains "9.4 GB free"
    And it contains "2.1 % free"
    And the line is marked "LOW"

  # ── RF-11: Largest folders ──

  @RF-11
  Scenario: Largest folders are bounded and marked partial
    Given a volume whose root contains 30 child folders and 250000 files
    When the folder scan reaches its file cap
    Then section "06 LARGEST FOLDERS" lists at most 10 folders sorted by size descending
    And the affected line ends with "PARTIAL (scan stopped: file cap)"
    And the section states scanned bytes versus volume used bytes
    And the section lists the largest individual files per volume as "<path> <size> GB" ordered by size descending then path ascending
    And the file listing carries the same "PARTIAL" marker when the budget or cap stopped the scan
    And no reparse point is followed

  # ── RF-12: Optional dxdiag ──

  @RF-12
  Scenario Outline: dxdiag block reflects the run outcome
    Given the run is invoked with "<flag>"
    And dxdiag "<outcome>"
    When a Full run finishes
    Then section "01 SYSTEM" renders "<expected>"
    And the remaining 13 sections are unaffected

    Examples:
      | flag           | outcome  | expected                                     |
      | (no flag)      | succeeds | a "DXDIAG (key lines)" block with at most 40 lines |
      | -SkipDxDiag    | n/a      | "dxdiag: skipped (-SkipDxDiag)"              |
      | (no flag)      | times out | "dxdiag: unavailable (timeout)"             |

  # ════════════════════════════════════════════════════════════
  # DEFECT CLOSURE: EVENT PROVIDER FILTERING - RF-13, RF-14
  # ════════════════════════════════════════════════════════════

  # ── RF-13: Provider AND ID filtering ──

  @RF-13
  Scenario: WHEA counts ignore Windows Update and TPM events with the same IDs
    Given a System log fixture with these events:
      | provider                      | id | count |
      | Microsoft-Windows-WHEA-Logger | 17 | 2     |
      | WindowsUpdateClient           | 19 | 3     |
      | TPM                           | 18 | 2     |
      | disk                          | 51 | 1     |
    When the event collector runs over a 30-day window
    Then counter "whea_17" is 2
    And counter "whea_18" is 0
    And counter "whea_19" is 0
    And no counter reports 3 for Id 19
    And the report does not contain the label "machine check" for those counts

  @RF-13
  Scenario: Every counter is labelled with its provider and prints its query
    Given a collected event summary
    When section "07 EVENT SUMMARY" is rendered
    Then each line reads "<counter_key> <provider> <id> total=<n> since_last_run=<value>"
    And each line is followed by a "query: LogName=... ProviderName=... Id=... since=..." line
    And the label for the WHEA rows is "WHEA correctable errors (Microsoft-Windows-WHEA-Logger)"

  # ── RF-14: Query guard ──

  @RF-14
  Scenario Outline: An event query without a full filter is rejected
    Given the event helper is loaded
    When it is called with "<arguments>"
    Then it throws a terminating error with code "<code>"
    And no event is returned

    Examples:
      | arguments                                  | code                     |
      | -LogName System -Id 19                     | PROVIDER_FILTER_REQUIRED |
      | -LogName System -ProviderName "  " -Id 19  | PROVIDER_FILTER_REQUIRED |
      | -LogName System -ProviderName disk         | ID_FILTER_REQUIRED       |

  @RF-14
  Scenario: Events returned for the wrong provider are dropped
    Given a stub that returns a WindowsUpdateClient event with Id 19 for a "stornvme" Id 129 query
    When the event collector runs
    Then counter "stornvme_129" is 0
    And "meta.off_provider_dropped" is 1
    And the report header shows "Off-provider dropped: 1"

  # ════════════════════════════════════════════════════════════
  # DEFECT CLOSURE: WER DEDUPLICATION AND OUTPUT BOUNDS - RF-15, RF-16
  # ════════════════════════════════════════════════════════════

  # ── RF-15: WER deduplication ──

  @RF-15
  Scenario: Repeated reports of one dump count as one unique dump
    Given an Application log fixture with 177 Windows Error Reporting Id 1001 events:
      | dump | reports |
      | A    | 173     |
      | B    | 2       |
      | C    | 1       |
      | D    | 1       |
    When the WER aggregator runs
    Then "events_seen" is 177
    And "unique_dumps" is 4
    And "repeats" is 173
    And "unidentified" is 0
    And the signature ranked first has count 173

  @RF-15
  Scenario: WER events without a dump path fall back to P1..P10
    Given two distinct groups of Id 1001 events whose messages contain no ".dmp" path
    And whose EventData carries P1..P10 fields
    When the WER aggregator runs
    Then "unique_dumps" is 0
    And "unique_params" is 2
    And "repeats" equals "events_seen" minus 2
    And the signature is built from the P fields, never from message text

  @RF-15
  Scenario: WER events without any signature are surfaced, not counted as dumps
    Given 3 Id 1001 events with neither a ".dmp" path nor P fields
    When the WER aggregator runs
    Then "unique_dumps" is 0
    And "unidentified" is 3
    And "repeats" is 0
    And section "08 CRASHES / WER" shows "unidentified: 3"

  @RF-15
  Scenario: The headline crash number is unique dumps
    Given the WER summary for a 30-day window with 6915 events and 12 unique dumps
    When the report and the quick table are rendered
    Then both show "unique dumps: 12" as the crash figure
    And both show the 6903 re-reports as a separate number
    And the string "crashes: 6915" appears nowhere

  # ── RF-16: Bounded output ──

  @RF-16
  Scenario: Event listings are capped with an explicit overflow line
    Given a category with 250 matching events and "-MaxEventsPerCategory 20"
    When the section is rendered
    Then the listing contains exactly 20 event lines
    And the next line reads "... 230 more not listed (see counts above)"

  @RF-16 @RNF-03 @RT-06
  Scenario: A 10000-event window still produces a shareable report
    Given a fixture with 10000 event records across 4 WER signatures
    When a Full run writes the report with default parameters
    Then the report file is at most 524288 bytes
    And the WER listing contains at most 20 lines
    And the overflow line reports 9980 omitted records

  @RF-16
  Scenario: Zero listing cap renders counts only
    Given the run is invoked with "-MaxEventsPerCategory 0"
    When section "07 EVENT SUMMARY" is rendered
    Then no event listing line is present
    And the counts are still present
    And no overflow line is printed

  # ════════════════════════════════════════════════════════════
  # STABILITY AND CONFIGURATION - RF-17 .. RF-27
  # ════════════════════════════════════════════════════════════

  # ── RF-17: Boot classification ──

  @RF-17
  Scenario: Boots are classified clean or dirty from EventLog events
    Given a System log with 6006 at 08:00, 6005 at 08:01, 6005 at 20:00 and 6008 at 20:05
    When section "09 BOOTS" is rendered
    Then the 08:01 event is "clean boot"
    And the 20:00 event is "dirty boot (unclean start)"
    And the 20:05 event is "dirty shutdown (unexpected)"
    And the section reports "clean boots: 1" and "dirty boots: 1"

  # ── RF-18: Kernel-Power 41 ──

  @RF-18 @EC-05
  Scenario: Bugcheck code is read by field name under a non-English locale
    Given a Spanish-locale Kernel-Power Id 41 event whose EventData has BugcheckCode 340
    When section "10 POWER" is rendered
    Then the code is rendered as "0x00000154"
    And the friendly name "UNEXPECTED_STORE_EXCEPTION" is appended
    And the value is not taken from the localised message text

  # ── RF-19: Fast Startup ──

  @RF-19
  Scenario: Enabled Fast Startup is reported with its consequence
    Given "HiberbootEnabled" is 1 in the Session Manager Power key
    When section "10 POWER" is rendered
    Then the state reads "ENABLED"
    And the consequence sentence about partial hibernation is present
    And the remediation hint "powercfg /h off" is present
    And no registry value is written

  # ── RF-20: Dynamic Lighting ──

  @RF-20
  Scenario Outline: Dynamic Lighting state is reported without inventing a value
    Given the Dynamic Lighting probe returns "<state>"
    When section "11 LIGHTING" is rendered
    Then the line begins with "Dynamic Lighting: <state>" and appends "(probe: <path>)"
    And the OS-level lighting note appears only when the state is "enabled"

    Examples:
      | state       |
      | enabled     |
      | disabled    |
      | not_present |

  # ── RF-21: Windows Update ──

  @RF-21 @RS-02
  Scenario: Update history is read offline
    Given 7 installed hotfixes and one pending update in the local datastore
    When section "12 WINDOWS UPDATE" is rendered
    Then exactly 5 hotfixes are listed, newest first
    And the pending block reads "pending: <title> (<date>)"
    And the update search was performed with Online set to false

  # ── RF-22: Oldest drivers ──

  @RF-22
  Scenario: Oldest drivers are ranked by date
    Given 40 signed drivers with parseable dates and 3 with null dates
    When section "13 DRIVERS" is rendered
    Then exactly 15 drivers are listed, oldest first
    And each line shows the date and age in years with one decimal
    And the section reports "no driver date: 3"

  # ── RF-23: RGB contention ──

  @RF-23
  Scenario: Competing lighting software is detected in services and autostart
    Given services "ArmouryCrateService" and "LEDKeeper2" are running
    And an autostart entry runs "C:\Program Files\LGHUB\lghub.exe"
    When section "11 LIGHTING" is rendered
    Then both services are listed with their state and start mode
    And the autostart entry is listed with name, command, location and user
    And the contention sentence about multiple lighting services is present

  # ── RF-24: TRIM ──

  @RF-24
  Scenario Outline: TRIM state is parsed by token, not by language
    Given fsutil prints "<output>"
    When section "14 MISC" is rendered
    Then the TRIM line reads "<expected>"

    Examples:
      | output                                          | expected |
      | NTFS DisableDeleteNotify = 0                    | enabled  |
      | NTFS DisableDeleteNotify = 1                    | disabled |
      | NTFS DisableDeleteNotify = 0 ReFS DisableDeleteNotify = 0 | enabled |

  # ── RF-25: Pagefile ──

  @RF-25
  Scenario: Pagefile configuration is reported
    Given a system-managed pagefile of 16 GB allocated and 3.2 GB in use
    When section "14 MISC" is rendered
    Then the line reports the allocated and current sizes in GB
    And it reports "pagefile: system managed"

  # ── RF-27: Unavailable discipline ──

  @RF-27
  Scenario: A zero is always attributable to a query
    Given a query for "stornvme" Id 129 that returns no events
    When the section is rendered
    Then the count renders as 0
    And the query line "LogName=System ProviderName=stornvme Id=129" is printed next to it

  @RF-27
  Scenario: A failed query never renders as zero
    Given a query that throws "The RPC server is unavailable"
    When the section is rendered
    Then the count renders as "unavailable (The RPC server is unavailable)"
    And the string "0" is not printed for that counter
    And "state.json" stores null for that counter

  # ════════════════════════════════════════════════════════════
  # QUICK MODE - RF-28 .. RF-30
  # ════════════════════════════════════════════════════════════

  # ── RF-28: Quick table ──

  @RF-28
  Scenario: Quick mode prints the fixed counter table
    Given a collected snapshot
    When the quick renderer runs
    Then the rows appear in the order stornvme 129, disk 51, WHEA 17, WHEA 18/19/47, Kernel-Power 41, EventLog 6008, App Error 1000, App Hang 1002, WER unique dumps, WER re-reports
    And the table has the columns label, total and delta
    And the output ends with the volume line, the NVMe line and the state path
    And the output is at most 24 lines
    And volume and NVMe lines are capped at 4 each with a "+ <n> more ... not listed" line when truncated
    And no progress line is printed

  @RF-28
  Scenario: Markers flag what needs attention
    Given a delta of 2 for "stornvme_129" and a volume at 2.1 percent free
    When the quick renderer runs
    Then the stornvme row ends with "!"
    And the volume line ends with "!"

  # ── RF-29: Delta ──

  @RF-29
  Scenario: Deltas count only events after the previous run
    Given a previous state with "last_run_at" 24 hours ago and "stornvme_129" at 4
    And 2 new stornvme 129 events since then, with 6 in the 30-day window
    When Quick mode runs
    Then the stornvme row shows total 6 and delta "+2"
    And the WER crash delta counts only signatures absent from the previous state

  @RF-29
  Scenario: Without a baseline every delta is a dash
    Given no "state.json" exists
    When Quick mode runs
    Then the baseline line reads "baseline: none (first run)"
    And every delta column shows "-"
    And the run exits with code 0

  @EC-13 @RF-29
  Scenario: An out-of-window baseline yields no delta
    Given a previous state whose "last_run_at" is 40 days ago
    And the run is invoked with "-Days 30"
    When Quick mode runs
    Then the baseline line reads "baseline: out of window (<date>)"
    And every delta column shows "-"
    And the totals still cover the full 30-day window
    And the run exits with code 0

  # ── RF-30: State persistence ──

  @RF-30
  Scenario: Both modes persist a comparable state
    Given a Full run followed by a Quick run
    When the second run starts
    Then it finds the state written by the first run
    And the state file was replaced atomically via a temporary file
    And every catalog counter key is present in the state, including zeros

  @RF-30 @EC-11
  Scenario: A corrupt state is set aside, not fatal
    Given a truncated "state.json"
    When any mode runs
    Then the file is renamed to "state.json.corrupt-<timestamp>"
    And one warning line is printed
    And the run continues as a first run and exits with code 0

  # ════════════════════════════════════════════════════════════
  # NON-FUNCTIONAL BUDGETS - RNF-01 .. RNF-06
  # ════════════════════════════════════════════════════════════

  # ── RNF-01: Full-mode runtime ──

  @RNF-01
  Scenario: A full run stays inside its time budget
    Given a reference host with a 448 GB system volume and a dxdiag run of 60 seconds
    When a Full run completes
    Then the non-folder-scan wall clock is at most 180 seconds and the folder scan is bounded to 30 seconds per volume
    And dxdiag carries a 90 second timeout, the update search 15 seconds, and the event-log step a 30 second total budget for all 19 catalog queries with a 10 second per-query timeout

  # ── RNF-04: PowerShell 5.1 compatibility ──

  @RNF-04
  Scenario: The code parses and runs on Windows PowerShell 5.1
    Given the full source tree
    When it is parsed by the PowerShell 5.1 grammar
    Then it contains no ternary expression, no null-coalescing operator, no "-Parallel" and no "using namespace"
    And every WMI read goes through Get-CimInstance

  # ── RNF-05: Encoding ──

  @RNF-05
  Scenario: Source and artifact encodings are fixed
    Given a completed Full run
    When the bytes of the artifacts and of the sources are inspected
    Then every ".ps1" and ".bat" byte is below 0x80
    And the report has CRLF line endings and no byte order mark
    And "state.json" is UTF-8 without a byte order mark

  # ════════════════════════════════════════════════════════════
  # LAUNCHER AND SECURITY - RF-31, RS-01 .. RS-04
  # ════════════════════════════════════════════════════════════

  # ── RF-31: Launcher ──

  @RF-31
  Scenario: The launcher elevates once and keeps the window open
    Given the file "Run-PcDiagnostics.bat"
    When its bytes are inspected
    Then every byte is below 0x80 and every line ends with CRLF
    And it invokes "Start-Process -Verb RunAs"
    And it passes "-ExecutionPolicy Bypass", "-NoProfile", "-NoExit" and "-File"
    And it passes no arguments to the script

  # ── RS-01 .. RS-04: Security ──

  @RS-01 @RS-04
  Scenario: The toolkit never mutates the system
    Given the full source tree
    When it is scanned for state-changing commands
    Then no call to Set-ItemProperty, New-ItemProperty, New-Item, Set-Service, Start-Service, Stop-Service, New-Service, Set-ExecutionPolicy, Install-Module, bcdedit, schtasks or "reg add" exists
    And the only permitted Remove-Item, Rename-Item or Move-Item targets are state files inside the output directory
    And the script never calls "Start-Process -Verb RunAs" itself

  @RS-02
  Scenario: No network call exists anywhere
    Given the full source tree
    When it is scanned for network primitives
    Then none of Invoke-WebRequest, Invoke-RestMethod, Test-NetConnection, Test-Connection, System.Net.WebClient, System.Net.Http.HttpClient, curl, wget or bitsadmin appears
    And the Windows Update search sets Online to false

  @RS-03
  Scenario: Writes stay inside the output directory
    Given a Full run with "-OutputDir C:\temp\reports"
    When the run completes
    Then every file created by the run is inside "C:\temp\reports"
    And nothing is written to the registry, the user profile, ProgramData or the startup folder
    And "dxdiag" received a target path inside "C:\temp\reports"

  # ════════════════════════════════════════════════════════════
  # TEST SUITE - RT-01 .. RT-07
  # ════════════════════════════════════════════════════════════

  # ── RT-01: Runner ──

  @RT-01 @RNF-06
  Scenario: The test runner is self-contained
    Given the file "tests/run-tests.ps1"
    When it runs on a machine without Pester installed
    Then it imports no module and calls no "Invoke-Pester"
    And it prints one PASS or FAIL line per test and a TOTAL line
    And it exits 0 when all tests pass and 1 when any test fails

  # ── RT-02, RT-03: Portability and stubs ──

  @RT-02 @RT-03
  Scenario: The suite runs on Linux PowerShell with stubs
    Given "pwsh" 7 on Linux with no Windows cmdlets available
    When "pwsh tests/run-tests.ps1" runs
    Then every Windows cmdlet call is served by a stub from "tests/stubs.ps1"
    And the entry script "Invoke-PcDiagnostics.ps1" is never dot-sourced by the suite
    And the suite finishes with exit code 0

  @RT-03
  Scenario: Stubs record how they were called
    Given a stub for Get-WinEvent
    When the collector queries it
    Then the recorded arguments contain a non-empty ProviderName, a non-empty Id array and a StartTime
    And the stub throws if ProviderName is missing

  # ── RT-04, RT-05: Mandatory bug regressions ──

  @RT-04 @RT-05
  Scenario: The suite contains the two defect-regression cases
    Given the mandatory case list of the specification
    When the suite runs
    Then a case named "T01-whea-provider-filter" passes
    And a case named "T04-wer-dedupe-dump" passes
    And both fixtures are synthetic, with no field hostname, user name or serial number

  # ── RT-06, RT-07: Budgets and hygiene ──

  @RT-06 @RT-07
  Scenario: Size and duration budgets are asserted by the suite
    Given the 10000-event fixture
    When the size test runs
    Then it asserts the report byte size is at most 524288
    And the whole suite finishes in under 60 seconds
    And no test touches the registry, the network or the repository working tree

  # ════════════════════════════════════════════════════════════
  # EDGE CASES - EC-01 .. EC-13
  # ════════════════════════════════════════════════════════════

  # ── EC-01: Not elevated ──

  @EC-01
  Scenario: A non-elevated run degrades instead of failing
    Given the process is not elevated
    When a Full run finishes
    Then the header reads "Elevated: no"
    And the first body line reads "DEGRADED RUN: not elevated, some collectors require administrator."
    And restricted sections render "unavailable (access denied)"
    And the run exits with code 0

  # ── EC-02: No NVMe ──

  @EC-02
  Scenario: A machine without NVMe still produces a complete report
    Given only SATA disks are present
    When a Full run finishes
    Then the NVMe SMART block reads "no NVMe device"
    And no collector throws
    And the quick table prints the NVMe line as "no NVMe device"

  # ── EC-03: Empty event log ──

  @EC-03
  Scenario: An empty log is reported as an attributable zero
    Given a System log with no events in the window
    When the event collector runs
    Then every counter renders 0 with its query line
    And no counter renders "unavailable"

  # ── EC-04: Get-WinEvent "no events" exception ──

  @EC-04
  Scenario: The no-events exception is treated as an empty result
    Given Get-WinEvent throws "No events were found that match the specified selection criteria" (0x80070490)
    When the collector handles the error
    Then the counter is 0 and not "unavailable"
    And the run does not fail

  # ── EC-05: Localised event messages ──

  @EC-05
  Scenario: Classification never depends on message language
    Given the same providers and IDs with Spanish and with English message bodies
    When both fixtures are classified
    Then the counters and the boot classification are identical
    And the only text read from a message is the ".dmp" path of a WER event

  # ── EC-07: dxdiag missing ──

  @EC-07
  Scenario: A missing dxdiag binary does not abort the run
    Given "dxdiag.exe" is not present on the system
    When a Full run finishes
    Then the dxdiag block reads "dxdiag: unavailable" with a reason
    And the run exits with code 0
    And the report contains all 14 sections

  # ── EC-08: Unwritable output directory ──

  @EC-08
  Scenario: An unwritable output directory is fatal and loud
    Given "-OutputDir" points to a path that cannot be created or written
    When the run starts
    Then it prints a single error naming the path
    And it exits with code 2
    And no partial report is left behind

  # ── EC-10: Multiline and oversized messages ──

  @EC-10
  Scenario: Event messages stay on one line and are truncated
    Given an event whose message contains 6 lines and 4000 characters
    When it is listed in the report
    Then it occupies exactly one line
    And the rendered message is at most 163 characters including the trailing "..."
    And no CR or LF from the message reaches the report

  # ── EC-11: Incompatible state version ──

  @EC-11
  Scenario: A newer state schema is not half-read
    Given a "state.json" with "schema_version" 2
    When any mode runs
    Then the file is set aside as "state.json.corrupt-<timestamp>"
    And the run proceeds as a first run
    And no field of the incompatible file is used as a baseline
