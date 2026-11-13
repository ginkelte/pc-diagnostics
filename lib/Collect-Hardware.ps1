# lib/Collect-Hardware.ps1
#
# Hardware inventory: system identity (RF-05), display adapters (RF-08b),
# CPU (RF-06) and memory modules (RF-07).
#
# Every collector returns an object with Available/Reason plus its data fields.
# A failed query degrades exactly one section and records a problem; it never
# throws at the caller and it never renders a false zero (RF-27, AD-06).

function Get-DiagSystem {
    <#
      Operating system, firmware and uptime. Uptime is derived from
      Win32_OperatingSystem.LastBootUpTime and exposed in hours with one decimal
      so the renderer prints "51.2 h" instead of a raw TimeSpan (RF-05).
    #>
    $reason = $null
    $os = $null
    $cs = $null
    $bb = $null
    $bios = $null

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    } catch {
        $reason = Get-DiagErrorText -ErrorRecord $_
        Add-DiagProblem -Collector 'system.os' -Reason $reason
    }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    } catch {
        Add-DiagProblem -Collector 'system.computersystem' -Reason (Get-DiagErrorText -ErrorRecord $_)
    }
    try {
        $bb = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop
    } catch {
        Add-DiagProblem -Collector 'system.baseboard' -Reason (Get-DiagErrorText -ErrorRecord $_)
    }
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    } catch {
        Add-DiagProblem -Collector 'system.bios' -Reason (Get-DiagErrorText -ErrorRecord $_)
    }

    # Build number plus UBR: "22631.4460" is the string users see in winver.
    $buildNumber = [string](Get-DiagPropValue -Object $os -Name 'BuildNumber' -Default '')
    $ubr = $null
    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($null -ne $cv) {
            if (-not [string]::IsNullOrWhiteSpace([string](Get-DiagPropValue -Object $cv -Name 'CurrentBuildNumber' -Default ''))) {
                $buildNumber = [string]$cv.CurrentBuildNumber
            }
            $ubrValue = Get-DiagPropValue -Object $cv -Name 'UBR' -Default $null
            if ($null -ne $ubrValue) { $ubr = [int]$ubrValue }
        }
    } catch {
        # A missing or unreadable key only costs the UBR suffix.
        Add-DiagProblem -Collector 'system.build' -Reason (Get-DiagErrorText -ErrorRecord $_)
    }
    $build = $buildNumber
    if (-not [string]::IsNullOrWhiteSpace($buildNumber) -and $null -ne $ubr) {
        $build = $buildNumber + '.' + [string]$ubr
    }

    $uptimeHours = $null
    $lastBoot = Get-DiagPropValue -Object $os -Name 'LastBootUpTime' -Default $null
    if ($null -ne $lastBoot) {
        try {
            $span = (Get-Date) - [datetime]$lastBoot
            $uptimeHours = [math]::Round($span.TotalHours, 1)
        } catch {
            $uptimeHours = $null
        }
    }

    $installDate = Get-DiagPropValue -Object $os -Name 'InstallDate' -Default $null
    $biosDate = Get-DiagPropValue -Object $bios -Name 'ReleaseDate' -Default $null

    $caption = [string](Get-DiagPropValue -Object $os -Name 'Caption' -Default '')
    if ([string]::IsNullOrWhiteSpace($caption)) { $caption = [string](Get-DiagPropValue -Object $os -Name 'Name' -Default '') }

    $available = ($null -ne $os)
    if (-not $available -and [string]::IsNullOrEmpty($reason)) { $reason = 'no operating system data' }

    return [pscustomobject]@{
        Available       = $available
        Reason          = $reason
        Caption         = $caption
        Version         = [string](Get-DiagPropValue -Object $os -Name 'Version' -Default '')
        Build           = $build
        BuildNumber     = $buildNumber
        UBR             = $ubr
        Edition         = [string](Get-DiagPropValue -Object $os -Name 'Caption' -Default '')
        InstallDate     = $installDate
        UptimeHours     = $uptimeHours
        LastBootUpTime  = $lastBoot
        Manufacturer    = [string](Get-DiagPropValue -Object $cs -Name 'Manufacturer' -Default '')
        Model           = [string](Get-DiagPropValue -Object $cs -Name 'Model' -Default '')
        BaseboardProduct = [string](Get-DiagPropValue -Object $bb -Name 'Product' -Default '')
        BaseboardManufacturer = [string](Get-DiagPropValue -Object $bb -Name 'Manufacturer' -Default '')
        BiosVendor      = [string](Get-DiagPropValue -Object $bios -Name 'Manufacturer' -Default '')
        BiosVersion     = [string](Get-DiagPropValue -Object $bios -Name 'SMBIOSBIOSVersion' -Default '')
        BiosDate        = $biosDate
    }
}

