# tests/fixtures/snapshot-builder.ps1
#
# Hand-built snapshots. The renderers (New-FullReport, Format-QuickReport) and
# the state writer (New-DiagState) are pure functions of a snapshot, so the only
# honest way to test them off-Windows is to construct the snapshot object the
# collectors would have produced. Nothing here reads the machine: every field is
# either a parameter or a constant of this file.
#
# The shape follows lib/Common.ps1 New-DiagSnapshot exactly; a section left out
# would make a renderer print "unavailable" and hide a regression, so every
# top-level key is present even when it is degraded.

function New-TestCounters {
    <#
      Ordered counter map for every catalog key. Default: a successful query that
      found nothing (total 0, no delta, no error) - the EC-03 shape. -Values
      overrides single keys, and a $null total there means "query failed", which
      must render as unavailable and never as 0.
    #>
    param($Values = $null)

    $map = [ordered]@{}
    foreach ($row in (Get-DiagEventCatalog)) {
        $map[[string]$row.Key] = @{ total = 0; since_last_run = $null; error = $null }
    }
    if ($null -ne $Values) {
        $keys = @()
        if ($Values -is [System.Collections.IDictionary]) { $keys = @($Values.Keys) } else { $keys = @($Values.PSObject.Properties.Name) }
        foreach ($key in $keys) {
            $entry = $null
            if ($Values -is [System.Collections.IDictionary]) { $entry = $Values[$key] } else { $entry = $Values.$key }
            $total = 0
            $delta = $null
            $error = $null
            if ($null -ne $entry) {
                if ($entry -is [System.Collections.IDictionary]) {
                    if ($entry.Contains('total')) { $total = $entry['total'] }
                    if ($entry.Contains('since_last_run')) { $delta = $entry['since_last_run'] }
                    if ($entry.Contains('error')) { $error = $entry['error'] }
                } else {
                    $total = $entry.total
                    $delta = $entry.since_last_run
                    $error = $entry.error
                }
            }
            $map[[string]$key] = @{ total = $total; since_last_run = $delta; error = $error }
        }
    }
    return $map
}

function New-TestStateCounters {
    <#
      Flat counter map as persisted in state.json (counter key -> integer). This
      is NOT the snapshot shape: the state keeps the total only, and
      Compare-DiagState subtracts two of these maps. Passing a snapshot-shaped
      map here would hand it a hashtable where it expects a number.
    #>
    param($Values = $null)

    $map = [ordered]@{}
    foreach ($row in (Get-DiagEventCatalog)) { $map[[string]$row.Key] = 0 }
    if ($null -ne $Values) {
        $keys = @()
        if ($Values -is [System.Collections.IDictionary]) { $keys = @($Values.Keys) } else { $keys = @($Values.PSObject.Properties.Name) }
        foreach ($key in $keys) {
            $value = $null
            if ($Values -is [System.Collections.IDictionary]) { $value = $Values[$key] } else { $value = $Values.$key }
            $map[[string]$key] = $value
        }
    }
    return $map
}

function New-TestWerSignature {
    param(
        [string]$Signature,
        [string]$Kind = 'dump',
        [int]$Count = 1,
        $FirstSeen = $null,
        $LastSeen = $null,
        [string]$App = $null
    )
    return [pscustomobject]@{
        signature  = $Signature
        kind       = $Kind
        count      = $Count
        first_seen = $FirstSeen
        last_seen  = $LastSeen
        app        = $App
    }
}

function New-TestWerSummary {
    <#
      The five numbers that must never be merged (defect 1.3), plus the delta
      fields Format-QuickReport reads.
    #>
    param(
        [int]$EventsSeen = 0,
        [int]$UniqueDumps = 0,
        [int]$UniqueParams = 0,
        [int]$Unidentified = 0,
        [int]$Repeats = 0,
        $Signatures = @(),
        $NewSignatures = $null,
        [bool]$DeltaAvailable = $false
    )
    return [pscustomobject]@{
        events_seen     = $EventsSeen
        unique_dumps    = $UniqueDumps
        unique_params   = $UniqueParams
        unidentified    = $Unidentified
        repeats         = $Repeats
        signatures      = @($Signatures)
        new_signatures  = $NewSignatures
        delta_available = $DeltaAvailable
    }
}

