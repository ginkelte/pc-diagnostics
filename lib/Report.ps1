# lib/Report.ps1
#
# Renderers (section 8). New-FullReport returns the 14-section report body as
# [string[]]; Format-QuickReport returns the console table as [string[]]. Neither
# function writes to the console or to disk: the entry point owns artifact
# writing (section 4.2), so both renderers stay pure functions of the snapshot
# and can be exercised on Linux with a fixture.
#
# Rules that shape every line below:
#   * a value that could not be collected renders "unavailable (<reason>)", never
#     0, never null, never an empty string (RF-27);
#   * a successful query that found nothing renders 0 *with* its query line, so a
#     zero is attributable and never looks like a broken query (RF-13);
#   * every number is invariant culture (section 7.3);
#   * ASCII only (RNF-05), Windows PowerShell 5.1 compatible (RNF-04);
#   * sections 01-14 always appear, in order, and a section body is never empty.
#
# The snapshot keys consumed here are the ones of section 4.4 only.

$script:DiagReportRule = '===================================================================='
$script:DiagReportThin = '--------------------------------------------------------------------'

# ---------------------------------------------------------------------------
# Buffer and formatting helpers
# ---------------------------------------------------------------------------

function New-DiagReportBuffer {
    <#
      An ArrayList is returned with -NoEnumerate because an empty collection
      that goes through the pipeline as a return value is unrolled to nothing.
    #>
    Write-Output -NoEnumerate (New-Object System.Collections.ArrayList)
}

function Add-DiagReportText {
    param($Buffer, [string]$Text)
    if ($null -eq $Buffer) { return }
    if ($null -eq $Text) { $Text = '' }
    [void]$Buffer.Add($Text)
}

function Add-DiagReportField {
    <#
      "    Label          : value" with a stable label column, so two reports
      from different versions stay diffable. -Indent widens the left margin for
      nested blocks (disk and pagefile details).
    #>
    param($Buffer, [string]$Label, [string]$Value, [int]$Width = 18, [int]$Indent = 4)
    $pad = ''
    if ($Indent -gt 0) { $pad = ' ' * $Indent }
    $name = [string]$Label
    if ($name.Length -lt $Width) { $name = $name.PadRight($Width) }
    Add-DiagReportText -Buffer $Buffer -Text ($pad + $name + ': ' + [string]$Value)
}

function Add-DiagReportNote {
    <#
      A free-text line indented under a field, used for the fixed sentences of
      RF-19, RF-20 and RF-23.
    #>
    param($Buffer, [string]$Text, [int]$Indent = 6)
    $pad = ''
    if ($Indent -gt 0) { $pad = ' ' * $Indent }
    Add-DiagReportText -Buffer $Buffer -Text ($pad + [string]$Text)
}

function Test-DiagReportValue {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $true
}

function Format-DiagReportText {
    <#
      A string field, or "unavailable (<reason>)" when it is missing. Values are
      collapsed to one line and bounded, so a multi-line CIM string cannot break
      the layout (EC-10).
    #>
    param($Value, [string]$Reason = 'not reported', [int]$MaxLength = 200)
    if (-not (Test-DiagReportValue -Value $Value)) { return ('unavailable (' + $Reason + ')') }
    $text = ''
    if ($Value -is [string]) { $text = $Value }
    else { $text = [string]$Value }
    $text = ConvertTo-DiagSingleLine -Text $text -MaxLength $MaxLength
    if ([string]::IsNullOrWhiteSpace($text)) { return ('unavailable (' + $Reason + ')') }
    return $text
}

function Format-DiagReportNumber {
    <#
      Invariant one-decimal (or -Decimals) formatting; $null is unavailable, not
      zero. Never uses a culture-sensitive cast, so a Spanish host cannot produce
      "2,1" (section 7.3).
    #>
    param($Value, [int]$Decimals = 1, [string]$Reason = 'not reported')
    if ($null -eq $Value) { return ('unavailable (' + $Reason + ')') }
    $text = $null
    try { $text = Format-DiagNumber -Value $Value -Decimals $Decimals } catch { $text = $null }
    if ([string]::IsNullOrWhiteSpace($text)) { return ('unavailable (' + $Reason + ')') }
    return $text
}

function Format-DiagReportUnit {
    <#
      Same as Format-DiagReportNumber with a unit suffix, applied only when there
      is a value: "9.4 GB" or "unavailable (not reported)", never "unavailable GB".
    #>
    param($Value, [int]$Decimals = 1, [string]$Unit = '', [string]$Reason = 'not reported')
    if ($null -eq $Value) { return ('unavailable (' + $Reason + ')') }
    $text = Format-DiagReportNumber -Value $Value -Decimals $Decimals -Reason $Reason
    if ($text.StartsWith('unavailable')) { return $text }
    if ([string]::IsNullOrEmpty($Unit)) { return $text }
    return ($text + ' ' + $Unit)
}

function Format-DiagReportDate {
    <#
      Accepts a [datetime] or an ISO string; a value that is present but
      unparsable renders "unavailable (unparsable)" rather than a fabricated date.
    #>
    param($Value, [string]$Format = 'yyyy-MM-dd', [string]$Reason = 'not reported')
    if (-not (Test-DiagReportValue -Value $Value)) { return ('unavailable (' + $Reason + ')') }
    $dt = ConvertTo-DiagDateTime -Value $Value
    if ($null -eq $dt) { return 'unavailable (unparsable)' }
    return $dt.ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-DiagReportState {
    <#
      Normalises a state token such as "not_present", "enabled" or
      "unavailable (access denied)" into a report value. A bare token that is
      not a known state becomes "unavailable (<token>)" so a broken probe can
      never read as a healthy one (RF-19, RF-20).
    #>
    param($Token, [string]$Reason = 'not reported')
    if (-not (Test-DiagReportValue -Value $Token)) { return ('unavailable (' + $Reason + ')') }
    $text = [string]$Token
    if ($text.StartsWith('unavailable')) { return $text }
    return $text
}

function Get-DiagReportEntryValue {
    <#
      Reads a key from either an IDictionary (the counter and listing-meta maps
      of the snapshot, a parsed hashtable) or an object. Hashtable keys are not
      guaranteed to be visible as PSObject properties, so both shapes are read
      explicitly.
    #>
    param($Entry, [string]$Name)
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains($Name)) { return $Entry[$Name] }
        return $null
    }
    return (Get-DiagPropValue -Object $Entry -Name $Name -Default $null)
}

function Get-DiagReportProblemReason {
    <#
      The reason a specific collector recorded in problems[]. Returns $null when
      it did not record one, which lets a caller tell "collected and empty" (a
      legitimate zero) from "not collected" (unavailable).
    #>
    param($Snapshot, [string]$Collector)
    if ($null -eq $Snapshot.problems) { return $null }
    foreach ($problem in @($Snapshot.problems.Problems)) {
        if ($null -eq $problem) { continue }
        if ([string]$problem.Collector -eq $Collector) {
            return (ConvertTo-DiagSingleLine -Text ([string]$problem.Reason) -MaxLength 160)
        }
    }
    return $null
}

function Get-DiagReportSectionReason {
    <#
      The reason a section is unusable: the collector's own Reason when it
      carries one, otherwise the first matching entry of problems[] (RF-27).
    #>
    param($Snapshot, $Section, [string]$Collector, [string]$Default = 'unavailable')
    if ($null -ne $Section) {
        $available = Get-DiagReportEntryValue -Entry $Section -Name 'Available'
        $reason = Get-DiagReportEntryValue -Entry $Section -Name 'Reason'
        if (-not [string]::IsNullOrWhiteSpace([string]$reason)) {
            return (ConvertTo-DiagSingleLine -Text ([string]$reason) -MaxLength 160)
        }
        if ($available -eq $false) { return 'not collected' }
    }
    $recorded = Get-DiagReportProblemReason -Snapshot $Snapshot -Collector $Collector
    if ($null -ne $recorded) { return $recorded }
    return $Default
}

function Get-DiagReportCounter {
    <#
      One catalog counter as a uniform object. present is false when the snapshot
      has no entry at all, which is different from a present entry whose total is
      $null (a failed query).
    #>
    param($Snapshot, [string]$Key)
    $result = [pscustomobject]@{
        present        = $false
        total          = $null
        since_last_run = $null
        error          = $null
    }
    $counters = $null
    if ($null -ne $Snapshot.events) {
        $counters = Get-DiagReportEntryValue -Entry $Snapshot.events -Name 'Counters'
    }
    if ($null -eq $counters) { return $result }
    $entry = $null
    if ($counters -is [System.Collections.IDictionary]) {
        if ($counters.Contains($Key)) { $entry = $counters[$Key] }
    } else {
        $entry = Get-DiagPropValue -Object $counters -Name $Key -Default $null
    }
    if ($null -eq $entry) { return $result }
    $result.present = $true
    $result.total = Get-DiagReportEntryValue -Entry $entry -Name 'total'
    $result.since_last_run = Get-DiagReportEntryValue -Entry $entry -Name 'since_last_run'
    $result.error = Get-DiagReportEntryValue -Entry $entry -Name 'error'
    return $result
}

function Get-DiagReportWindowStart {
    param($Snapshot)
    $days = 30
    $meta = $Snapshot.meta
    if ($null -ne $meta) {
        $value = Get-DiagReportEntryValue -Entry $meta -Name 'WindowDays'
        if ($null -ne $value) { $days = [int]$value }
    }
    $start = $null
    if ($null -ne $meta) {
        $start = ConvertTo-DiagDateTime -Value (Get-DiagReportEntryValue -Entry $meta -Name 'WindowStart')
    }
    if ($null -eq $start) { $start = (Get-Date).Date.AddDays(-1 * $days) }
    return $start
}