function Get-DiagGpu {
    <#
      Display adapters from Win32_VideoController, ordered by name ascending.
      Independent of dxdiag: -SkipDxDiag must not remove this block (RF-08b).
      A field the adapter does not report stays $null so the renderer can print
      "unavailable (<reason>)" instead of 0.
    #>
    $adapters = New-Object System.Collections.ArrayList
    $reason = $null

    try {
        $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
    } catch {
        $reason = Get-DiagErrorText -ErrorRecord $_
        Add-DiagProblem -Collector 'gpu' -Reason $reason
        return [pscustomobject]@{
            Available = $false
            Reason    = $reason
            Adapters  = @()
        }
    }

    foreach ($c in $controllers) {
        if ($null -eq $c) { continue }
        $vramBytes = Get-DiagPropValue -Object $c -Name 'AdapterRAM' -Default $null
        $vramGb = $null
        if ($null -ne $vramBytes) {
            try { $vramGb = [math]::Round([double]$vramBytes / 1073741824.0, 1) } catch { $vramGb = $null }
        }
        $driverDate = Get-DiagPropValue -Object $c -Name 'DriverDate' -Default $null
        $driverDateText = $null
        if ($null -ne $driverDate) {
            try { $driverDateText = ([datetime]$driverDate).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch { $driverDateText = $null }
        }
        $width = Get-DiagPropValue -Object $c -Name 'CurrentHorizontalResolution' -Default $null
        $height = Get-DiagPropValue -Object $c -Name 'CurrentVerticalResolution' -Default $null
        $refresh = Get-DiagPropValue -Object $c -Name 'CurrentRefreshRate' -Default $null
        $resolution = $null
        if ($null -ne $width -and $null -ne $height) {
            if ([int]$width -gt 0 -and [int]$height -gt 0) {
                $resolution = [string]$width + 'x' + [string]$height
            }
        }
        [void]$adapters.Add([pscustomobject]@{
            Name          = [string](Get-DiagPropValue -Object $c -Name 'Name' -Default '')
            DriverVersion = [string](Get-DiagPropValue -Object $c -Name 'DriverVersion' -Default '')
            DriverDate    = $driverDateText
            VramGB        = $vramGb
            Resolution    = $resolution
            RefreshHz     = $refresh
            VideoProcessor = [string](Get-DiagPropValue -Object $c -Name 'VideoProcessor' -Default '')
        })
    }

    $ordered = @($adapters.ToArray() | Sort-Object -Property @{ Expression = { $_.Name } })

    if ($ordered.Count -eq 0) {
        Add-DiagProblem -Collector 'gpu' -Reason 'no display adapter reported'
    }

    return [pscustomobject]@{
        Available = $true
        Reason    = $null
        Adapters  = $ordered
    }
}

function Get-DiagCpu {
    <#
      Name, cores, threads, socket and clocks. MaxClockSpeed of the current
      processor is the only "max" Windows exposes without a benchmark, and
      benchmarks are out of scope (NG5).
    #>
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
    } catch {
        $reason = Get-DiagErrorText -ErrorRecord $_
        Add-DiagProblem -Collector 'cpu' -Reason $reason
        return [pscustomobject]@{ Available = $false; Reason = $reason }
    }
    if ($null -eq $cpu) {
        $reason = 'no processor reported'
        Add-DiagProblem -Collector 'cpu' -Reason $reason
        return [pscustomobject]@{ Available = $false; Reason = $reason }
    }

    $cores = Get-DiagPropValue -Object $cpu -Name 'NumberOfCores' -Default $null
    $threads = Get-DiagPropValue -Object $cpu -Name 'NumberOfLogicalProcessors' -Default $null
    $baseMhz = Get-DiagPropValue -Object $cpu -Name 'CurrentClockSpeed' -Default $null
    $maxMhz = Get-DiagPropValue -Object $cpu -Name 'MaxClockSpeed' -Default $null

    $coreThreadText = $null
    if ($null -ne $cores -and $null -ne $threads) {
        $coreThreadText = [string]$cores + ' cores / ' + [string]$threads + ' threads'
    }

    return [pscustomobject]@{
        Available   = $true
        Reason      = $null
        Name        = [string](Get-DiagPropValue -Object $cpu -Name 'Name' -Default '')
        Cores       = $cores
        Threads     = $threads
        Socket      = [string](Get-DiagPropValue -Object $cpu -Name 'SocketDesignation' -Default '')
        BaseMHz     = $baseMhz
        MaxMHz      = $maxMhz
        CoreThread  = $coreThreadText
        Manufacturer = [string](Get-DiagPropValue -Object $cpu -Name 'Manufacturer' -Default '')
        ProcessorId = [string](Get-DiagPropValue -Object $cpu -Name 'ProcessorId' -Default '')
    }
}

function Get-DiagMemoryTypeName {
    <#
      SMBIOS memory type code to name. unknown(<n>) keeps the raw number visible
      instead of guessing (RF-07).
    #>
    param($Code)
    if ($null -eq $Code) { return 'unknown(0)' }
    $n = 0
    try { $n = [int]$Code } catch { return 'unknown(' + [string]$Code + ')' }
    switch ($n) {
        20 { return 'DDR' }
        21 { return 'DDR2' }
        22 { return 'DDR2 FB-DIMM' }
        24 { return 'DDR3' }
        25 { return 'FBD2' }
        26 { return 'DDR4' }
        27 { return 'LPDDR' }
        28 { return 'LPDDR2' }
        29 { return 'LPDDR3' }
        30 { return 'LPDDR4' }
        34 { return 'DDR5' }
        35 { return 'LPDDR5' }
        default { return 'unknown(' + [string]$n + ')' }
    }
}

