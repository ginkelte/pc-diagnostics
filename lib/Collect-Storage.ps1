# lib/Collect-Storage.ps1
#
# Storage inventory (RF-08), NVMe SMART/health (RF-09), volume free space
# (RF-10) and the bounded folder scan (RF-11).
#
# Read-only. The only external program used anywhere in this file is fsutil in
# Collect-Config.ps1; nothing here writes to a device, a volume or the registry.

# ---------------------------------------------------------------------------
# NVMe SMART/Health Information log layout (NVMe Base Specification, section
# 5.14 "SMART / Health Information Log"). Byte offsets into the 512-byte log
# page. Every consumer of the log reads through these constants so an offset can
# be corrected in one place.
#
#    0        critical warning (bit field)
#    1..2     composite temperature, Kelvin, little endian, 0-based
#    3        available spare, percent
#    4        available spare threshold, percent
#    5        percentage used (endurance), percent - NOT a health percentage
#    32..47   data units read
#    48..63   data units written
#    128..143 power-on hours, 128-bit little endian
#    144..159 unsafe shutdowns, 128-bit little endian
#    160..175 media and data integrity errors, 128-bit little endian
#
# A log shorter than 176 bytes cannot supply the last three fields and is
# treated as absent (RF-09).
# ---------------------------------------------------------------------------
$script:DiagNvmeOffsetCriticalWarning   = 0
$script:DiagNvmeOffsetTemperature       = 1
$script:DiagNvmeOffsetAvailableSpare    = 3
$script:DiagNvmeOffsetPercentageUsed    = 5
$script:DiagNvmeOffsetPowerOnHours      = 128
$script:DiagNvmeOffsetUnsafeShutdowns   = 144
$script:DiagNvmeOffsetMediaErrors       = 160
$script:DiagNvmeMinimumLogLength        = 176
$script:DiagNvmeKelvinOffset            = 273

$script:DiagNvmeInteropReady = $false