function Get-DiagReportSystemBuild {
    <#
      "10.0.22631" plus the UBR suffix yields "10.0.22631.4460", the string users
      see in winver; a build that already carries the revision is not doubled.
    #>
    param($System)
    $version = ''
    $build = ''
    if ($null -ne $System) {
        $version = [string](Get-DiagReportEntryValue -Entry $System -Name 'Version')
        $build = [string](Get-DiagReportEntryValue -Entry $System -Name 'Build')
    }
    $text = $version
    if (-not [string]::IsNullOrWhiteSpace($build) -and $build.Contains('.')) {
        $parts = $build.Split('.')
        $ubr = $parts[$parts.Length - 1]
        if (-not [string]::IsNullOrWhiteSpace($ubr)) {
            if ([string]::IsNullOrWhiteSpace($text)) { $text = $build }
            else { $text = $text + '.' + $ubr }
        }
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return 'unavailable (not reported)' }
    return $text
}

function Get-DiagReportWindowsVersion {
    <#
      "11" / "10" / the raw version string, for the Quick-mode header line.
    #>
    param($System)
    $caption = ''
    if ($null -ne $System) { $caption = [string](Get-DiagReportEntryValue -Entry $System -Name 'Caption') }
    if ($caption.Contains('Windows 11')) { return '11' }
    if ($caption.Contains('Windows 10')) { return '10' }
    $version = ''
    if ($null -ne $System) { $version = [string](Get-DiagReportEntryValue -Entry $System -Name 'Version') }
    if (-not [string]::IsNullOrWhiteSpace($version)) { return $version }
    return 'unavailable'
}

# ---------------------------------------------------------------------------
# Section 01 SYSTEM (RF-05, RF-08b, RF-12)
# ---------------------------------------------------------------------------

function Get-DiagReportSection01 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $system = $Snapshot.system
    $gpu = $Snapshot.gpu
    $dxdiag = $Snapshot.dxdiag

    # DXDIAG block: present whenever the collector ran, with its own skip and
    # failure states (RF-12, EC-07).
    if ($null -eq $dxdiag) {
        Add-DiagReportText -Buffer $b -Text '    dxdiag: unavailable (not run)'
    } elseif ($dxdiag.Available -eq $true) {
        Add-DiagReportText -Buffer $b -Text '    DXDIAG (key lines)'
        $keyLines = @($dxdiag.KeyLines)
        if ($keyLines.Count -eq 0) {
            Add-DiagReportText -Buffer $b -Text '      no key lines matched'
        } else {
            foreach ($line in $keyLines) {
                if (-not (Test-DiagReportValue -Value $line)) { continue }
                Add-DiagReportText -Buffer $b -Text ('      ' + (ConvertTo-DiagSingleLine -Text ([string]$line) -MaxLength 200))
            }
        }
    } elseif ($dxdiag.Skipped -eq $true) {
        # The skip reason travels in State so a Quick-mode skip is not reported
        # as a -SkipDxDiag skip: they are different decisions.
        $skipText = [string]$dxdiag.State
        if ([string]::IsNullOrWhiteSpace($skipText)) { $skipText = 'skipped (-SkipDxDiag)' }
        Add-DiagReportText -Buffer $b -Text ('    dxdiag: ' + $skipText)
    } else {
        Add-DiagReportText -Buffer $b -Text ('    dxdiag: ' + (Format-DiagReportState -Token $dxdiag.State -Reason 'not run'))
    }

    # Display adapters: always rendered, independent of -SkipDxDiag (RF-08b).
    Add-DiagReportText -Buffer $b -Text '    GPU (display adapters)'
    $adapters = @()
    if ($null -ne $gpu) { $adapters = @($gpu.Adapters) }
    if ($adapters.Count -eq 0) {
        Add-DiagReportText -Buffer $b -Text ('      gpu: ' + (Format-DiagReportState -Token (Get-DiagReportSectionReason -Snapshot $Snapshot -Section $gpu -Collector 'gpu') -Reason 'no display adapter reported'))
    } else {
        foreach ($adapter in $adapters) {
            if ($null -eq $adapter) { continue }
            $tokens = New-Object System.Collections.ArrayList
            [void]$tokens.Add((Format-DiagReportText -Value $adapter.Name -Reason 'not reported'))
            [void]$tokens.Add('driver ' + (Format-DiagReportText -Value $adapter.DriverVersion -Reason 'not reported'))
            [void]$tokens.Add((Format-DiagReportDate -Value $adapter.DriverDate -Format 'yyyy-MM-dd' -Reason 'not reported'))
            [void]$tokens.Add('VRAM ' + (Format-DiagReportUnit -Value $adapter.VramGB -Decimals 1 -Unit 'GB'))
            $mode = 'unavailable (not reported)'
            if (Test-DiagReportValue -Value $adapter.Resolution) {
                $mode = [string]$adapter.Resolution
                if ($null -ne $adapter.RefreshHz) {
                    $mode = $mode + ' @ ' + (Format-DiagReportNumber -Value $adapter.RefreshHz -Decimals 0) + ' Hz'
                }
            }
            [void]$tokens.Add($mode)
            Add-DiagReportText -Buffer $b -Text ('      ' + (($tokens.ToArray()) -join ' | '))
        }
    }

    if ($null -eq $system -or (Get-DiagReportEntryValue -Entry $system -Name 'Available') -ne $true) {
        Add-DiagReportText -Buffer $b -Text ('    SECTION UNAVAILABLE: system (' + (Get-DiagReportSectionReason -Snapshot $Snapshot -Section $system -Collector 'system.os') + ')')
        return @($b.ToArray())
    }

    Add-DiagReportField -Buffer $b -Label 'Caption' -Value (Format-DiagReportText -Value $system.Caption)
    Add-DiagReportField -Buffer $b -Label 'Version' -Value (Format-DiagReportText -Value $system.Version)
    Add-DiagReportField -Buffer $b -Label 'Build' -Value (Format-DiagReportText -Value $system.Build)
    Add-DiagReportField -Buffer $b -Label 'Edition' -Value (Format-DiagReportText -Value $system.Edition)
    Add-DiagReportField -Buffer $b -Label 'Install date' -Value (Format-DiagReportDate -Value $system.InstallDate -Format 'yyyy-MM-dd HH:mm:ss')
    Add-DiagReportField -Buffer $b -Label 'Uptime' -Value (Format-DiagReportUnit -Value $system.UptimeHours -Decimals 1 -Unit 'h')
    Add-DiagReportField -Buffer $b -Label 'Manufacturer' -Value (Format-DiagReportText -Value $system.Manufacturer)
    Add-DiagReportField -Buffer $b -Label 'Model' -Value (Format-DiagReportText -Value $system.Model)
    Add-DiagReportField -Buffer $b -Label 'Baseboard' -Value (Format-DiagReportText -Value $system.BaseboardProduct)
    Add-DiagReportField -Buffer $b -Label 'BIOS vendor' -Value (Format-DiagReportText -Value $system.BiosVendor)
    Add-DiagReportField -Buffer $b -Label 'BIOS version' -Value (Format-DiagReportText -Value $system.BiosVersion)
    Add-DiagReportField -Buffer $b -Label 'BIOS date' -Value (Format-DiagReportDate -Value $system.BiosDate -Format 'yyyy-MM-dd')

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 02 CPU (RF-06)
# ---------------------------------------------------------------------------

function Get-DiagReportSection02 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $cpu = $Snapshot.cpu

    if ($null -eq $cpu -or (Get-DiagReportEntryValue -Entry $cpu -Name 'Available') -ne $true) {
        Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: cpu (' + (Get-DiagReportSectionReason -Snapshot $Snapshot -Section $cpu -Collector 'cpu') + ')')
        return @($b.ToArray())
    }

    Add-DiagReportField -Buffer $b -Label 'Name' -Value (Format-DiagReportText -Value $cpu.Name)
    Add-DiagReportField -Buffer $b -Label 'Physical cores' -Value (Format-DiagReportUnit -Value $cpu.Cores -Decimals 0)
    Add-DiagReportField -Buffer $b -Label 'Logical processors' -Value (Format-DiagReportUnit -Value $cpu.Threads -Decimals 0)
    Add-DiagReportField -Buffer $b -Label 'Socket' -Value (Format-DiagReportText -Value $cpu.Socket)
    Add-DiagReportField -Buffer $b -Label 'Base clock' -Value (Format-DiagReportUnit -Value $cpu.BaseMHz -Decimals 0 -Unit 'MHz')
    Add-DiagReportField -Buffer $b -Label 'Max clock' -Value (Format-DiagReportUnit -Value $cpu.MaxMHz -Decimals 0 -Unit 'MHz')
    $coreThread = 'unavailable (not reported)'
    if (Test-DiagReportValue -Value $cpu.CoreThread) { $coreThread = [string]$cpu.CoreThread }
    Add-DiagReportField -Buffer $b -Label 'Cores/threads' -Value $coreThread

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 03 MEMORY (RF-07)
# ---------------------------------------------------------------------------