function New-TestVolume {
    param(
        [Parameter(Mandatory = $true)][string]$Mount,
        $FreePct = $null,
        $FreeGB = $null,
        $SizeGB = $null,
        [string]$FileSystem = 'NTFS'
    )
    return [pscustomobject]@{
        Mount      = $Mount
        FileSystem = $FileSystem
        SizeGB     = $SizeGB
        FreeGB     = $FreeGB
        FreePct    = $FreePct
    }
}

function New-TestDisk {
    param(
        [int]$Number = 0,
        [string]$FriendlyName = 'Test NVMe Device',
        [string]$BusType = 'NVMe',
        [string]$FirmwareVersion = '1.0.0',
        $Smart = $null,
        $SizeGB = 1000.0,
        [string]$HealthStatus = 'Healthy',
        [string]$SerialNumber = 'TEST-SERIAL-0001'
    )
    return [pscustomobject]@{
        DiskNumber        = $Number
        FriendlyName      = $FriendlyName
        SerialNumber      = $SerialNumber
        FirmwareVersion   = $FirmwareVersion
        BusType           = $BusType
        MediaType         = 'SSD'
        SizeGB            = $SizeGB
        HealthStatus      = $HealthStatus
        OperationalStatus = 'OK'
        PartitionStyle    = 'GPT'
        Smart             = $Smart
    }
}

function New-TestSmart {
    param(
        $TemperatureC = 41,
        $PercentageUsed = 3,
        $CriticalWarning = 0,
        $AvailableSparePct = 100,
        $PowerOnHours = 1200,
        $UnsafeShutdowns = 4,
        $MediaErrors = 0,
        $PredictFailure = $false
    )
    return [pscustomobject]@{
        TemperatureC      = $TemperatureC
        PercentageUsed    = $PercentageUsed
        CriticalWarning   = $CriticalWarning
        AvailableSparePct = $AvailableSparePct
        PowerOnHours      = $PowerOnHours
        UnsafeShutdowns   = $UnsafeShutdowns
        MediaErrors       = $MediaErrors
        PredictFailure    = $PredictFailure
    }
}

function New-TestNvmeLog {
    <#
      One 512-byte NVMe SMART/Health Information log page (log page 02h) with
      values chosen so every field can be checked by hand:

        byte    0      critical warning        1
        bytes   1-2    composite temperature   315 K (0x013B) -> 42 C
        byte    3      available spare         100 %
        byte    4      spare threshold         10 %
        byte    5      percentage used         7 %
        bytes  32-47   data units read         1000
        bytes  48-63   data units written      all 16 bytes FFh: the 128-bit
                                               value is far beyond 64 bits, so
                                               it must saturate, not wrap
        bytes  64-79   host read commands      1234567890123456  (fits, exact)
        bytes  80-95   host write commands     987654321
        bytes  96-111  controller busy time    4242 minutes
        bytes 112-127  power cycles            42
        bytes 128-143  power-on hours          12345
        bytes 144-159  unsafe shutdowns        3
        bytes 160-175  media errors            2
        bytes 176-191  error log entries       5

      Bytes the parser does not read stay 0.
    #>
    $bytes = New-Object byte[] 512

    # 64-bit little-endian writer; the 128-bit saturation case is written by hand.
    $putUInt64 = {
        param([byte[]]$Buffer, [int]$Offset, [long]$Value)
        for ($i = 0; $i -lt 8; $i++) {
            $Buffer[$Offset + $i] = [byte](($Value -shr (8 * $i)) -band 0xFF)
        }
    }

    $bytes[0] = 1                        # critical warning
    $bytes[1] = 0x3B                     # temperature 315 K, low byte
    $bytes[2] = 0x01                     # temperature 315 K, high byte
    $bytes[3] = 100                      # available spare %
    $bytes[4] = 10                       # available spare threshold %
    $bytes[5] = 7                        # percentage used %

    & $putUInt64 $bytes 32 ([long]1000)                    # data units read
    for ($i = 48; $i -lt 64; $i++) { $bytes[$i] = 0xFF }   # data units written
    & $putUInt64 $bytes 64 ([long]1234567890123456)        # host read commands
    & $putUInt64 $bytes 80 ([long]987654321)               # host write commands
    & $putUInt64 $bytes 96 ([long]4242)                    # controller busy
    & $putUInt64 $bytes 112 ([long]42)                     # power cycles
    & $putUInt64 $bytes 128 ([long]12345)                  # power-on hours
    & $putUInt64 $bytes 144 ([long]3)                      # unsafe shutdowns
    & $putUInt64 $bytes 160 ([long]2)                      # media errors
    & $putUInt64 $bytes 176 ([long]5)                      # error log entries

    return ,$bytes
}