function Initialize-DiagNvmeInterop {
    <#
      Compiles the DeviceIoControl wrapper on first use. Compiled lazily inside a
      function so dot-sourcing the library has no side effect. Returns $false
      when compilation is impossible (non-Windows host, restricted runspace).
    #>
    if ($script:DiagNvmeInteropReady) { return $true }

    $source = @'
using System;
using System.Runtime.InteropServices;

public static class PcDiagNvmeInterop
{
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;
    private const uint IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFileW(string name, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(IntPtr device, uint code,
        byte[] inBuffer, int inSize, byte[] outBuffer, int outSize,
        out int returned, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static void Put(byte[] buffer, int offset, uint value)
    {
        buffer[offset] = (byte)(value & 0xFF);
        buffer[offset + 1] = (byte)((value >> 8) & 0xFF);
        buffer[offset + 2] = (byte)((value >> 16) & 0xFF);
        buffer[offset + 3] = (byte)((value >> 24) & 0xFF);
    }

    // Returns the 512-byte SMART/Health Information log, or null.
    // Input buffer: STORAGE_PROPERTY_QUERY (PropertyId=StorageDeviceProtocolSpecificProperty,
    // QueryType=PropertyStandardQuery) followed by STORAGE_PROTOCOL_SPECIFIC_DATA
    // (Version 1, Size 48, ProtocolType NVMe, DataType LogPage, request value 02h).
    // The exact struct packing has to be confirmed against real hardware; the
    // caller treats null or a short buffer as "no health log" rather than zero.
    public static byte[] QueryHealthLog(int diskNumber)
    {
        IntPtr handle = CreateFileW(@"\\.\PhysicalDrive" + diskNumber,
            GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle == IntPtr.Zero || handle.ToInt64() == -1) { return null; }
        try
        {
            byte[] input = new byte[56];
            Put(input, 0, 49);   // StorageDeviceProtocolSpecificProperty
            Put(input, 4, 0);    // PropertyStandardQuery
            Put(input, 8, 1);    // STORAGE_PROTOCOL_SPECIFIC_DATA.Version
            Put(input, 12, 48);  // STORAGE_PROTOCOL_SPECIFIC_DATA.Size
            Put(input, 16, 3);   // ProtocolTypeNvme
            Put(input, 20, 2);   // NVMeDataTypeLogPage
            Put(input, 24, 2);   // log page identifier: SMART/Health Information
            Put(input, 28, 0);   // request sub value
            Put(input, 32, 8);   // ProtocolDataOffset
            Put(input, 36, 512); // ProtocolDataLength

            byte[] output = new byte[4096];
            int returned;
            bool ok = DeviceIoControl(handle, IOCTL_STORAGE_QUERY_PROPERTY,
                input, input.Length, output, output.Length, out returned, IntPtr.Zero);
            if (!ok || returned < 512) { return null; }

            // The protocol data block sits at the end of the returned buffer;
            // the fixed STORAGE_PROTOCOL_SPECIFIC_DATA header precedes it.
            byte[] log = new byte[512];
            Buffer.BlockCopy(output, returned - 512, log, 0, 512);
            return log;
        }
        finally
        {
            CloseHandle(handle);
        }
    }
}
'@

    try {
        Add-Type -TypeDefinition $source -ErrorAction Stop
        $script:DiagNvmeInteropReady = $true
        return $true
    } catch {
        $script:DiagNvmeInteropReady = $false
        return $false
    }
}

function Get-NvmeHealthLog {
    <#
      Returns the raw 512-byte NVMe health log for a physical disk, or $null when
      it cannot be read. Never throws (RF-09, section 4.3).
    #>
    param([Parameter(Mandatory = $true)][int]$DiskNumber)

    if (-not (Test-DiagWindowsHost)) { return $null }
    try {
        if (-not (Initialize-DiagNvmeInterop)) { return $null }
        $bytes = [PcDiagNvmeInterop]::QueryHealthLog($DiskNumber)
        if ($null -eq $bytes) { return $null }
        if ($bytes.Length -lt $script:DiagNvmeMinimumLogLength) { return $null }
        return ,$bytes
    } catch {
        return $null
    }
}

function ConvertFrom-DiagUInt128 {
    <#
      128-bit little-endian field to a number. Values that cannot fit a double
      without precision loss (or that are absurd for the field) are saturated
      rather than wrapped into a negative number.
    #>
    param([byte[]]$Bytes, [int]$Offset)
    if ($null -eq $Bytes -or $Bytes.Length -lt ($Offset + 16)) { return $null }
    $value = 0.0
    $i = 15
    while ($i -ge 0) {
        $value = ($value * 256.0) + [double]$Bytes[$Offset + $i]
        $i = $i - 1
    }
    if ($value -gt 9007199254740991.0) { return [long]9007199254740991 }
    return [long]$value
}

function Get-NvmeSmart {
    <#
      Per-field NVMe health, each field independently sourced (RF-09):

        critical_warning   log byte 0
        available_spare    log byte 3
        percentage_used    log byte 5           -> storage reliability Wear
        temperature_c      log bytes 1-2 Kelvin -> storage reliability Temperature
        power_on_hours     log bytes 128-143    -> storage reliability PowerOnHours
        unsafe_shutdowns   log bytes 144-159
        media_errors       log bytes 160-175    -> sum of uncorrected read+write
        predict_failure    MSStorageDriver_FailurePredictStatus (root\wmi)

      When no health log is available every byte-derived field stays $null and
      the renderer must print "unavailable (no NVMe health log)". Rendering 0 is
      a defect of the same class as the inflated event counts (RF-09).
    #>
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber,
        $PhysicalDisk = $null
    )

    $log = Get-NvmeHealthLog -DiskNumber $DiskNumber
    $hasLog = ($null -ne $log -and $log.Length -ge $script:DiagNvmeMinimumLogLength)

    $reliability = $null
    if ($null -ne $PhysicalDisk) {
        try { $reliability = Get-StorageReliabilityCounter -PhysicalDisk $PhysicalDisk -ErrorAction Stop } catch { $reliability = $null }
    }
    if ($null -eq $reliability) {
        try { $reliability = Get-StorageReliabilityCounter -DiskNumber $DiskNumber -ErrorAction Stop } catch { $reliability = $null }
    }

    $criticalWarning = $null
    $availableSpare = $null
    $percentageUsed = $null
    $temperature = $null
    $powerOnHours = $null
    $unsafeShutdowns = $null
    $mediaErrors = $null
    $sources = New-Object System.Collections.ArrayList

    if ($hasLog) {
        $criticalWarning = [int]$log[$script:DiagNvmeOffsetCriticalWarning]
        $availableSpare = [int]$log[$script:DiagNvmeOffsetAvailableSpare]
        $percentageUsed = [int]$log[$script:DiagNvmeOffsetPercentageUsed]
        $kelvin = ([int]$log[$script:DiagNvmeOffsetTemperature]) + (([int]$log[$script:DiagNvmeOffsetTemperature + 1]) * 256)
        if ($kelvin -gt 0) { $temperature = $kelvin - $script:DiagNvmeKelvinOffset }
        $powerOnHours = ConvertFrom-DiagUInt128 -Bytes $log -Offset $script:DiagNvmeOffsetPowerOnHours
        $unsafeShutdowns = ConvertFrom-DiagUInt128 -Bytes $log -Offset $script:DiagNvmeOffsetUnsafeShutdowns
        $mediaErrors = ConvertFrom-DiagUInt128 -Bytes $log -Offset $script:DiagNvmeOffsetMediaErrors
        [void]$sources.Add('health-log')
    }

    if ($null -eq $percentageUsed) {
        $wear = Get-DiagPropValue -Object $reliability -Name 'Wear' -Default $null
        if ($null -ne $wear) {
            $percentageUsed = [int]$wear
            [void]$sources.Add('wear-counter')
        }
    }
    if ($null -eq $temperature) {
        $temp = Get-DiagPropValue -Object $reliability -Name 'Temperature' -Default $null
        if ($null -ne $temp -and [int]$temp -gt 0) {
            $temperature = [int]$temp
            [void]$sources.Add('temperature-counter')
        }
    }
    if ($null -eq $powerOnHours) {
        $poh = Get-DiagPropValue -Object $reliability -Name 'PowerOnHours' -Default $null
        if ($null -ne $poh) {
            $powerOnHours = [long]$poh
            [void]$sources.Add('power-on-hours-counter')
        }
    }
    if ($null -eq $mediaErrors) {
        $readErrors = Get-DiagPropValue -Object $reliability -Name 'ReadErrorsUncorrected' -Default $null
        $writeErrors = Get-DiagPropValue -Object $reliability -Name 'WriteErrorsUncorrected' -Default $null
        if ($null -ne $readErrors -or $null -ne $writeErrors) {
            $sum = 0
            if ($null -ne $readErrors) { $sum = $sum + [int]$readErrors }
            if ($null -ne $writeErrors) { $sum = $sum + [int]$writeErrors }
            $mediaErrors = $sum
            [void]$sources.Add('uncorrected-error-counters')
        }
    }

    $predictFailure = $null
    try {
        $status = Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSStorageDriver_FailurePredictStatus' -ErrorAction Stop
        if ($null -ne $status) {
            $flag = Get-DiagPropValue -Object $status -Name 'PredictFailure' -Default $null
            if ($null -ne $flag) { $predictFailure = [bool]$flag }
        }
    } catch {
        $predictFailure = $null
    }

    $reason = $null
    if (-not $hasLog) { $reason = 'no NVMe health log' }

    return [pscustomobject]@{
        Available          = $hasLog
        Reason             = $reason
        HasHealthLog       = $hasLog
        Sources            = @($sources.ToArray())
        CriticalWarning    = $criticalWarning
        AvailableSparePct  = $availableSpare
        PercentageUsed     = $percentageUsed
        TemperatureC       = $temperature
        PowerOnHours       = $powerOnHours
        UnsafeShutdowns    = $unsafeShutdowns
        MediaErrors        = $mediaErrors
        PredictFailure     = $predictFailure
    }
}

# ---------------------------------------------------------------------------
# Disk inventory (RF-08)
# ---------------------------------------------------------------------------

function Get-DiagBusTypeName {
    <#
      STORAGE_BUS_TYPE value to name. Never renders the raw enum integer (RF-08).
    #>
    param($BusType)
    if ($null -eq $BusType) { return 'unknown(0)' }

    $asText = $null
    try { $asText = [string]$BusType } catch { $asText = $null }
    if (-not [string]::IsNullOrWhiteSpace($asText) -and -not ($asText -match '^\d+$')) {
        # Already a name (real Get-PhysicalDisk returns an enum whose ToString()
        # is the name; fixtures may return the name directly).
        return $asText
    }

    $n = 0
    try { $n = [int]$BusType } catch { return 'unknown(0)' }
    switch ($n) {
        1 { return 'SCSI' }
        2 { return 'ATAPI' }
        3 { return 'ATA' }
        4 { return 'IEEE1394' }
        5 { return 'SSA' }
        6 { return 'Fibre' }
        7 { return 'USB' }
        8 { return 'RAID' }
        9 { return 'iSCSI' }
        10 { return 'SAS' }
        11 { return 'SATA' }
        12 { return 'SD' }
        13 { return 'MMC' }
        14 { return 'Virtual' }
        15 { return 'FileBackedVirtual' }
        16 { return 'StorageSpaces' }
        17 { return 'NVMe' }
        18 { return 'SCM' }
        19 { return 'UFS' }
        default { return 'unknown(' + [string]$n + ')' }
    }
}

function Get-DiagMediaTypeName {
    param($MediaType)
    if ($null -eq $MediaType) { return 'unknown' }
    $asText = $null
    try { $asText = [string]$MediaType } catch { $asText = $null }
    if (-not [string]::IsNullOrWhiteSpace($asText) -and -not ($asText -match '^\d+$')) { return $asText }
    $n = 0
    try { $n = [int]$MediaType } catch { return 'unknown' }
    switch ($n) {
        3 { return 'HDD' }
        4 { return 'SSD' }
        5 { return 'SCM' }
        default { return 'Unspecified' }
    }
}

function Get-DiagDisks {
    <#
      One entry per physical disk, ordered by disk number ascending. Smart is
      populated later by Add-DiagNvmeSmart, which keeps step 4 (enumerate) and
      step 5 (read SMART) separately measurable.
    #>
    $disks = New-Object System.Collections.ArrayList
    $reason = $null

    $physical = @()
    try {
        $physical = @(Get-PhysicalDisk -ErrorAction Stop)
    } catch {
        $reason = Get-DiagErrorText -ErrorRecord $_
        Add-DiagProblem -Collector 'storage.physicaldisk' -Reason $reason
    }

    foreach ($d in $physical) {
        if ($null -eq $d) { continue }
        $busType = Get-DiagBusTypeName -BusType (Get-DiagPropValue -Object $d -Name 'BusType' -Default $null)
        $size = Get-DiagPropValue -Object $d -Name 'Size' -Default $null
        $sizeGb = $null
        if ($null -ne $size) {
            try { $sizeGb = [math]::Round([double]$size / 1073741824.0, 1) } catch { $sizeGb = $null }
        }
        $operational = Get-DiagPropValue -Object $d -Name 'OperationalStatus' -Default $null
        if ($null -ne $operational -and $operational -is [System.Array]) { $operational = ($operational -join ',') }
        $health = Get-DiagPropValue -Object $d -Name 'HealthStatus' -Default $null
        if ($null -eq $health) {
            $health = Get-DiagPropValue -Object $d -Name 'HealthStatusText' -Default $null
        }
        [void]$disks.Add([pscustomobject]@{
            DiskNumber        = Get-DiagPropValue -Object $d -Name 'DeviceId' -Default (Get-DiagPropValue -Object $d -Name 'Number' -Default $null)
            FriendlyName      = [string](Get-DiagPropValue -Object $d -Name 'FriendlyName' -Default '')
            SerialNumber      = [string](Get-DiagPropValue -Object $d -Name 'SerialNumber' -Default '')
            FirmwareVersion   = [string](Get-DiagPropValue -Object $d -Name 'FirmwareVersion' -Default '')
            BusType           = $busType
            MediaType         = (Get-DiagMediaTypeName -MediaType (Get-DiagPropValue -Object $d -Name 'MediaType' -Default $null))
            SizeGB            = $sizeGb
            HealthStatus      = [string]$health
            OperationalStatus = [string]$operational
            PartitionStyle    = $null
            IsBoot            = $null
            PhysicalDisk      = $d
            Smart             = $null
        })
    }

    # Partition style and boot/system flags live on Get-Disk, not Get-PhysicalDisk.
    try {
        $logical = @(Get-Disk -ErrorAction Stop)
        foreach ($disk in $disks) {
            foreach ($l in $logical) {
                if ($null -eq $l) { continue }
                $ln = Get-DiagPropValue -Object $l -Name 'Number' -Default $null
                if ($null -ne $ln -and $null -ne $disk.DiskNumber -and [string]$ln -eq [string]$disk.DiskNumber) {
                    $disk.PartitionStyle = [string](Get-DiagPropValue -Object $l -Name 'PartitionStyle' -Default '')
                    $disk.IsBoot = Get-DiagPropValue -Object $l -Name 'IsBoot' -Default $null
                }
            }
        }
    } catch {
        Add-DiagProblem -Collector 'storage.disk' -Reason (Get-DiagErrorText -ErrorRecord $_)
    }

    $ordered = @($disks.ToArray() | Sort-Object -Property @{ Expression = { $_.DiskNumber } })

    if ($ordered.Count -eq 0 -and [string]::IsNullOrEmpty($reason)) { $reason = 'no physical disk reported' }
    return [pscustomobject]@{
        Available = ($ordered.Count -gt 0)
        Reason    = $reason
        Disks     = $ordered
    }
}

function Add-DiagNvmeSmart {
    <#
      Fills the Smart sub-object for every disk whose bus type is NVMe. Non-NVMe
      disks keep Smart = $null; a machine without NVMe yields an empty NVMe block
      and "no NVMe device" in the report (EC-02).
    #>
    param($Disks)

    $result = New-Object System.Collections.ArrayList
    foreach ($d in @($Disks)) {
        if ($null -eq $d) { continue }
        if ($d.BusType -eq 'NVMe') {
            # [int]$null is 0 and does not throw: casting would silently read
            # disk 0's SMART and attribute it to this disk - a fabricated value
            # indistinguishable from a measured one. Parse the text instead, so
            # a missing or malformed number is refused rather than guessed.
            $raw = Get-DiagPropValue -Object $d -Name 'DiskNumber' -Default $null
            $rawText = ''
            if ($null -ne $raw) { $rawText = [string]$raw }
            $number = 0
            $parsed = $false
            try { $parsed = [int]::TryParse($rawText, [ref]$number) } catch { $parsed = $false }
            if (-not $parsed -or $number -lt 0) {
                $d.Smart = $null
                Add-DiagProblem -Collector 'nvme' -Reason ('disk number unavailable (DiskNumber=''' + $rawText + ''')')
            } else {
                $d.Smart = Get-NvmeSmart -DiskNumber $number -PhysicalDisk $d.PhysicalDisk
            }
        }
        [void]$result.Add($d)
    }
    return @($result.ToArray())
}

# ---------------------------------------------------------------------------
# Volumes (RF-10)
# ---------------------------------------------------------------------------

function Get-VolumeSpace {
    <#
      Fixed volumes only, ordered by mount ascending. FreePct is
      round(FreeGB / SizeGB * 100, 1) and is $null when the size is unknown, so
      state.json can store null instead of a fabricated 0 (section 7.2).
    #>
    $volumes = New-Object System.Collections.ArrayList
    $raw = @()

    try {
        $raw = @(Get-Volume -ErrorAction Stop)
    } catch {
        Add-DiagProblem -Collector 'volumes' -Reason (Get-DiagErrorText -ErrorRecord $_)
        return @()
    }

    foreach ($v in $raw) {
        if ($null -eq $v) { continue }
        $driveType = [string](Get-DiagPropValue -Object $v -Name 'DriveType' -Default '')
        $isFixed = ($driveType -eq 'Fixed') -or ($driveType -eq '3')
        if (-not $isFixed) { continue }

        $letter = [string](Get-DiagPropValue -Object $v -Name 'DriveLetter' -Default '')
        if ([string]::IsNullOrWhiteSpace($letter)) { continue }
        $mount = $letter
        if (-not $mount.EndsWith(':')) { $mount = $mount + ':' }
        $mount = $mount + '\'

        $sizeBytes = Get-DiagPropValue -Object $v -Name 'Size' -Default $null
        $freeBytes = Get-DiagPropValue -Object $v -Name 'SizeRemaining' -Default $null
        $sizeGb = $null
        $freeGb = $null
        if ($null -ne $sizeBytes) {
            try { $sizeGb = [math]::Round([double]$sizeBytes / 1073741824.0, 1) } catch { $sizeGb = $null }
        }
        if ($null -ne $freeBytes) {
            try { $freeGb = [math]::Round([double]$freeBytes / 1073741824.0, 1) } catch { $freeGb = $null }
        }

        $freePct = $null
        if ($null -ne $sizeGb -and $null -ne $freeGb -and $sizeGb -gt 0) {
            $freePct = [math]::Round(([double]$freeGb / [double]$sizeGb) * 100.0, 1)
        }

        [void]$volumes.Add([pscustomobject]@{
            Mount      = $mount
            SizeGB     = $sizeGb
            FreeGB     = $freeGb
            FreePct    = $freePct
            FileSystem = [string](Get-DiagPropValue -Object $v -Name 'FileSystem' -Default '')
            Label      = [string](Get-DiagPropValue -Object $v -Name 'FileSystemLabel' -Default '')
            UsedBytes  = $(if ($null -ne $sizeBytes -and $null -ne $freeBytes) { [double]$sizeBytes - [double]$freeBytes } else { $null })
            SizeBytes  = $sizeBytes
            FreeBytes  = $freeBytes
        })
    }

    return @($volumes.ToArray() | Sort-Object -Property @{ Expression = { $_.Mount } })
}

# ---------------------------------------------------------------------------
# Largest folders and files (RF-11)
# ---------------------------------------------------------------------------

function Test-DiagReparsePoint {
    <#
      True for a reparse point, junction or symbolic link. These are skipped and
      never followed: following one can leave the volume, double count, or loop.
    #>
    param($Item)
    if ($null -eq $Item) { return $false }
    $linkType = Get-DiagPropValue -Object $Item -Name 'LinkType' -Default $null
    if (-not [string]::IsNullOrWhiteSpace([string]$linkType)) { return $true }
    $attr = Get-DiagPropValue -Object $Item -Name 'Attributes' -Default $null
    if ($null -eq $attr) { return $false }
    try {
        return (([int]$attr -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $false
    }
}

function Measure-DiagFolderScan {
    <#
      Bounded recursive size scan of a volume root.

      Bounds (mandatory - an unbounded scan of a full 448 GB volume is a hang):
        * reparse points, junctions and links are skipped, never followed;
        * hard time budget (default 30 s per volume);
        * hard file cap (default 200,000 files per volume);
        * every file counts toward its folder total regardless of size; only the
          rendered listing is capped by -Top.

      Returns Folders and Files arrays plus ScannedBytes, FileCount and the stop
      reason ("time budget" or "file cap"), so the renderer can print
      "PARTIAL (scan stopped: <reason>)" and the section can compare scanned
      bytes with the volume's used bytes.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Volume,
        [int]$Top = 10,
        [int]$TimeBudgetSeconds = 30,
        [int]$MaxFiles = 200000
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $folders = New-Object System.Collections.ArrayList
    $files = New-Object System.Collections.ArrayList
    $scannedBytes = 0.0
    $fileCount = 0
    $stopReason = $null
    $keepFiles = $Top * 4
    if ($keepFiles -lt 40) { $keepFiles = 40 }

    $rootItems = @()
    try {
        $rootItems = @(Get-ChildItem -LiteralPath $Volume -Force -ErrorAction SilentlyContinue)
    } catch {
        $stopReason = 'unreadable root'
    }

    foreach ($child in $rootItems) {
        if ($null -eq $child) { continue }
        $isContainer = Get-DiagPropValue -Object $child -Name 'PSIsContainer' -Default $false
        if (-not $isContainer) { continue }
        if (Test-DiagReparsePoint -Item $child) { continue }

        $folderPath = [string](Get-DiagPropValue -Object $child -Name 'FullName' -Default '')
        if ([string]::IsNullOrWhiteSpace($folderPath)) { continue }

        $folderBytes = 0.0
        $folderFiles = 0
        $stack = New-Object System.Collections.Stack
        $stack.Push($folderPath)
        $folderStopped = $false

        while ($stack.Count -gt 0) {
            if ($sw.Elapsed.TotalSeconds -ge $TimeBudgetSeconds) {
                $stopReason = 'time budget'
                $folderStopped = $true
                break
            }
            if ($fileCount -ge $MaxFiles) {
                $stopReason = 'file cap'
                $folderStopped = $true
                break
            }
            $current = [string]$stack.Pop()
            $entries = @()
            try {
                $entries = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue)
            } catch {
                $entries = @()
            }
            foreach ($entry in $entries) {
                if ($null -eq $entry) { continue }
                if (Test-DiagReparsePoint -Item $entry) { continue }
                $entryIsContainer = Get-DiagPropValue -Object $entry -Name 'PSIsContainer' -Default $false
                if ($entryIsContainer) {
                    $stack.Push([string](Get-DiagPropValue -Object $entry -Name 'FullName' -Default ''))
                    continue
                }
                $length = Get-DiagPropValue -Object $entry -Name 'Length' -Default 0
                $size = 0.0
                try { $size = [double]$length } catch { $size = 0.0 }
                $folderBytes = $folderBytes + $size
                $folderFiles = $folderFiles + 1
                $scannedBytes = $scannedBytes + $size
                $fileCount = $fileCount + 1
                [void]$files.Add([pscustomobject]@{
                    Path  = [string](Get-DiagPropValue -Object $entry -Name 'FullName' -Default '')
                    Bytes = $size
                })
                if ($fileCount -ge $MaxFiles) { break }
            }
            if ($fileCount -ge $MaxFiles) {
                $stopReason = 'file cap'
                $folderStopped = $true
                break
            }
            if ($files.Count -gt 20000) {
                # Keep the candidate list bounded instead of holding every path.
                $trimmed = @($files.ToArray() | Sort-Object -Property @{ Expression = { $_.Bytes }; Descending = $true } | Select-Object -First $keepFiles)
                $files.Clear()
                foreach ($f in $trimmed) { [void]$files.Add($f) }
            }
        }

        [void]$folders.Add([pscustomobject]@{
            Path      = $folderPath
            Bytes     = $folderBytes
            SizeGB    = [math]::Round($folderBytes / 1073741824.0, 1)
            FileCount = $folderFiles
            Partial   = $null
        })

        if ($folderStopped) { break }
    }

    $sw.Stop()

    $folderList = @($folders.ToArray() | Sort-Object -Property @{ Expression = { $_.Bytes }; Descending = $true }, @{ Expression = { $_.Path }; Descending = $false })
    if ($Top -gt 0 -and $folderList.Count -gt $Top) {
        $folderList = @($folderList | Select-Object -First $Top)
    }

    # A stopped scan makes every size provisional, including the folder that was
    # still being walked. Marking all of them is safer than silently reporting a
    # short number as final.
    if (-not [string]::IsNullOrEmpty($stopReason)) {
        foreach ($f in $folderList) { $f.Partial = $stopReason }
    }

    $fileList = @($files.ToArray() | Sort-Object -Property @{ Expression = { $_.Bytes }; Descending = $true }, @{ Expression = { $_.Path }; Descending = $false })
    if ($Top -gt 0 -and $fileList.Count -gt $Top) {
        $fileList = @($fileList | Select-Object -First $Top)
    }
    $fileOutput = New-Object System.Collections.ArrayList
    foreach ($f in $fileList) {
        [void]$fileOutput.Add([pscustomobject]@{
            Path    = $f.Path
            Bytes   = $f.Bytes
            SizeGB  = [math]::Round([double]$f.Bytes / 1073741824.0, 1)
            Partial = $stopReason
        })
    }

    return [pscustomobject]@{
        Volume       = $Volume
        Folders      = $folderList
        Files        = @($fileOutput.ToArray())
        ScannedBytes = $scannedBytes
        ScannedGB    = [math]::Round($scannedBytes / 1073741824.0, 1)
        FileCount    = $fileCount
        Partial      = $stopReason
        Elapsed      = $sw.Elapsed.TotalSeconds
    }
}

function Get-LargestFolders {
    <#
      Top immediate child directories of -Volume by recursive size, descending.
      Each entry carries Path, SizeGB, FileCount and Partial ($null when the scan
      completed, otherwise "time budget" or "file cap").
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Volume,
        [int]$Top = 10,
        [int]$TimeBudgetSeconds = 30
    )
    $scan = Measure-DiagFolderScan -Volume $Volume -Top $Top -TimeBudgetSeconds $TimeBudgetSeconds
    return @($scan.Folders)
}

function Get-LargestFiles {
    <#
      Top individual files under -Volume by size, descending, then path
      ascending. Same 30 s / 200,000-file bounds as the folder scan (RF-11).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Volume,
        [int]$Top = 10,
        [int]$TimeBudgetSeconds = 30
    )
    $scan = Measure-DiagFolderScan -Volume $Volume -Top $Top -TimeBudgetSeconds $TimeBudgetSeconds
    return @($scan.Files)
}