function Get-DiagReportSection03 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $memory = $Snapshot.memory

    if ($null -eq $memory -or (Get-DiagReportEntryValue -Entry $memory -Name 'Available') -ne $true) {
        Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: memory (' + (Get-DiagReportSectionReason -Snapshot $Snapshot -Section $memory -Collector 'memory') + ')')
        return @($b.ToArray())
    }

    $modules = @($memory.Modules)
    if ($modules.Count -eq 0) {
        Add-DiagReportText -Buffer $b -Text 'no populated memory slot reported'
    } else {
        foreach ($m in $modules) {
            if ($null -eq $m) { continue }
            $tokens = New-Object System.Collections.ArrayList
            [void]$tokens.Add((Format-DiagReportText -Value $m.Manufacturer))
            [void]$tokens.Add((Format-DiagReportText -Value $m.PartNumber))
            [void]$tokens.Add((Format-DiagReportUnit -Value $m.CapacityGB -Decimals 1 -Unit 'GB'))
            [void]$tokens.Add((Format-DiagReportText -Value $m.Type))
            [void]$tokens.Add('rated (SPD/XMP) ' + (Format-DiagReportUnit -Value $m.RatedMHz -Decimals 0 -Unit 'MT/s'))
            [void]$tokens.Add('running ' + (Format-DiagReportUnit -Value $m.RunningMHz -Decimals 0 -Unit 'MT/s'))
            [void]$tokens.Add((Format-DiagReportUnit -Value $m.Voltage -Decimals 1 -Unit 'V'))
            [void]$tokens.Add('slot ' + (Format-DiagReportText -Value $m.DeviceLocator))
            [void]$tokens.Add('bank ' + (Format-DiagReportText -Value $m.BankLabel))
            Add-DiagReportText -Buffer $b -Text ('    ' + (($tokens.ToArray()) -join ' | '))
        }
    }

    # RF-07: the explicit under-rating line. Taken from the snapshot when the
    # collector produced it, recomputed otherwise so a fixture snapshot behaves.
    $below = @()
    if ($null -ne $memory.BelowRated) { $below = @($memory.BelowRated) }
    if ($below.Count -eq 0) {
        foreach ($m in $modules) {
            if ($null -eq $m) { continue }
            if ($null -eq $m.RatedMHz -or $null -eq $m.RunningMHz) { continue }
            if ([int]$m.RunningMHz -le 0) { continue }
            if ([int]$m.RunningMHz -lt [int]$m.RatedMHz) {
                $below = $below + [pscustomobject]@{ Module = $m.DeviceLocator; RatedMHz = $m.RatedMHz; RunningMHz = $m.RunningMHz }
            }
        }
    }
    foreach ($entry in $below) {
        if ($null -eq $entry) { continue }
        Add-DiagReportText -Buffer $b -Text ('    memory running below module rating: ' + (Format-DiagReportText -Value $entry.Module) + ' rated ' + (Format-DiagReportUnit -Value $entry.RatedMHz -Decimals 0 -Unit 'MT/s') + ', running ' + (Format-DiagReportUnit -Value $entry.RunningMHz -Decimals 0 -Unit 'MT/s'))
    }

    $totalText = Format-DiagReportUnit -Value $memory.TotalGB -Decimals 1 -Unit 'GB'
    $populatedText = Format-DiagReportNumber -Value $memory.PopulatedSlots -Decimals 0
    $slotText = Format-DiagReportNumber -Value $memory.TotalSlots -Decimals 0
    Add-DiagReportText -Buffer $b -Text ('    total: ' + $totalText + ' | populated slots: ' + $populatedText + ' | total slots: ' + $slotText)

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 04 STORAGE DEVICES (RF-08, RF-09)
# ---------------------------------------------------------------------------

function Get-DiagReportSection04 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $storage = $Snapshot.storage
    $disks = @()
    if ($null -ne $storage) { $disks = @($storage.Disks) }

    if ($disks.Count -eq 0) {
        $reason = Get-DiagReportSectionReason -Snapshot $Snapshot -Section $storage -Collector 'storage.physicaldisk'
        Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: storage (' + $reason + ')')
        return @($b.ToArray())
    }

    $nvmeSeen = 0
    foreach ($disk in $disks) {
        if ($null -eq $disk) { continue }
        $number = 'unknown'
        if (Test-DiagReportValue -Value $disk.DiskNumber) { $number = [string]$disk.DiskNumber }
        Add-DiagReportText -Buffer $b -Text ('    Disk ' + $number + ' | ' + (Format-DiagReportText -Value $disk.FriendlyName))
        Add-DiagReportField -Buffer $b -Label 'serial' -Value (Format-DiagReportText -Value $disk.SerialNumber) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'firmware' -Value (Format-DiagReportText -Value $disk.FirmwareVersion) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'bus type' -Value (Format-DiagReportText -Value $disk.BusType) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'media type' -Value (Format-DiagReportText -Value $disk.MediaType) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'size' -Value (Format-DiagReportUnit -Value $disk.SizeGB -Decimals 1 -Unit 'GB') -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'health' -Value (Format-DiagReportText -Value $disk.HealthStatus) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'operational status' -Value (Format-DiagReportText -Value $disk.OperationalStatus) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'partition style' -Value (Format-DiagReportText -Value $disk.PartitionStyle) -Indent 8 -Width 22

        if ([string]$disk.BusType -ne 'NVMe') { continue }
        $nvmeSeen = $nvmeSeen + 1

        # RF-09: every byte-derived field is reported independently, and a
        # missing health log is "unavailable (no NVMe health log)" per field.
        $smart = $disk.Smart
        $logReason = 'no NVMe health log'
        Add-DiagReportField -Buffer $b -Label 'NVMe critical warning' -Value (Format-DiagReportNumber -Value (Get-DiagReportEntryValue -Entry $smart -Name 'CriticalWarning') -Decimals 0 -Reason $logReason) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'NVMe available spare' -Value (Format-DiagReportUnit -Value (Get-DiagReportEntryValue -Entry $smart -Name 'AvailableSparePct') -Decimals 0 -Unit '%' -Reason $logReason) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'NVMe percentage used' -Value (Format-DiagReportUnit -Value (Get-DiagReportEntryValue -Entry $smart -Name 'PercentageUsed') -Decimals 0 -Unit '%' -Reason $logReason) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'NVMe temperature' -Value (Format-DiagReportUnit -Value (Get-DiagReportEntryValue -Entry $smart -Name 'TemperatureC') -Decimals 0 -Unit 'C' -Reason $logReason) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'NVMe power-on hours' -Value (Format-DiagReportNumber -Value (Get-DiagReportEntryValue -Entry $smart -Name 'PowerOnHours') -Decimals 0 -Reason $logReason) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'NVMe unsafe shutdowns' -Value (Format-DiagReportNumber -Value (Get-DiagReportEntryValue -Entry $smart -Name 'UnsafeShutdowns') -Decimals 0 -Reason $logReason) -Indent 8 -Width 22
        Add-DiagReportField -Buffer $b -Label 'NVMe media errors' -Value (Format-DiagReportNumber -Value (Get-DiagReportEntryValue -Entry $smart -Name 'MediaErrors') -Decimals 0 -Reason $logReason) -Indent 8 -Width 22
        $predict = Get-DiagReportEntryValue -Entry $smart -Name 'PredictFailure'
        $predictText = 'unavailable (not reported)'
        if ($null -ne $predict) {
            if ([bool]$predict) { $predictText = 'yes' } else { $predictText = 'no' }
        }
        Add-DiagReportField -Buffer $b -Label 'NVMe predict failure' -Value $predictText -Indent 8 -Width 22
    }

    if ($nvmeSeen -eq 0) {
        Add-DiagReportText -Buffer $b -Text '    no NVMe device'
    }

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 05 VOLUMES (RF-10)
# ---------------------------------------------------------------------------

function Get-DiagReportSection05 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $volumes = @()
    if ($null -ne $Snapshot.volumes) { $volumes = @($Snapshot.volumes.Volumes) }

    if ($volumes.Count -eq 0) {
        $reason = Get-DiagReportSectionReason -Snapshot $Snapshot -Section $Snapshot.volumes -Collector 'volumes'
        Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: volumes (' + $reason + ')')
        return @($b.ToArray())
    }

    foreach ($v in $volumes) {
        if ($null -eq $v) { continue }
        $mount = Format-DiagReportText -Value $v.Mount
        $fs = Format-DiagReportText -Value $v.FileSystem
        $sizeText = Format-DiagReportUnit -Value $v.SizeGB -Decimals 1 -Unit 'GB'
        $freeText = Format-DiagReportUnit -Value $v.FreeGB -Decimals 1 -Unit 'GB'
        $pctText = 'unavailable (size unknown)'
        if ($null -ne $v.FreePct) {
            $pctText = (Format-DiagReportNumber -Value $v.FreePct -Decimals 1) + ' % free'
        }
        $line = '    ' + $mount + '  ' + $fs + '   ' + $sizeText + ' total   ' + $freeText + ' free   ' + $pctText
        if ($null -ne $v.FreePct -and [double]$v.FreePct -lt 10.0) { $line = $line + '  LOW' }
        Add-DiagReportText -Buffer $b -Text $line
    }

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 06 LARGEST FOLDERS (RF-11)
# ---------------------------------------------------------------------------