function Get-DiagMemory {
    <#
      One entry per populated slot plus slot totals.

      Two clock fields are kept and labelled separately on purpose: Speed is the
      rated (SPD/XMP) speed and ConfiguredClockSpeed is what the memory bus is
      actually running at. Merging them hides the DDR4-3600-on-a-3200-part case
      (RF-07, section 1.4); the renderer emits the explicit
      "memory running below module rating" line when running < rated.
    #>
    $modules = New-Object System.Collections.ArrayList
    $reason = $null

    $totalSlots = $null
    try {
        $array = Get-CimInstance -ClassName Win32_PhysicalMemoryArray -ErrorAction Stop | Select-Object -First 1
        $totalSlots = Get-DiagPropValue -Object $array -Name 'MemoryDevices' -Default $null
    } catch {
        Add-DiagProblem -Collector 'memory.array' -Reason (Get-DiagErrorText -ErrorRecord $_)
    }

    try {
        $raw = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
    } catch {
        $reason = Get-DiagErrorText -ErrorRecord $_
        Add-DiagProblem -Collector 'memory' -Reason $reason
        return [pscustomobject]@{
            Available      = $false
            Reason         = $reason
            Modules        = @()
            TotalSlots     = $totalSlots
            PopulatedSlots = 0
            TotalGB        = $null
            BelowRated     = @()
        }
    }

    $totalBytes = 0
    foreach ($m in $raw) {
        if ($null -eq $m) { continue }
        $capacity = Get-DiagPropValue -Object $m -Name 'Capacity' -Default $null
        $capacityGb = $null
        if ($null -ne $capacity) {
            try {
                $capacityGb = [math]::Round([double]$capacity / 1073741824.0, 1)
                $totalBytes = $totalBytes + [double]$capacity
            } catch { $capacityGb = $null }
        }
        $smbiosType = Get-DiagPropValue -Object $m -Name 'SMBIOSMemoryType' -Default $null
        if ($null -eq $smbiosType) { $smbiosType = Get-DiagPropValue -Object $m -Name 'MemoryType' -Default $null }
        $rated = Get-DiagPropValue -Object $m -Name 'Speed' -Default $null
        $running = Get-DiagPropValue -Object $m -Name 'ConfiguredClockSpeed' -Default $null
        $voltage = Get-DiagPropValue -Object $m -Name 'ConfiguredVoltage' -Default $null
        $volts = $null
        if ($null -ne $voltage) {
            try { $volts = [math]::Round([double]$voltage / 1000.0, 1) } catch { $volts = $null }
        }
        [void]$modules.Add([pscustomobject]@{
            Manufacturer   = [string](Get-DiagPropValue -Object $m -Name 'Manufacturer' -Default '')
            PartNumber     = ([string](Get-DiagPropValue -Object $m -Name 'PartNumber' -Default '')).Trim()
            CapacityGB     = $capacityGb
            TypeCode       = $smbiosType
            Type           = (Get-DiagMemoryTypeName -Code $smbiosType)
            RatedMHz       = $rated
            RunningMHz     = $running
            Voltage        = $volts
            DeviceLocator  = [string](Get-DiagPropValue -Object $m -Name 'DeviceLocator' -Default '')
            BankLabel      = [string](Get-DiagPropValue -Object $m -Name 'BankLabel' -Default '')
            SerialNumber   = [string](Get-DiagPropValue -Object $m -Name 'SerialNumber' -Default '')
        })
    }

    $sorted = @($modules.ToArray() | Sort-Object -Property @{ Expression = { $_.DeviceLocator } })

    # Modules running below their rating, for the explicit RF-07 line.
    $belowRated = New-Object System.Collections.ArrayList
    foreach ($mod in $sorted) {
        if ($null -eq $mod.RatedMHz -or $null -eq $mod.RunningMHz) { continue }
        if ([int]$mod.RunningMHz -le 0) { continue }
        if ([int]$mod.RunningMHz -lt [int]$mod.RatedMHz) {
            [void]$belowRated.Add([pscustomobject]@{
                Module     = $mod.DeviceLocator
                RatedMHz   = [int]$mod.RatedMHz
                RunningMHz = [int]$mod.RunningMHz
            })
        }
    }

    $totalGb = $null
    if ($totalBytes -gt 0) { $totalGb = [math]::Round($totalBytes / 1073741824.0, 1) }

    return [pscustomobject]@{
        Available      = $true
        Reason         = $reason
        Modules        = $sorted
        TotalSlots     = $totalSlots
        PopulatedSlots = $sorted.Count
        TotalGB        = $totalGb
        BelowRated     = @($belowRated.ToArray())
    }
}