function New-TestSnapshot {
    <#
      A complete snapshot object. Without -Full every section is present but
      degraded ("not collected"), which keeps a renderer test small; -Full fills
      the sections with plausible data so a size or layout assertion is measured
      on a representative report rather than on 14 "SECTION UNAVAILABLE" lines.
    #>
    param(
        [int]$WindowDays = 30,
        # [object], not [datetime]: a null default cannot bind to a typed
        # DateTime parameter, and "no window given" has to be expressible.
        $WindowStart = $null,
        [string]$HostName = 'TEST-HOST',
        $Counters = $null,
        $Listings = $null,
        $ListingsMeta = $null,
        $Wer = $null,
        [object[]]$Volumes = @(),
        [object[]]$Disks = @(),
        [switch]$StorageAvailable,
        [switch]$Full,
        [string]$StatePath = 'C:\temp\reports\state.json',
        [string]$OutputDir = 'C:\temp\reports',
        [int]$OffProviderDropped = 0,
        [object[]]$BootEntries = @()
    )

    if ($null -eq $WindowStart) { $WindowStart = (Get-Date).Date.AddDays(-1 * $WindowDays) }
    if (-not ($WindowStart -is [datetime])) {
        $WindowStart = [datetime]::Parse([string]$WindowStart, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $now = Get-Date

    $counterMap = $Counters
    if ($null -eq $counterMap) { $counterMap = New-TestCounters }

    $catalog = Get-DiagEventCatalog
    if ($null -eq $Wer) { $Wer = New-TestWerSummary }

    # Default: every catalog row was queried successfully and found nothing.
    $listingMap = @{}
    $metaMap = @{}
    foreach ($row in $catalog) {
        $listingMap[[string]$row.Key] = @()
        $metaMap[[string]$row.Key] = @{ shown = 0; omitted = 0; cap = 20 }
    }
    if ($null -ne $Listings) {
        $keys = @()
        if ($Listings -is [System.Collections.IDictionary]) { $keys = @($Listings.Keys) } else { $keys = @($Listings.PSObject.Properties.Name) }
        foreach ($key in $keys) {
            if ($Listings -is [System.Collections.IDictionary]) { $listingMap[[string]$key] = @($Listings[$key]) } else { $listingMap[[string]$key] = @($Listings.$key) }
        }
    }
    if ($null -ne $ListingsMeta) {
        $keys = @()
        if ($ListingsMeta -is [System.Collections.IDictionary]) { $keys = @($ListingsMeta.Keys) } else { $keys = @($ListingsMeta.PSObject.Properties.Name) }
        foreach ($key in $keys) {
            if ($ListingsMeta -is [System.Collections.IDictionary]) { $metaMap[[string]$key] = $ListingsMeta[$key] } else { $metaMap[[string]$key] = $ListingsMeta.$key }
        }
    }

    if ($Full) {
        $system = [pscustomobject]@{
            Available        = $true
            Caption          = 'Windows 11 Pro'
            Version          = '10.0.22631'
            Build            = '10.0.22631.4460'
            Edition          = 'Professional'
            InstallDate      = '2025-04-02T10:00:00-03:00'
            UptimeHours      = 51.2
            Manufacturer     = 'Test Vendor'
            Model            = 'Test Machine 1'
            BaseboardProduct = 'TESTBOARD'
            BiosVendor       = 'Test Firmware'
            BiosVersion      = '1.0.0'
            BiosDate         = '2024-01-15T00:00:00-03:00'
        }
        $cpu = [pscustomobject]@{
            Available  = $true
            Name       = 'Test CPU 8-Core'
            Cores      = 8
            Threads    = 16
            Socket     = 'AM5'
            BaseMHz    = 3800
            MaxMHz     = 5200
            CoreThread = '8C/16T'
        }
        $memory = [pscustomobject]@{
            Available      = $true
            Modules        = @(
                [pscustomobject]@{ Manufacturer = 'TestRAM'; PartNumber = 'TR-16G-6000'; CapacityGB = 16.0; Type = 'DDR5'; RatedMHz = 6000; RunningMHz = 4800; Voltage = 1.2; DeviceLocator = 'DIMM 0'; BankLabel = 'BANK 0' },
                [pscustomobject]@{ Manufacturer = 'TestRAM'; PartNumber = 'TR-16G-6000'; CapacityGB = 16.0; Type = 'DDR5'; RatedMHz = 6000; RunningMHz = 4800; Voltage = 1.2; DeviceLocator = 'DIMM 1'; BankLabel = 'BANK 1' }
            )
            BelowRated     = @()
            TotalGB        = 32.0
            PopulatedSlots = 2
            TotalSlots     = 4
        }
        $gpu = [pscustomobject]@{
            Available = $true
            Adapters  = @([pscustomobject]@{ Name = 'Test GPU'; DriverVersion = '31.0.15.3623'; DriverDate = '2025-06-01T00:00:00-03:00'; VramGB = 12.0; Resolution = '2560x1440'; RefreshHz = 165 })
        }
        if ($Disks.Count -eq 0) {
            $Disks = @(New-TestDisk -Number 0 -FriendlyName 'Test NVMe Device' -Smart (New-TestSmart))
        }
        if ($Volumes.Count -eq 0) {
            $Volumes = @(New-TestVolume -Mount 'C:\' -FreePct 12.9 -FreeGB 120.3 -SizeGB 930.5)
        }
        $storageAvailable = $true
        $bootEntries = @(
            [pscustomobject]@{ TimeCreated = $WindowStart.AddDays(1); Id = 6006; ProviderName = 'EventLog'; Kind = 'clean'; Label = 'clean shutdown' },
            [pscustomobject]@{ TimeCreated = $WindowStart.AddDays(1).AddMinutes(2); Id = 6005; ProviderName = 'EventLog'; Kind = 'clean'; Label = 'clean boot' }
        )
        $power = [pscustomobject]@{
            Available      = $true
            FastStartup    = 'enabled'
            FastStartupConsequence = 'Fast Startup is on: a shutdown is a hibernation, so boot counts and uptime are not what they look like.'
            FastStartupHint = 'Run "powercfg /h off" only if you need real shutdown semantics.'
            BugcheckCodes  = @([pscustomobject]@{ Code = 340; CodeHex = '0x00000154'; Friendly = 'UNEXPECTED_STORE_EXCEPTION'; Parameters = @('0x1', '0x2') })
            Pagefile       = [pscustomobject]@{ AutomaticManaged = $true; Entries = @() }
        }
        $lighting = [pscustomobject]@{
            Available           = $true
            DynamicLighting     = 'enabled'
            DynamicLightingNote = 'Dynamic Lighting is on; ambient effects may keep a lighting service running.'
            Services            = @([pscustomobject]@{ Name = 'LightingService'; DisplayName = 'Lighting Service'; State = 'Running'; StartMode = 'Automatic' })
            RunningServices     = 1
            StartupCommands     = @([pscustomobject]@{ Name = 'Lighting'; Command = 'lighting.exe'; Location = 'Startup'; User = 'TEST-USER' })
            StartupTotal        = 1
            ContentionFlag      = $false
        }
        $update = [pscustomobject]@{
            Available    = $true
            LatestKbs    = @(
                [pscustomobject]@{ HotFixID = 'KB0000001'; InstalledOn = '2026-11-05T00:00:00-03:00'; Description = 'Cumulative Update' },
                [pscustomobject]@{ HotFixID = 'KB0000002'; InstalledOn = '2026-10-20T00:00:00-03:00'; Description = 'Servicing Stack Update' }
            )
            Pending      = $null
            PendingState = 'none'
            SearchDate   = '2026-11-10T00:00:00-03:00'
        }
        $drivers = [pscustomobject]@{
            Available     = $true
            OldestDrivers = @(
                [pscustomobject]@{ DateText = '2016-03-01T00:00:00-03:00'; AgeYears = 10.6; Name = 'Legacy Device'; Provider = 'Test Vendor'; Version = '1.0.0.0' }
            )
            NoDriverDate  = 0
        }
        $misc = [pscustomobject]@{ Available = $true; Trim = 'enabled'; UptimeHours = 51.2; WindowsBuild = '10.0.22631' }
        $dxdiag = [pscustomobject]@{
            Available       = $true
            Skipped         = $false
            State           = 'ok'
            Reason          = $null
            OperatingSystem = 'Windows 11 Pro 64-bit (10.0, Build 26200)'
            Processor       = 'Intel(R) Core(TM) i7-11700 @ 2.50GHz (16 CPUs), ~2.5GHz'
            Memory          = '32768MB RAM'
            DisplayDevices  = @([pscustomobject]@{ CardName = 'Test GPU'; ChipType = 'Test Chip'; DedicatedMemory = '12288 MB'; DriverVersion = '31.0.15.3623'; DriverDate = '6/1/2025 21:00:00' })
            KeyLines        = @('OperatingSystem: Windows 11 Pro 64-bit (10.0, Build 26200)', 'DisplayDevice #1 CardName: Test GPU')
            File            = 'C:\\temp\\reports\\dxdiag-test-host-20260101-000000.xml'
        }
    } else {
        $system = [pscustomobject]@{ Available = $false; Reason = 'not collected' }
        $cpu = [pscustomobject]@{ Available = $false; Reason = 'not collected' }
        $memory = [pscustomobject]@{ Available = $false; Reason = 'not collected' }
        $gpu = [pscustomobject]@{ Available = $false; Reason = 'not collected'; Adapters = @() }
        $storageAvailable = [bool]$StorageAvailable
        $bootEntries = @($BootEntries)
        $power = [pscustomobject]@{ Available = $false; Reason = 'not collected'; FastStartup = 'unavailable (not collected)'; BugcheckCodes = @(); Pagefile = $null }
        $lighting = [pscustomobject]@{ Available = $false; Reason = 'not collected'; DynamicLighting = 'unavailable (not collected)'; Services = @(); StartupCommands = @(); RunningServices = $null; StartupTotal = $null; ContentionFlag = $false }
        $update = [pscustomobject]@{ Available = $false; Reason = 'not collected'; LatestKbs = @(); Pending = $null; PendingState = 'unavailable (not collected)'; SearchDate = $null }
        $drivers = [pscustomobject]@{ Available = $false; Reason = 'not collected'; OldestDrivers = @(); NoDriverDate = 0 }
        $misc = [pscustomobject]@{ Available = $false; Reason = 'not collected'; Trim = 'unavailable (not collected)'; UptimeHours = $null; WindowsBuild = $null }
        $dxdiag = [pscustomobject]@{
            Available       = $false
            Skipped         = $true
            State           = 'skipped (-SkipDxDiag)'
            Reason          = 'skipped'
            OperatingSystem = 'unavailable (skipped)'
            Processor       = 'unavailable (skipped)'
            Memory          = 'unavailable (skipped)'
            DisplayDevices  = @()
            KeyLines        = @()
            File            = $null
        }
    }

    $cleanBoots = 0
    $dirtyBoots = 0
    foreach ($entry in @($bootEntries)) {
        if ($null -eq $entry) { continue }
        if ([int]$entry.Id -eq 6005) {
            if ([string]$entry.Kind -eq 'clean') { $cleanBoots = $cleanBoots + 1 } else { $dirtyBoots = $dirtyBoots + 1 }
        }
    }

    $meta = [pscustomobject]@{
        Timestamp          = (Get-DiagTimestamp)
        Host               = $HostName
        Mode               = 'Full'
        WindowDays         = $WindowDays
        WindowStart        = (Get-DiagTimestamp -Date $WindowStart)
        Elevated           = $true
        Version            = '1.0.0'
        SectionsSkipped    = @()
        OffProviderDropped = $OffProviderDropped
        OutputDir          = $OutputDir
        StatePath          = $StatePath
        Stamp              = (Get-DiagFileNameStamp)
        BaselineUsable     = $false
        BaselineReason     = 'none (first run)'
        PreviousLastRunAt  = $null
        SkipDxDiag         = $true
        EventBudgetSeconds = 30
        # [System.IO.Path]::Combine, not Join-Path: a Windows-shaped "C:\..." path
        # is not a drive on Linux and Join-Path would throw there.
        ReportPath         = [System.IO.Path]::Combine($OutputDir, 'pc-diagnostics-test-host.txt')
    }

    return [pscustomobject]@{
        meta            = $meta
        system          = $system
        cpu             = $cpu
        memory          = $memory
        gpu             = $gpu
        storage         = [pscustomobject]@{ Available = $storageAvailable; Reason = $(if ($storageAvailable) { $null } else { 'not collected' }); Disks = @($Disks) }
        volumes         = [pscustomobject]@{ Volumes = @($Volumes) }
        largest_folders = @{}
        largest_files   = @{}
        events          = [pscustomobject]@{
            Counters     = $counterMap
            Catalog      = $catalog
            Listings     = $listingMap
            ListingsMeta = $metaMap
        }
        wer             = $Wer
        boots           = [pscustomobject]@{ Entries = @($bootEntries); Clean = $cleanBoots; Dirty = $dirtyBoots }
        power           = $power
        lighting        = $lighting
        update          = $update
        drivers         = $drivers
        misc            = $misc
        dxdiag          = $dxdiag
        problems        = [pscustomobject]@{ Problems = @() }
    }
}

function New-TestWerEvents {
    <#
      The 10,000-event flood (T07) without a 2 MB fixture file: the events are
      generated deterministically from a count and a signature count. Every event
      carries a distinct dump path, so the dedupe step has real work to do and the
      listing cap is measured against a real omission count.
    #>
    param([int]$Count = 10000, [int]$SignatureCount = 4, $Start = $null)

    if ($null -eq $Start) { $Start = (Get-Date).Date.AddDays(-20) }
    if (-not ($Start -is [datetime])) {
        $Start = [datetime]::Parse([string]$Start, [System.Globalization.CultureInfo]::InvariantCulture)
    }

    $events = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $Count) {
        $signature = $i % $SignatureCount
        $app = 'flood' + [string]$signature + '.exe'
        $message = 'Faulting application name: ' + $app + ', version: 1.0.0.0. Attached files: C:\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_flood' + [string]$signature + '\Report.wer.dmp'
        [void]$events.Add([pscustomobject]@{
            TimeCreated      = $Start.AddMinutes($i)
            Id               = 1001
            ProviderName     = 'Windows Error Reporting'
            LevelDisplayName = 'Information'
            Level            = 4
            Message          = $message
            Data             = [ordered]@{ AppName = $app; P1 = $app; P2 = '1.0.0.0'; P3 = '00000000' }
        })
        $i = $i + 1
    }
    return @($events.ToArray())
}

function Get-TestFixtureSince {
    <#
      The query window a fixture-derived test should use: one day before its
      earliest event. Deriving it from the data keeps a fixture with fixed dates
      valid forever - a hardcoded "30 days ago" would silently start returning
      nothing, and an empty result would make several assertions pass vacuously.
    #>
    param([Parameter(Mandatory = $true)]$Fixture, [Parameter(Mandatory = $true)][string]$LogName)

    $earliest = $null
    $logs = $Fixture.PSObject.Properties['logs']
    if ($null -eq $logs -or $null -eq $logs.Value) { return (Get-Date).Date.AddYears(-10) }
    $logProperty = $logs.Value.PSObject.Properties[$LogName]
    if ($null -eq $logProperty -or $null -eq $logProperty.Value) { return (Get-Date).Date.AddYears(-10) }
    foreach ($record in @($logProperty.Value)) {
        $stamp = [datetime]::Parse([string]$record.TimeCreated, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($null -eq $earliest -or $stamp -lt $earliest) { $earliest = $stamp }
    }
    if ($null -eq $earliest) { return (Get-Date).Date.AddYears(-10) }
    return $earliest.AddDays(-1)
}

function Get-TestCounterValue {
    <#
      One counter's total from a counter map, or $null when the key is absent.
      Used instead of $counters[$key].total because a hashtable entry is not
      always a PSObject.
    #>
    param($Counters, [string]$Key)

    if ($null -eq $Counters) { return $null }
    $entry = $null
    if ($Counters -is [System.Collections.IDictionary]) {
        if ($Counters.Contains($Key)) { $entry = $Counters[$Key] }
    } else {
        $property = $Counters.PSObject.Properties[$Key]
        if ($null -ne $property) { $entry = $property.Value }
    }
    if ($null -eq $entry) { return $null }
    if ($entry -is [System.Collections.IDictionary]) {
        if ($entry.Contains('total')) { return $entry['total'] }
        return $null
    }
    return $entry.total
}