function Get-DiagReportSection06 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $volumes = @()
    if ($null -ne $Snapshot.volumes) { $volumes = @($Snapshot.volumes.Volumes) }

    if ($volumes.Count -eq 0) {
        Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: largest_folders (' + (Get-DiagReportSectionReason -Snapshot $Snapshot -Section $Snapshot.volumes -Collector 'largest_folders' -Default 'no fixed volume to scan') + ')')
        return @($b.ToArray())
    }

    $rendered = 0
    foreach ($v in $volumes) {
        if ($null -eq $v) { continue }
        $mount = [string]$v.Mount
        $folders = @()
        $files = @()
        $scannedGb = $null
        $partial = $null
        if ($null -ne $Snapshot.largest_folders) {
            if ($Snapshot.largest_folders -is [System.Collections.IDictionary]) {
                if ($Snapshot.largest_folders.Contains($mount)) { $folders = @($Snapshot.largest_folders[$mount]) }
            } else {
                $folders = @(Get-DiagPropValue -Object $Snapshot.largest_folders -Name $mount -Default @())
            }
        }
        if ($null -ne $Snapshot.largest_files) {
            if ($Snapshot.largest_files -is [System.Collections.IDictionary]) {
                if ($Snapshot.largest_files.Contains($mount)) { $files = @($Snapshot.largest_files[$mount]) }
            } else {
                $files = @(Get-DiagPropValue -Object $Snapshot.largest_files -Name $mount -Default @())
            }
        }
        $scannedGb = Get-DiagReportEntryValue -Entry $v -Name 'ScannedGB'
        $partial = Get-DiagReportEntryValue -Entry $v -Name 'ScanPartial'

        if ($folders.Count -eq 0 -and $files.Count -eq 0) {
            Add-DiagReportText -Buffer $b -Text ('    ' + $mount + ' folders: unavailable (not scanned)')
            $rendered = $rendered + 1
            continue
        }

        $usedGb = $null
        if ($null -ne $v.SizeGB -and $null -ne $v.FreeGB) {
            $usedGb = [double]$v.SizeGB - [double]$v.FreeGB
        }
        $scanText = (Format-DiagReportUnit -Value $scannedGb -Decimals 1 -Unit 'GB')
        $usedText = (Format-DiagReportUnit -Value $usedGb -Decimals 1 -Unit 'GB')
        $scanLine = '    ' + $mount + ' scanned ' + $scanText + ' of ' + $usedText + ' used'
        if (Test-DiagReportValue -Value $partial) { $scanLine = $scanLine + '  PARTIAL (scan stopped: ' + [string]$partial + ')' }
        Add-DiagReportText -Buffer $b -Text $scanLine

        foreach ($folder in $folders) {
            if ($null -eq $folder) { continue }
            $line = '      ' + (Format-DiagReportText -Value $folder.Path) + '  ' + (Format-DiagReportUnit -Value $folder.SizeGB -Decimals 1 -Unit 'GB') + '  ' + (Format-DiagReportNumber -Value $folder.FileCount -Decimals 0) + ' files'
            if (Test-DiagReportValue -Value $folder.Partial) { $line = $line + '  PARTIAL (scan stopped: ' + [string]$folder.Partial + ')' }
            Add-DiagReportText -Buffer $b -Text $line
        }
        if ($files.Count -gt 0) {
            Add-DiagReportText -Buffer $b -Text ('      ' + $mount + ' largest files')
            foreach ($file in $files) {
                if ($null -eq $file) { continue }
                $line = '      ' + (Format-DiagReportText -Value $file.Path) + '  ' + (Format-DiagReportUnit -Value $file.SizeGB -Decimals 1 -Unit 'GB')
                if (Test-DiagReportValue -Value $file.Partial) { $line = $line + '  PARTIAL (scan stopped: ' + [string]$file.Partial + ')' }
                Add-DiagReportText -Buffer $b -Text $line
            }
        }
        $rendered = $rendered + 1
    }

    if ($rendered -eq 0) {
        Add-DiagReportText -Buffer $b -Text 'no data (no fixed volume to scan)'
    }

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 07 EVENT SUMMARY (RF-13, RF-16, RF-27)
# ---------------------------------------------------------------------------

function Get-DiagReportSection07 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $catalog = $null
    $listings = $null
    $listingsMeta = $null
    if ($null -ne $Snapshot.events) {
        $catalog = Get-DiagReportEntryValue -Entry $Snapshot.events -Name 'Catalog'
        $listings = Get-DiagReportEntryValue -Entry $Snapshot.events -Name 'Listings'
        $listingsMeta = Get-DiagReportEntryValue -Entry $Snapshot.events -Name 'ListingsMeta'
    }
    if ($null -eq $catalog) { $catalog = Get-DiagEventCatalog }
    $windowStart = Get-DiagReportWindowStart -Snapshot $Snapshot

    foreach ($row in @($catalog)) {
        if ($null -eq $row) { continue }
        $key = [string]$row.Key
        $counter = Get-DiagReportCounter -Snapshot $Snapshot -Key $key

        $totalText = 'unavailable (no query result)'
        if ($counter.present) {
            if ($null -eq $counter.total) {
                $reason = 'query failed'
                if (Test-DiagReportValue -Value $counter.error) { $reason = [string]$counter.error }
                $totalText = 'unavailable (' + (ConvertTo-DiagSingleLine -Text $reason -MaxLength 120) + ')'
            } else {
                $totalText = Format-DiagReportNumber -Value $counter.total -Decimals 0
            }
        }

        # "-" is the spec's "no usable baseline" token; a failed query keeps it
        # too, because a delta from a broken total would be a fabricated number.
        $deltaText = '-'
        if ($counter.present -and $null -ne $counter.total -and $null -ne $counter.since_last_run) {
            $deltaText = Format-DiagReportNumber -Value $counter.since_last_run -Decimals 0
        }

        $ids = @($row.Ids) -join ','
        Add-DiagReportText -Buffer $b -Text ('    ' + $key + '  ' + [string]$row.Provider + ' ' + $ids + '  total=' + $totalText + '  since_last_run=' + $deltaText)
        Add-DiagReportText -Buffer $b -Text ('      label: ' + (Format-DiagReportText -Value $row.Label))
        Add-DiagReportText -Buffer $b -Text ('      ' + (Get-DiagQueryText -Row $row -Since $windowStart))

        # Listing (RF-16). A cap of 0 means counts only: no listing lines, not
        # even the overflow line.
        $meta = $null
        if ($null -ne $listingsMeta) {
            if ($listingsMeta -is [System.Collections.IDictionary]) {
                if ($listingsMeta.Contains($key)) { $meta = $listingsMeta[$key] }
            } else {
                $meta = Get-DiagPropValue -Object $listingsMeta -Name $key -Default $null
            }
        }
        if ($null -eq $meta) {
            Add-DiagReportText -Buffer $b -Text '      listing: unavailable (no listing metadata)'
            continue
        }
        $cap = Get-DiagReportEntryValue -Entry $meta -Name 'cap'
        if ($null -ne $cap -and [int]$cap -le 0) { continue }

        $events = @()
        if ($null -ne $listings) {
            if ($listings -is [System.Collections.IDictionary]) {
                if ($listings.Contains($key)) { $events = @($listings[$key]) }
            } else {
                $events = @(Get-DiagPropValue -Object $listings -Name $key -Default @())
            }
        }
        foreach ($ev in $events) {
            if ($null -eq $ev) { continue }
            $stamp = Format-DiagReportDate -Value $ev.TimeCreated -Format 'yyyy-MM-dd HH:mm:ss' -Reason 'no timestamp'
            $line = '      ' + $stamp + '  ' + (Format-DiagReportText -Value $ev.ProviderName -Reason 'unknown provider') + '  ' + (Format-DiagReportNumber -Value $ev.Id -Decimals 0 -Reason 'unknown id') + '  ' + (Format-DiagReportText -Value $ev.Level -Reason 'no level') + '  ' + (ConvertTo-DiagSingleLine -Text ([string]$ev.Message) -MaxLength 160)
            Add-DiagReportText -Buffer $b -Text $line
        }
        $omitted = Get-DiagReportEntryValue -Entry $meta -Name 'omitted'
        if ($null -ne $omitted -and [int]$omitted -gt 0) {
            Add-DiagReportText -Buffer $b -Text ('      ... ' + [string]([int]$omitted) + ' more not listed (see counts above)')
        }
    }

    if ($b.Count -eq 0) {
        Add-DiagReportText -Buffer $b -Text 'SECTION UNAVAILABLE: events (empty catalog)'
    }

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 08 CRASHES / WER (RF-15)
# ---------------------------------------------------------------------------

function Get-DiagReportSection08 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $wer = $Snapshot.wer

    # A failed wer_1001 query yields zeros in the snapshot; rendering those would
    # be a false zero, so the section is declared unavailable instead (RF-27).
    $counter = Get-DiagReportCounter -Snapshot $Snapshot -Key 'wer_1001'
    if ($counter.present -and $null -eq $counter.total) {
        $reason = 'query failed'
        if (Test-DiagReportValue -Value $counter.error) { $reason = [string]$counter.error }
        Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: wer (' + (ConvertTo-DiagSingleLine -Text $reason -MaxLength 120) + ')')
        return @($b.ToArray())
    }

    if ($null -eq $wer) {
        Add-DiagReportText -Buffer $b -Text 'SECTION UNAVAILABLE: wer (collector failed)'
        return @($b.ToArray())
    }

    $headline = 'WER events: ' + (Format-DiagReportNumber -Value $wer.events_seen -Decimals 0) +
        ' | unique dumps: ' + (Format-DiagReportNumber -Value $wer.unique_dumps -Decimals 0) +
        ' | signature-only (params): ' + (Format-DiagReportNumber -Value $wer.unique_params -Decimals 0) +
        ' | unidentified: ' + (Format-DiagReportNumber -Value $wer.unidentified -Decimals 0) +
        ' | re-reports: ' + (Format-DiagReportNumber -Value $wer.repeats -Decimals 0)
    Add-DiagReportText -Buffer $b -Text $headline

    $signatures = @($wer.signatures)
    if ($signatures.Count -eq 0) {
        Add-DiagReportText -Buffer $b -Text '    no WER signature in the window'
        return @($b.ToArray())
    }

    # count descending then signature ascending is the order the collector
    # produced; it is re-sorted here so a hand-built fixture is rendered right.
    $sorted = @($signatures | Where-Object { $null -ne $_ } | Sort-Object -Property @{ Expression = { [int]$_.count }; Descending = $true }, @{ Expression = { [string]$_.signature }; Descending = $false })
    foreach ($sig in $sorted) {
        $first = Format-DiagReportDate -Value $sig.first_seen -Format 'yyyy-MM-dd HH:mm:ss' -Reason 'not recorded'
        $last = Format-DiagReportDate -Value $sig.last_seen -Format 'yyyy-MM-dd HH:mm:ss' -Reason 'not recorded'
        $app = Format-DiagReportText -Value $sig.app -Reason 'not recorded'
        Add-DiagReportText -Buffer $b -Text ('    ' + (Format-DiagReportNumber -Value $sig.count -Decimals 0) + '  ' + [string]$sig.kind + '  ' + (Format-DiagReportText -Value $sig.signature) + '  first ' + $first + '  last ' + $last + '  app ' + $app)
    }

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 09 BOOTS (RF-17)
# ---------------------------------------------------------------------------

function Get-DiagReportSection09 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $boots = $Snapshot.boots

    if ($null -eq $boots) {
        Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: boots (' + (Get-DiagReportSectionReason -Snapshot $Snapshot -Section $boots -Collector 'boots') + ')')
        return @($b.ToArray())
    }

    # Boot classification is derived from the 6005/6006/6008 queries. If one of
    # them failed the totals are unknown, and "clean boots: 0" would be the exact
    # false zero RF-27 forbids (EC-03 vs EC-04).
    foreach ($key in @('eventlog_6005', 'eventlog_6006', 'eventlog_6008')) {
        $counter = Get-DiagReportCounter -Snapshot $Snapshot -Key $key
        if ($counter.present -and $null -eq $counter.total) {
            $reason = 'query failed'
            if (Test-DiagReportValue -Value $counter.error) { $reason = [string]$counter.error }
            Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: boots (EventLog ' + $key.Substring($key.Length - 4) + ' query: ' + (ConvertTo-DiagSingleLine -Text $reason -MaxLength 120) + ')')
            return @($b.ToArray())
        }
    }

    Add-DiagReportField -Buffer $b -Label 'clean boots' -Value (Format-DiagReportNumber -Value $boots.Clean -Decimals 0)
    Add-DiagReportField -Buffer $b -Label 'dirty boots' -Value (Format-DiagReportNumber -Value $boots.Dirty -Decimals 0)

    $entries = @($boots.Entries)
    if ($entries.Count -eq 0) {
        Add-DiagReportText -Buffer $b -Text '    no EventLog 6005/6006/6008 event in the window'
        return @($b.ToArray())
    }
    $shown = 0
    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
        if ($shown -ge 10) { break }
        Add-DiagReportText -Buffer $b -Text ('    ' + (Format-DiagReportDate -Value $entry.TimeCreated -Format 'yyyy-MM-dd HH:mm:ss' -Reason 'no timestamp') + '  ' + (Format-DiagReportNumber -Value $entry.Id -Decimals 0 -Reason 'unknown id') + '  ' + (Format-DiagReportText -Value $entry.Label -Reason 'unclassified'))
        $shown = $shown + 1
    }
    if ($entries.Count -gt $shown) {
        Add-DiagReportText -Buffer $b -Text ('    ... ' + [string]([int]($entries.Count - $shown)) + ' more not listed (see counts above)')
    }

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 10 POWER (RF-18, RF-19)
# ---------------------------------------------------------------------------

function Get-DiagReportSection10 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $power = $Snapshot.power

    if ($null -eq $power) {
        Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: power (' + (Get-DiagReportSectionReason -Snapshot $Snapshot -Section $power -Collector 'power') + ')')
        return @($b.ToArray())
    }

    $fast = Format-DiagReportState -Token $power.FastStartup -Reason 'not collected'
    if ($fast -eq 'enabled') { $fast = 'ENABLED' } elseif ($fast -eq 'disabled') { $fast = 'DISABLED' }
    Add-DiagReportField -Buffer $b -Label 'Fast Startup' -Value $fast
    if ($fast -eq 'ENABLED') {
        Add-DiagReportNote -Buffer $b -Text (Format-DiagReportText -Value $power.FastStartupConsequence -Reason 'not recorded')
        Add-DiagReportNote -Buffer $b -Text (Format-DiagReportText -Value $power.FastStartupHint -Reason 'not recorded')
    }

    $bugchecks = @($power.BugcheckCodes)
    if ($bugchecks.Count -eq 0) {
        # Not "0": a zero count here would be indistinguishable from a broken
        # query, and the count lives in section 07 with its query line.
        Add-DiagReportField -Buffer $b -Label 'Bugcheck' -Value 'none in the window (no Microsoft-Windows-Kernel-Power 41 event)'
    } else {
        foreach ($code in $bugchecks) {
            if ($null -eq $code) { continue }
            $text = 'unavailable (BugcheckCode field missing)'
            if ($null -ne $code.Code) {
                if ([int]$code.Code -eq 0) {
                    $text = 'no bugcheck (power loss or hard reset)'
                } else {
                    $hex = [string]$code.CodeHex
                    if ([string]::IsNullOrWhiteSpace($hex)) { $hex = '0x' + ([int]$code.Code).ToString('X8', [System.Globalization.CultureInfo]::InvariantCulture) }
                    $text = $hex
                    if (Test-DiagReportValue -Value $code.Friendly) { $text = $text + ' ' + [string]$code.Friendly }
                    $params = @($code.Parameters)
                    if ($params.Count -gt 0) {
                        $parts = @()
                        foreach ($p in $params) {
                            if (Test-DiagReportValue -Value $p) { $parts = $parts + [string]$p }
                        }
                        if ($parts.Count -gt 0) { $text = $text + ' (params ' + ($parts -join ',') + ')' }
                    }
                }
            }
            Add-DiagReportField -Buffer $b -Label 'Bugcheck' -Value $text
        }
    }

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 11 LIGHTING (RF-20, RF-23)
# ---------------------------------------------------------------------------

function Get-DiagReportSection11 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $lighting = $Snapshot.lighting

    if ($null -eq $lighting) {
        Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: lighting (' + (Get-DiagReportSectionReason -Snapshot $Snapshot -Section $lighting -Collector 'lighting') + ')')
        return @($b.ToArray())
    }

    $state = Format-DiagReportState -Token $lighting.DynamicLighting -Reason 'not collected'
    Add-DiagReportField -Buffer $b -Label 'Dynamic Lighting' -Value $state
    if ($state -eq 'enabled') {
        Add-DiagReportNote -Buffer $b -Text (Format-DiagReportText -Value $lighting.DynamicLightingNote -Reason 'not recorded')
    }

    $services = @($lighting.Services)
    $serviceProblem = Get-DiagReportProblemReason -Snapshot $Snapshot -Collector 'lighting.services'
    if ($null -ne $serviceProblem) {
        Add-DiagReportField -Buffer $b -Label 'lighting services' -Value ('unavailable (' + $serviceProblem + ')')
    } else {
        Add-DiagReportField -Buffer $b -Label 'lighting services' -Value ((Format-DiagReportNumber -Value $services.Count -Decimals 0) + ' (running: ' + (Format-DiagReportNumber -Value $lighting.RunningServices -Decimals 0) + ')')
    }
    foreach ($svc in $services) {
        if ($null -eq $svc) { continue }
        Add-DiagReportText -Buffer $b -Text ('      ' + (Format-DiagReportText -Value $svc.Name) + ' | ' + (Format-DiagReportText -Value $svc.DisplayName) + ' | ' + (Format-DiagReportText -Value $svc.State) + ' | ' + (Format-DiagReportText -Value $svc.StartMode))
    }

    $startup = @($lighting.StartupCommands)
    $startupProblem = Get-DiagReportProblemReason -Snapshot $Snapshot -Collector 'lighting.startup'
    if ($null -ne $startupProblem) {
        Add-DiagReportField -Buffer $b -Label 'autostart entries' -Value ('unavailable (' + $startupProblem + ')')
    } else {
        Add-DiagReportField -Buffer $b -Label 'autostart entries' -Value ((Format-DiagReportNumber -Value $startup.Count -Decimals 0) + ' matching of ' + (Format-DiagReportNumber -Value $lighting.StartupTotal -Decimals 0) + ' total')
    }
    foreach ($entry in $startup) {
        if ($null -eq $entry) { continue }
        Add-DiagReportText -Buffer $b -Text ('      ' + (Format-DiagReportText -Value $entry.Name) + ' | ' + (Format-DiagReportText -Value $entry.Command) + ' | ' + (Format-DiagReportText -Value $entry.Location) + ' | ' + (Format-DiagReportText -Value $entry.User))
    }

    if ($lighting.ContentionFlag -eq $true) {
        Add-DiagReportNote -Buffer $b -Text (Format-DiagReportText -Value $lighting.ContentionNote -Reason 'multiple lighting services are running')
    }

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 12 WINDOWS UPDATE (RF-21)
# ---------------------------------------------------------------------------

function Get-DiagReportSection12 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $update = $Snapshot.update

    if ($null -eq $update) {
        Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: update (' + (Get-DiagReportSectionReason -Snapshot $Snapshot -Section $update -Collector 'update') + ')')
        return @($b.ToArray())
    }

    $hotfixes = @($update.LatestKbs)
    $hotfixProblem = Get-DiagReportProblemReason -Snapshot $Snapshot -Collector 'update.hotfix'
    if ($hotfixes.Count -eq 0) {
        if ($null -ne $hotfixProblem) {
            Add-DiagReportText -Buffer $b -Text ('    hotfixes: unavailable (' + $hotfixProblem + ')')
        } else {
            Add-DiagReportText -Buffer $b -Text '    hotfixes: none reported (Get-HotFix returned no entry)'
        }
    }
    foreach ($kb in $hotfixes) {
        if ($null -eq $kb) { continue }
        Add-DiagReportText -Buffer $b -Text ('    ' + (Format-DiagReportText -Value $kb.HotFixID -Reason 'no KB id') + '  ' + (Format-DiagReportDate -Value $kb.InstalledOn -Format 'yyyy-MM-dd' -Reason 'no install date') + '  ' + (Format-DiagReportText -Value $kb.Description -Reason 'no description'))
    }

    $pendingText = Format-DiagReportState -Token $update.PendingState -Reason 'not collected'
    if ($pendingText -eq 'pending' -and $null -ne $update.Pending) {
        $pendingText = (Format-DiagReportText -Value $update.Pending.Title -Reason 'no title') + ' (' + (Format-DiagReportText -Value $update.Pending.Date -Reason 'date unknown') + ')'
    } elseif ($pendingText -eq 'none') {
        $pendingText = 'none'
    }
    Add-DiagReportField -Buffer $b -Label 'pending' -Value $pendingText

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 13 DRIVERS (RF-22)
# ---------------------------------------------------------------------------

function Get-DiagReportSection13 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $drivers = $Snapshot.drivers

    if ($null -eq $drivers -or (Get-DiagReportEntryValue -Entry $drivers -Name 'Available') -ne $true) {
        Add-DiagReportText -Buffer $b -Text ('SECTION UNAVAILABLE: drivers (' + (Get-DiagReportSectionReason -Snapshot $Snapshot -Section $drivers -Collector 'drivers') + ')')
        return @($b.ToArray())
    }

    $list = @($drivers.OldestDrivers)
    if ($list.Count -eq 0) {
        Add-DiagReportText -Buffer $b -Text '    no signed driver with a readable date'
    }
    foreach ($d in $list) {
        if ($null -eq $d) { continue }
        Add-DiagReportText -Buffer $b -Text ('    ' + (Format-DiagReportDate -Value $d.DateText -Format 'yyyy-MM-dd' -Reason 'no date') + '  ' + (Format-DiagReportUnit -Value $d.AgeYears -Decimals 1 -Unit 'y') + '  ' + (Format-DiagReportText -Value $d.Name -Reason 'no device name') + '  ' + (Format-DiagReportText -Value $d.Provider -Reason 'no provider') + '  ' + (Format-DiagReportText -Value $d.Version -Reason 'no version'))
    }
    Add-DiagReportField -Buffer $b -Label 'no driver date' -Value (Format-DiagReportNumber -Value $drivers.NoDriverDate -Decimals 0)

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# Section 14 MISC (RF-24, RF-25)
# ---------------------------------------------------------------------------

function Get-DiagReportSection14 {
    param($Snapshot)
    $b = New-DiagReportBuffer
    $misc = $Snapshot.misc
    $power = $Snapshot.power

    $trimText = 'unavailable (not collected)'
    if ($null -ne $misc) { $trimText = Format-DiagReportState -Token $misc.Trim -Reason 'not collected' }
    Add-DiagReportField -Buffer $b -Label 'TRIM' -Value $trimText

    $uptime = 'unavailable (not collected)'
    if ($null -ne $misc) { $uptime = Format-DiagReportUnit -Value $misc.UptimeHours -Decimals 1 -Unit 'h' }
    Add-DiagReportField -Buffer $b -Label 'Uptime' -Value $uptime

    $build = 'unavailable (not collected)'
    if ($null -ne $misc) { $build = Format-DiagReportText -Value $misc.WindowsBuild -Reason 'not collected' }
    Add-DiagReportField -Buffer $b -Label 'Windows build' -Value $build

    # RF-25 pagefile configuration (the facts live under power in the snapshot).
    $pagefile = $null
    if ($null -ne $power) { $pagefile = $power.Pagefile }
    if ($null -eq $pagefile) {
        Add-DiagReportField -Buffer $b -Label 'pagefile' -Value ('unavailable (' + (Get-DiagReportSectionReason -Snapshot $Snapshot -Section $power -Collector 'power.pagefile') + ')')
    } else {
        $entries = @($pagefile.Entries)
        $automatic = Get-DiagReportEntryValue -Entry $pagefile -Name 'AutomaticManaged'
        if ($automatic -eq $true) {
            Add-DiagReportField -Buffer $b -Label 'pagefile' -Value 'system managed'
        } elseif ($entries.Count -eq 0) {
            if ($automatic -eq $false) {
                Add-DiagReportField -Buffer $b -Label 'pagefile' -Value 'none configured'
            } else {
                $reason = Get-DiagReportEntryValue -Entry $pagefile -Name 'Reason'
                Add-DiagReportField -Buffer $b -Label 'pagefile' -Value (Format-DiagReportText -Value $reason -Reason 'not collected')
            }
        }
        foreach ($entry in $entries) {
            if ($null -eq $entry) { continue }
            $line = '      ' + (Format-DiagReportText -Value $entry.Name -Reason 'no name') +
                '  allocated ' + (Format-DiagReportUnit -Value $entry.AllocatedGB -Decimals 1 -Unit 'GB') +
                '  used ' + (Format-DiagReportUnit -Value $entry.CurrentGB -Decimals 1 -Unit 'GB') +
                '  peak ' + (Format-DiagReportUnit -Value $entry.PeakGB -Decimals 1 -Unit 'GB')
            Add-DiagReportText -Buffer $b -Text $line
        }
    }

    if ($b.Count -eq 0) {
        Add-DiagReportText -Buffer $b -Text 'no data (misc collectors did not run)'
    }

    return @($b.ToArray())
}

# ---------------------------------------------------------------------------
# New-FullReport (section 8.2)
# ---------------------------------------------------------------------------

function New-FullReport {
    <#
      Renders sections 01-14 of the report (section 8.2) and returns the lines as
      [string[]]. It writes neither the console nor the disk: the entry point
      writes the artifact as UTF-8 without a BOM with CRLF line endings (RF-03,
      RNF-05), which is what keeps this function testable on Linux.

      -Path is part of the frozen seam of section 4.3 and names the artifact the
      caller is about to write; the renderer uses it only to echo nothing
      machine-specific into the body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $lines = New-DiagReportBuffer
    $meta = $Snapshot.meta

    $generated = 'unavailable (not recorded)'
    $hostName = 'unavailable (not recorded)'
    $mode = 'Unavailable'
    $elevatedText = 'no'
    $outputDir = 'unavailable (not recorded)'
    $version = 'unavailable (not recorded)'
    $windowDays = 30
    $offProvider = 0
    if ($null -ne $meta) {
        $generated = Format-DiagReportDate -Value $meta.Timestamp -Format 'yyyy-MM-dd HH:mm:ss zzz' -Reason 'not recorded'
        $hostName = Format-DiagReportText -Value $meta.Host -Reason 'not recorded'
        $modeText = Get-DiagReportEntryValue -Entry $meta -Name 'Mode'
        if (Test-DiagReportValue -Value $modeText) { $mode = [string]$modeText }
        if ((Get-DiagReportEntryValue -Entry $meta -Name 'Elevated') -eq $true) { $elevatedText = 'yes' }
        $outputDir = Format-DiagReportText -Value $meta.OutputDir -Reason 'not recorded'
        $version = Format-DiagReportText -Value $meta.Version -Reason 'not recorded'
        $windowValue = Get-DiagReportEntryValue -Entry $meta -Name 'WindowDays'
        if ($null -ne $windowValue) { $windowDays = [int]$windowValue }
        $offValue = Get-DiagReportEntryValue -Entry $meta -Name 'OffProviderDropped'
        if ($null -ne $offValue) { $offProvider = [int]$offValue }
    }

    $windowStart = Get-DiagReportWindowStart -Snapshot $Snapshot
    $windowText = 'last ' + [string]$windowDays + ' days (since ' + $windowStart.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) + ')'

    $windowsText = 'unavailable (not recorded)'
    if ($null -ne $Snapshot.system) {
        $caption = Get-DiagReportEntryValue -Entry $Snapshot.system -Name 'Caption'
        if (Test-DiagReportValue -Value $caption) {
            $windowsText = [string]$caption + ' ' + (Get-DiagReportSystemBuild -System $Snapshot.system)
        }
    }

    # Built with Add calls rather than an @(a + b, c + d) literal: inside an array
    # literal the comma binds tighter than "+", which silently splits every
    # concatenated element into two array items (and so into two report lines).
    Add-DiagReportText -Buffer $lines -Text $script:DiagReportRule
    Add-DiagReportText -Buffer $lines -Text ' PC DIAGNOSTICS REPORT'
    Add-DiagReportText -Buffer $lines -Text $script:DiagReportRule
    Add-DiagReportText -Buffer $lines -Text ('Generated      : ' + $generated)
    Add-DiagReportText -Buffer $lines -Text ('Host           : ' + $hostName)
    Add-DiagReportText -Buffer $lines -Text ('Windows        : ' + $windowsText)
    Add-DiagReportText -Buffer $lines -Text ('Window         : ' + $windowText)
    Add-DiagReportText -Buffer $lines -Text ('Mode           : ' + $mode)
    Add-DiagReportText -Buffer $lines -Text ('Elevated       : ' + $elevatedText)
    Add-DiagReportText -Buffer $lines -Text ('Output dir     : ' + $outputDir)
    Add-DiagReportText -Buffer $lines -Text ('Script version : ' + $version)
    Add-DiagReportText -Buffer $lines -Text ('Off-provider dropped: ' + (Format-DiagReportNumber -Value $offProvider -Decimals 0))
    Add-DiagReportText -Buffer $lines -Text $script:DiagReportThin
    Add-DiagReportText -Buffer $lines -Text ''

    if ($elevatedText -ne 'yes') {
        Add-DiagReportText -Buffer $lines -Text 'DEGRADED RUN: not elevated, some collectors require administrator.'
        Add-DiagReportText -Buffer $lines -Text ''
    }

    $titles = @(
        '[01] SYSTEM',
        '[02] CPU',
        '[03] MEMORY',
        '[04] STORAGE DEVICES',
        '[05] VOLUMES',
        '[06] LARGEST FOLDERS',
        '[07] EVENT SUMMARY',
        '[08] CRASHES / WER',
        '[09] BOOTS',
        '[10] POWER',
        '[11] LIGHTING',
        '[12] WINDOWS UPDATE',
        '[13] DRIVERS',
        '[14] MISC'
    )

    $bodies = New-Object System.Collections.ArrayList
    [void]$bodies.Add(@(Get-DiagReportSection01 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection02 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection03 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection04 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection05 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection06 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection07 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection08 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection09 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection10 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection11 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection12 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection13 -Snapshot $Snapshot))
    [void]$bodies.Add(@(Get-DiagReportSection14 -Snapshot $Snapshot))

    $index = 0
    while ($index -lt $titles.Count) {
        Add-DiagReportText -Buffer $lines -Text ('=== ' + $titles[$index] + ' ===')
        $body = @($bodies[$index])
        if ($body.Count -eq 0) {
            # A section body is never empty (section 8.2).
            Add-DiagReportText -Buffer $lines -Text 'SECTION UNAVAILABLE: no data returned'
        } else {
            foreach ($line in $body) { Add-DiagReportText -Buffer $lines -Text ([string]$line) }
        }
        Add-DiagReportText -Buffer $lines -Text ''
        $index = $index + 1
    }

    Add-DiagReportText -Buffer $lines -Text $script:DiagReportRule
    Add-DiagReportText -Buffer $lines -Text ' END OF REPORT'
    Add-DiagReportText -Buffer $lines -Text $script:DiagReportRule

    return @($lines.ToArray())
}

# ---------------------------------------------------------------------------
# Format-QuickReport (section 8.3, RF-28, RF-29)
# ---------------------------------------------------------------------------

function Get-DiagReportBaseline {
    <#
      The baseline decision, made from the previous state and the window alone so
      a fixture snapshot behaves like a real run (RF-29, EC-13):
        none (first run)            - no previous state, unparsable timestamp,
                                      future timestamp or a different host
        out of window (<date>)      - previous run older than the window start
        <date> (<age> h ago)        - usable baseline
    #>
    param($Snapshot, $Previous)
    $result = [pscustomobject]@{
        usable  = $false
        text    = 'baseline: none (first run)'
        lastRun = $null
    }

    $meta = $Snapshot.meta
    $windowDays = 30
    if ($null -ne $meta) {
        $windowValue = Get-DiagReportEntryValue -Entry $meta -Name 'WindowDays'
        if ($null -ne $windowValue) { $windowDays = [int]$windowValue }
    }
    $windowStart = Get-DiagReportWindowStart -Snapshot $Snapshot
    $now = Get-Date

    if ($null -ne $meta) {
        # A snapshot written for a specific window wins over a recomputation.
        $metaStart = ConvertTo-DiagDateTime -Value (Get-DiagReportEntryValue -Entry $meta -Name 'WindowStart')
        if ($null -ne $metaStart) { $windowStart = $metaStart }
    }

    if ($null -eq $Previous) { return $result }

    $lastRun = ConvertTo-DiagDateTime -Value (Get-DiagReportEntryValue -Entry $Previous -Name 'last_run_at')
    if ($null -eq $lastRun) { return $result }

    $previousHost = [string](Get-DiagReportEntryValue -Entry $Previous -Name 'host')
    $currentHost = ''
    if ($null -ne $meta) { $currentHost = [string](Get-DiagReportEntryValue -Entry $meta -Name 'Host') }
    if (-not [string]::IsNullOrEmpty($previousHost) -and -not [string]::IsNullOrEmpty($currentHost) -and $previousHost -ne $currentHost) {
        return $result
    }
    if ($lastRun -gt $now) { return $result }

    if ($lastRun -lt $windowStart) {
        $result.lastRun = $lastRun
        $result.text = 'baseline: out of window (' + $lastRun.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) + ')'
        return $result
    }

    $ageHours = [math]::Round(($now - $lastRun).TotalHours, 1)
    $result.usable = $true
    $result.lastRun = $lastRun
    $result.text = 'baseline: ' + $lastRun.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) + ' (' + (Format-DiagReportNumber -Value $ageHours -Decimals 1) + ' h ago)'
    return $result
}

function Get-DiagReportQuickRows {
    <#
      The ten rows of RF-28 in their fixed order, each with its totals and delta.
      A row whose totals cannot be read renders "unavailable", never 0.
    #>
    param($Snapshot, [bool]$BaselineUsable)

    $definitions = @(
        @{ Label = 'stornvme 129 (device reset)'; Keys = @('stornvme_129'); Source = 'counter' },
        @{ Label = 'disk 51 (paging error)'; Keys = @('disk_51'); Source = 'counter' },
        @{ Label = 'WHEA 17 (PCIe AER corrected)'; Keys = @('whea_17'); Source = 'counter' },
        # Id 18 is FATAL and 19/47 are corrected machine checks; the label says so
        # because the total below is a sum of both severities and a reader must
        # not read "+0" on a fatal error as "nothing corrected".
        @{ Label = 'WHEA 18 fatal, 19/47 corrected'; Keys = @('whea_18', 'whea_19', 'whea_47'); Source = 'counter' },
        @{ Label = 'Kernel-Power 41 (bugcheck)'; Keys = @('kernel_power_41'); Source = 'counter' },
        @{ Label = 'EventLog 6008 (dirty shutdown)'; Keys = @('eventlog_6008'); Source = 'counter' },
        @{ Label = 'App Error 1000'; Keys = @('app_error_1000'); Source = 'counter' },
        @{ Label = 'App Hang 1002'; Keys = @('app_hang_1002'); Source = 'counter' },
        @{ Label = 'WER unique dumps'; Keys = @(); Source = 'wer_dumps' },
        @{ Label = 'WER re-reports'; Keys = @(); Source = 'wer_repeats' }
    )

    $wer = $Snapshot.wer
    $rows = New-Object System.Collections.ArrayList

    foreach ($definition in $definitions) {
        $label = [string]$definition.Label
        $total = $null
        $delta = $null
        $available = $true

        if ($definition.Source -eq 'counter') {
            foreach ($key in @($definition.Keys)) {
                $counter = Get-DiagReportCounter -Snapshot $Snapshot -Key ([string]$key)
                if (-not $counter.present -or $null -eq $counter.total) {
                    # A sum with a missing term is not a total: report the gap.
                    $available = $false
                    $total = $null
                    $delta = $null
                    break
                }
                if ($null -eq $total) { $total = 0 }
                $total = [int]$total + [int]$counter.total
                if ($BaselineUsable -and $null -ne $counter.since_last_run) {
                    if ($null -eq $delta) { $delta = 0 }
                    $delta = [int]$delta + [int]$counter.since_last_run
                }
            }
        } elseif ($definition.Source -eq 'wer_dumps') {
            # The WER numbers come from the wer_1001 query: a failed query makes
            # them unknown, and a zero there would be a false zero (RF-27).
            $werCounter = Get-DiagReportCounter -Snapshot $Snapshot -Key 'wer_1001'
            if ($null -eq $wer -or ($werCounter.present -and $null -eq $werCounter.total)) {
                $available = $false
            } else {
                $total = $wer.unique_dumps
                $delta = $wer.new_signatures
                if ($null -eq $total) { $available = $false }
            }
        } elseif ($definition.Source -eq 'wer_repeats') {
            $werCounter = Get-DiagReportCounter -Snapshot $Snapshot -Key 'wer_1001'
            if ($null -eq $wer -or ($werCounter.present -and $null -eq $werCounter.total)) {
                $available = $false
            } else {
                $total = $wer.repeats
                if ($null -eq $total) { $available = $false }
            }
        }

        [void]$rows.Add([pscustomobject]@{
            Label     = $label
            Total     = $total
            Delta     = $delta
            Available = $available
        })
    }

    return @($rows.ToArray())
}

function Get-DiagReportRepeatsDelta {
    <#
      WER re-reports delta: the growth of the repeat count between the two
      states. It is a number only when the baseline is usable and both sides
      carry an integer; otherwise the delta column renders "-".
    #>
    param($Snapshot, $Previous, [bool]$BaselineUsable)
    if (-not $BaselineUsable) { return $null }
    if ($null -eq $Previous) { return $null }
    $previousWer = Get-DiagReportEntryValue -Entry $Previous -Name 'wer'
    if ($null -eq $previousWer) { return $null }
    $before = Get-DiagReportEntryValue -Entry $previousWer -Name 'repeats'
    if ($null -eq $before) { return $null }
    $wer = $Snapshot.wer
    if ($null -eq $wer) { return $null }
    $now = Get-DiagReportEntryValue -Entry $wer -Name 'repeats'
    if ($null -eq $now) { return $null }
    return ([int]$now - [int]$before)
}

function Get-DiagReportQuickDeviceBlock {
    <#
      Caps a block at -Max lines *including* the "+ n more" marker, so the 4-line
      cap of RF-28 and the 24-line ceiling of RF-28 cannot contradict each other.
    #>
    param([string[]]$Items, [int]$Max, [string]$MoreLabel)
    $result = New-Object System.Collections.ArrayList
    if ($null -eq $Items) { return @() }
    $count = $Items.Count
    if ($count -le $Max) {
        foreach ($item in $Items) { if ($null -ne $item) { [void]$result.Add($item) } }
        return @($result.ToArray())
    }
    $keep = $Max - 1
    if ($keep -lt 1) { $keep = 1 }
    $i = 0
    while ($i -lt $keep) {
        if ($null -ne $Items[$i]) { [void]$result.Add($Items[$i]) }
        $i = $i + 1
    }
    [void]$result.Add('+ ' + [string]([int]($count - $keep)) + ' more ' + $MoreLabel + ' not listed')
    return @($result.ToArray())
}

function Format-QuickReport {
    <#
      Returns the Quick-mode console lines in the fixed order of RF-28 (title,
      header, baseline, 10 counter rows, volume lines, NVMe lines, "state: <path>"),
      capped at 24 lines including the blank separator. No progress lines, no
      file paths other than the state path (RF-04, section 8.3).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        $Previous = $null
    )

    $lines = New-DiagReportBuffer
    $meta = $Snapshot.meta

    # --- title and header -------------------------------------------------
    Add-DiagReportText -Buffer $lines -Text 'PC DIAGNOSTICS - QUICK'

    $hostName = 'unavailable'
    $windowDays = 30
    $statePath = 'unavailable (no output directory)'
    if ($null -ne $meta) {
        $hostValue = Get-DiagReportEntryValue -Entry $meta -Name 'Host'
        if (Test-DiagReportValue -Value $hostValue) { $hostName = [string]$hostValue }
        $windowValue = Get-DiagReportEntryValue -Entry $meta -Name 'WindowDays'
        if ($null -ne $windowValue) { $windowDays = [int]$windowValue }
        $stateValue = Get-DiagReportEntryValue -Entry $meta -Name 'StatePath'
        if (-not [string]::IsNullOrWhiteSpace([string]$stateValue)) { $statePath = [string]$stateValue }
    }

    $winVersion = Get-DiagReportWindowsVersion -System $Snapshot.system
    $build = ''
    $miscBuild = $null
    if ($null -ne $Snapshot.misc) { $miscBuild = Get-DiagReportEntryValue -Entry $Snapshot.misc -Name 'WindowsBuild' }
    if ($null -ne $Snapshot.system) {
        $systemBuild = Get-DiagReportEntryValue -Entry $Snapshot.system -Name 'Build'
        if (Test-DiagReportValue -Value $systemBuild) { $build = [string]$systemBuild }
    }
    if ([string]::IsNullOrWhiteSpace($build) -and (Test-DiagReportValue -Value $miscBuild)) { $build = [string]$miscBuild }

    # "Win <release> <build>" reads as one field: an unknown release does not
    # print "unavailable unavailable".
    $winText = 'unavailable'
    if ($winVersion -ne 'unavailable' -and -not [string]::IsNullOrWhiteSpace($build)) { $winText = $winVersion + ' ' + $build }
    elseif ($winVersion -ne 'unavailable') { $winText = $winVersion }
    elseif (-not [string]::IsNullOrWhiteSpace($build)) { $winText = $build }

    $uptime = 'unavailable'
    if ($null -ne $Snapshot.system) {
        $uptimeHours = Get-DiagReportEntryValue -Entry $Snapshot.system -Name 'UptimeHours'
        if ($null -ne $uptimeHours) { $uptime = (Format-DiagReportNumber -Value $uptimeHours -Decimals 1) + ' h' }
    }

    Add-DiagReportText -Buffer $lines -Text ('Host ' + $hostName + ' | Win ' + $winText + ' | uptime ' + $uptime + ' | window ' + [string]$windowDays + ' d')

    # --- baseline ---------------------------------------------------------
    $baseline = Get-DiagReportBaseline -Snapshot $Snapshot -Previous $Previous
    Add-DiagReportText -Buffer $lines -Text $baseline.text
    Add-DiagReportText -Buffer $lines -Text ''

    # --- the ten rows -----------------------------------------------------
    $rows = Get-DiagReportQuickRows -Snapshot $Snapshot -BaselineUsable $baseline.usable
    $repeatsDelta = Get-DiagReportRepeatsDelta -Snapshot $Snapshot -Previous $Previous -BaselineUsable $baseline.usable

    # The total column is as wide as its widest value (at least 5), so the delta
    # column stays aligned on a degraded run where a total reads "unavailable".
    $totalTexts = @()
    foreach ($row in $rows) {
        $text = 'unavailable'
        if ($row.Available -and $null -ne $row.Total) { $text = Format-DiagReportNumber -Value $row.Total -Decimals 0 }
        $totalTexts = $totalTexts + @($text)
    }
    $totalWidth = 5
    foreach ($text in $totalTexts) { if ($text.Length -gt $totalWidth) { $totalWidth = $text.Length } }

    $rowIndex = 0
    foreach ($row in $rows) {
        $label = [string]$row.Label
        if ($label.Length -lt 36) { $label = $label.PadRight(36) }
        $totalText = [string]$totalTexts[$rowIndex]
        if ($totalText.Length -lt $totalWidth) { $totalText = $totalText.PadLeft($totalWidth) }

        $deltaValue = $row.Delta
        if ([string]$row.Label -eq 'WER re-reports') { $deltaValue = $repeatsDelta }
        if (-not $baseline.usable) { $deltaValue = $null }
        # An unavailable total cannot carry a delta: "+0" next to "unavailable"
        # would read as "nothing happened" when the truth is "unknown".
        if (-not $row.Available) { $deltaValue = $null }

        $deltaText = '-'
        $mark = ''
        if ($null -ne $deltaValue) {
            $signed = [int]$deltaValue
            if ($signed -ge 0) { $deltaText = '+' + (Format-DiagReportNumber -Value $signed -Decimals 0) }
            else { $deltaText = '-' + (Format-DiagReportNumber -Value ([math]::Abs($signed)) -Decimals 0) }
            if ($signed -gt 0) { $mark = ' !' }
        }

        Add-DiagReportText -Buffer $lines -Text ($label + ' ' + $totalText + '   ' + $deltaText + $mark)
        $rowIndex = $rowIndex + 1
    }

    # --- volumes and NVMe, one block each, capped at 4 lines including the
    #     overflow marker so the 24-line ceiling always holds --------------
    $volumes = @()
    if ($null -ne $Snapshot.volumes) { $volumes = @($Snapshot.volumes.Volumes) }

    $volumeLines = New-Object System.Collections.ArrayList
    foreach ($v in $volumes) {
        if ($null -eq $v) { continue }
        $mount = [string]$v.Mount
        if ($mount.EndsWith('\')) { $mount = $mount.Substring(0, $mount.Length - 1) }
        $pctText = 'unavailable'
        if ($null -ne $v.FreePct) { $pctText = (Format-DiagReportNumber -Value $v.FreePct -Decimals 1) + ' % free' }
        $freeText = 'unavailable'
        if ($null -ne $v.FreeGB) { $freeText = (Format-DiagReportNumber -Value $v.FreeGB -Decimals 1) + ' GB' }
        $line = $mount + ' ' + $pctText + ' (' + $freeText + ')'
        if ($null -ne $v.FreePct -and [double]$v.FreePct -lt 10.0) { $line = $line + ' !' }
        [void]$volumeLines.Add($line)
    }

    $nvmeLines = New-Object System.Collections.ArrayList
    $storageAvailable = $true
    $storageReason = 'not collected'
    $storage = $Snapshot.storage
    if ($null -eq $storage -or (Get-DiagReportEntryValue -Entry $storage -Name 'Available') -ne $true) {
        $storageAvailable = $false
        $storageReason = Get-DiagReportSectionReason -Snapshot $Snapshot -Section $storage -Collector 'storage.physicaldisk'
    }
    if ($storageAvailable) {
        foreach ($disk in @($storage.Disks)) {
            if ($null -eq $disk) { continue }
            if ([string]$disk.BusType -ne 'NVMe') { continue }
            $model = 'unavailable'
            if (Test-DiagReportValue -Value $disk.FriendlyName) { $model = [string]$disk.FriendlyName }
            $firmware = 'unavailable'
            if (Test-DiagReportValue -Value $disk.FirmwareVersion) { $firmware = [string]$disk.FirmwareVersion }
            $smart = $disk.Smart
            $temperature = Get-DiagReportEntryValue -Entry $smart -Name 'TemperatureC'
            $wear = Get-DiagReportEntryValue -Entry $smart -Name 'PercentageUsed'
            $critical = Get-DiagReportEntryValue -Entry $smart -Name 'CriticalWarning'

            $tempText = 'unavailable'
            if ($null -ne $temperature) { $tempText = (Format-DiagReportNumber -Value $temperature -Decimals 0) + ' C' }
            $wearText = 'unavailable'
            if ($null -ne $wear) { $wearText = (Format-DiagReportNumber -Value $wear -Decimals 0) + ' %' }

            $line = $model + ' | FW ' + $firmware + ' | ' + $tempText + ' | wear ' + $wearText
            $hot = $false
            if ($null -ne $temperature -and [double]$temperature -ge 70.0) { $hot = $true }
            if ($null -ne $wear -and [double]$wear -ge 80.0) { $hot = $true }
            if ($null -ne $critical -and [int]$critical -ne 0) { $hot = $true }
            if ($hot) { $line = $line + ' !' }
            [void]$nvmeLines.Add($line)
        }
    }

    Add-DiagReportText -Buffer $lines -Text ''
    foreach ($line in (Get-DiagReportQuickDeviceBlock -Items @($volumeLines.ToArray()) -Max 4 -MoreLabel 'volumes')) {
        Add-DiagReportText -Buffer $lines -Text ([string]$line)
    }
    if (-not $storageAvailable) {
        Add-DiagReportText -Buffer $lines -Text ('NVMe unavailable (' + (ConvertTo-DiagSingleLine -Text $storageReason -MaxLength 48) + ')')
    } elseif ($nvmeLines.Count -eq 0) {
        Add-DiagReportText -Buffer $lines -Text 'no NVMe device'
    } else {
        foreach ($line in (Get-DiagReportQuickDeviceBlock -Items @($nvmeLines.ToArray()) -Max 4 -MoreLabel 'NVMe devices')) {
            Add-DiagReportText -Buffer $lines -Text ([string]$line)
        }
    }

    # Hard ceiling (RF-28): 24 lines including the trailing "state:" line. The
    # blocks above are sized so this never fires (title, header, baseline, blank,
    # 10 rows, blank, 4 volume lines, 4 NVMe lines, state = 24); if a future
    # change breaks that arithmetic, the last device line is dropped rather than
    # the ceiling, and the state path is never the line that goes missing.
    $result = @($lines.ToArray())
    while ($result.Count -gt 23) {
        $trimmed = @()
        $i = 0
        while ($i -lt ($result.Count - 1)) { $trimmed = $trimmed + $result[$i]; $i = $i + 1 }
        $result = $trimmed
    }
    $result = $result + @('state: ' + $statePath)

    return $result
}
