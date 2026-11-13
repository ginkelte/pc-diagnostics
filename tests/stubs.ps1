# tests/stubs.ps1
#
# Stubs for every Windows dependency of the toolkit (RT-03). The suite runs on
# Linux PowerShell, where none of these commands exist, so each stub must:
#
#   * shadow the real cmdlet or executable by name (a function wins over a cmdlet
#     and over an external program, so dot-sourcing this file is enough);
#   * serve data from tests/fixtures/*.json, never from the machine;
#   * reject an incomplete filter, mirroring RF-14, so a collector that forgets a
#     filter fails loudly instead of returning a plausible empty set;
#   * append every call to $global:PcDiagCallLog, so a test can assert HOW a
#     cmdlet was called and not only what came back;
#   * never touch the registry, the network or the clock beyond fixed fixture
#     data, and never block: every stub returns or throws immediately.
#
# A stub that throws a query failure does it as a plain terminating error, which
# is what makes "unavailable" testable without a real Windows host.

if ($null -eq $global:PcDiagCallLog) { $global:PcDiagCallLog = New-Object System.Collections.ArrayList }
$global:PcDiagFixture = $null
$global:PcDiagFixtureName = ''
$global:PcDiagStubMode = 'normal'
$global:PcDiagStubErrorText = 'stub query failure'

$script:StubFixtureDir = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures'

# ---------------------------------------------------------------------------
# Fixture and call-log plumbing
# ---------------------------------------------------------------------------

function Reset-PcDiagStubs {
    <#
      Order independence (RT-07): every test starts from a clean call log, no
      fixture and normal stub behaviour.
    #>
    $global:PcDiagCallLog = New-Object System.Collections.ArrayList
    $global:PcDiagFixture = $null
    $global:PcDiagFixtureName = ''
    $global:PcDiagStubMode = 'normal'
    $global:PcDiagStubErrorText = 'stub query failure'
}

function Get-PcDiagFixtureDirectory { return [string]$script:StubFixtureDir }

function Set-PcDiagFixture {
    <#
      Loads tests/fixtures/<Name>.json. The file holds synthetic records only:
      provider names, ids, timestamps, messages and EventData. No hostname, no
      user name, no serial number (RT-05).
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $path = Join-Path -Path $script:StubFixtureDir -ChildPath ($Name + '.json')
    if (-not (Test-Path -LiteralPath $path)) {
        throw (New-Object System.Exception('STUB_FIXTURE_MISSING: ' + $path))
    }
    $text = Get-Content -LiteralPath $path -Raw
    $global:PcDiagFixture = ConvertFrom-Json -InputObject $text
    $global:PcDiagFixtureName = $Name
    return $global:PcDiagFixture
}

function Set-PcDiagFixtureObject {
    param([Parameter(Mandatory = $true)]$Fixture, [string]$Name = 'in-memory')
    $global:PcDiagFixture = $Fixture
    $global:PcDiagFixtureName = $Name
    return $global:PcDiagFixture
}

function Set-PcDiagStubMode {
    <#
      normal          - honest filter (provider and Id honoured)
      ignore-provider - a broken source that honours only the log and the time
                        (the real-world defect of section 1.2)
      no-events       - the HRESULT 0x80070490 "no events" failure (EC-04)
      throw           - a generic query failure ("unavailable")
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('normal', 'ignore-provider', 'no-events', 'throw')][string]$Mode, [string]$ErrorText = 'stub query failure')
    $global:PcDiagStubMode = $Mode
    $global:PcDiagStubErrorText = $ErrorText
}

function Add-PcDiagStubCall {
    param([string]$Cmdlet, $Arguments)
    [void]$global:PcDiagCallLog.Add([pscustomobject]@{
        Cmdlet    = [string]$Cmdlet
        Arguments = $Arguments
    })
}

function Get-PcDiagCalls {
    <#
      Recorded calls, newest last. -Cmdlet filters by name so a test does not have
      to know what else a collector touched.
    #>
    param([string]$Cmdlet = '')

    $result = New-Object System.Collections.ArrayList
    foreach ($call in @($global:PcDiagCallLog)) {
        if ($null -eq $call) { continue }
        if (-not [string]::IsNullOrEmpty($Cmdlet) -and [string]$call.Cmdlet -ne $Cmdlet) { continue }
        [void]$result.Add($call)
    }
    return @($result.ToArray())
}

function Get-PcDiagLastCall {
    param([string]$Cmdlet = '')
    $calls = @(Get-PcDiagCalls -Cmdlet $Cmdlet)
    if ($calls.Count -eq 0) { return $null }
    return $calls[$calls.Count - 1]
}

# ---------------------------------------------------------------------------
# Error helpers
# ---------------------------------------------------------------------------

function New-PcDiagStubFilterError {
    <#
      The same loud rejection the real guard produces, from the stub's side: a
      collector that drops a filter must not silently get an empty result.
    #>
    param([string]$Missing)

    $message = 'STUB_' + $Missing + '_FILTER_REQUIRED: the stub refuses to query without ' + $Missing + '.'
    $ex = New-Object System.Exception($message)
    return (New-Object System.Management.Automation.ErrorRecord(
        $ex, ('STUB_' + $Missing + '_FILTER_REQUIRED'),
        [System.Management.Automation.ErrorCategory]::InvalidArgument, $Missing))
}

function New-PcDiagStubNoEventsError {
    <#
      Mirrors Get-WinEvent's "No events were found that match the specified
      selection criteria" (HRESULT 0x80070490 = -2147023728). The HRESULT is the
      contract: EC-04 forbids detecting this case by message text.
    #>
    $ex = New-Object System.Exception('No events were found that match the specified selection criteria.')
    try { $ex.HResult = -2147023728 } catch { }
    return $ex
}

# ---------------------------------------------------------------------------
# Event fixtures
# ---------------------------------------------------------------------------

function New-PcDiagEvent {
    <#
      Builds one synthetic event object with the shape Get-WinEvent returns:
      TimeCreated, Id, ProviderName, LevelDisplayName, Message and an EventData
      map. Used both by the fixture loader and by in-memory generators.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $true)]$TimeCreated,
        [string]$Message = '',
        $Data = $null,
        [string]$Level = 'Warning'
    )

    $stamp = $TimeCreated
    if (-not ($stamp -is [datetime])) { $stamp = [datetime]::Parse([string]$stamp, [System.Globalization.CultureInfo]::InvariantCulture) }

    $dataMap = [ordered]@{}
    if ($null -ne $Data) {
        if ($Data -is [System.Collections.IDictionary]) {
            foreach ($key in $Data.Keys) { $dataMap[[string]$key] = $Data[$key] }
        } else {
            foreach ($property in $Data.PSObject.Properties) { $dataMap[[string]$property.Name] = $property.Value }
        }
    }

    return [pscustomobject]@{
        TimeCreated      = $stamp
        Id               = $Id
        ProviderName     = $ProviderName
        LevelDisplayName = $Level
        Level            = 3
        Message          = $Message
        Data             = $dataMap
    }
}

function ConvertTo-PcDiagFixtureEvent {
    param($Record)

    $dataMap = [ordered]@{}
    $data = $null
    try { $data = $Record.PSObject.Properties['Data'] } catch { $data = $null }
    if ($null -ne $data -and $null -ne $data.Value) {
        foreach ($property in $data.Value.PSObject.Properties) { $dataMap[[string]$property.Name] = $property.Value }
    }

    return (New-PcDiagEvent -Id ([int]$Record.Id) -ProviderName ([string]$Record.ProviderName) -TimeCreated ([string]$Record.TimeCreated) -Message ([string](Get-PcDiagRecordValue -Record $Record -Name 'Message' -Default '')) -Data $dataMap -Level ([string](Get-PcDiagRecordValue -Record $Record -Name 'Level' -Default 'Warning')))
}

function Get-PcDiagRecordValue {
    param($Record, [string]$Name, $Default = $null)
    if ($null -eq $Record) { return $Default }
    $property = $null
    try { $property = $Record.PSObject.Properties[$Name] } catch { $property = $null }
    if ($null -eq $property) { return $Default }
    if ($null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-PcDiagFixtureLog {
    <#
      The raw records of one log from the loaded fixture, or an empty array.
    #>
    param([string]$LogName)

    if ($null -eq $global:PcDiagFixture) { return @() }
    $logs = $null
    try { $logs = $global:PcDiagFixture.PSObject.Properties['logs'] } catch { $logs = $null }
    if ($null -eq $logs -or $null -eq $logs.Value) { return @() }
    $logProperty = $null
    try { $logProperty = $logs.Value.PSObject.Properties[$LogName] } catch { $logProperty = $null }
    if ($null -eq $logProperty -or $null -eq $logProperty.Value) { return @() }
    return @($logProperty.Value)
}

# ---------------------------------------------------------------------------
# Get-WinEvent
# ---------------------------------------------------------------------------

function Get-WinEvent {
    <#
      Event query stub. Honours -FilterHashtable (LogName, ProviderName, Id,
      StartTime, Level) and -MaxEvents, and throws when any of the four required
      keys is missing.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$FilterHashtable,
        [int]$MaxEvents = 0,
        [string[]]$LogName,
        [string[]]$ProviderName,
        [int[]]$Id,
        [datetime]$StartTime
    )

    $filter = @{}
    if ($null -ne $FilterHashtable) {
        foreach ($key in $FilterHashtable.Keys) { $filter[[string]$key] = $FilterHashtable[$key] }
    }
    if ($PSBoundParameters.ContainsKey('LogName')) { $filter['LogName'] = @($LogName) }
    if ($PSBoundParameters.ContainsKey('ProviderName')) { $filter['ProviderName'] = @($ProviderName) }
    if ($PSBoundParameters.ContainsKey('Id')) { $filter['Id'] = @($Id) }
    if ($PSBoundParameters.ContainsKey('StartTime')) { $filter['StartTime'] = $StartTime }

    $logValue = ''
    if ($filter.ContainsKey('LogName')) {
        $logItems = @($filter['LogName'])
        if ($logItems.Count -gt 0) { $logValue = [string]$logItems[0] }
    }

    $providers = @()
    if ($filter.ContainsKey('ProviderName')) {
        foreach ($item in @($filter['ProviderName'])) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item)) { $providers = $providers + @([string]$item) }
        }
    }

    $ids = @()
    if ($filter.ContainsKey('Id')) {
        foreach ($item in @($filter['Id'])) { $ids = $ids + @([int]$item) }
    }

    $since = $null
    if ($filter.ContainsKey('StartTime') -and $null -ne $filter['StartTime']) {
        $since = $filter['StartTime']
        if (-not ($since -is [datetime])) {
            try { $since = [datetime]::Parse([string]$since, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $since = $null }
        }
    }

    Add-PcDiagStubCall -Cmdlet 'Get-WinEvent' -Arguments ([pscustomobject]@{
        LogName      = $logValue
        ProviderName = $providers
        Id           = $ids
        StartTime    = $since
        MaxEvents    = $MaxEvents
        Filter       = $filter
    })

    # RF-14 from the other side: the source refuses an incomplete filter.
    if ([string]::IsNullOrWhiteSpace($logValue)) { throw (New-PcDiagStubFilterError -Missing 'LOGNAME') }
    if ($providers.Count -eq 0) { throw (New-PcDiagStubFilterError -Missing 'PROVIDER') }
    if ($ids.Count -eq 0) { throw (New-PcDiagStubFilterError -Missing 'ID') }
    if ($null -eq $since) { throw (New-PcDiagStubFilterError -Missing 'STARTTIME') }

    $mode = [string]$global:PcDiagStubMode
    if ($mode -eq 'throw') {
        throw (New-Object System.Exception([string]$global:PcDiagStubErrorText))
    }
    if ($mode -eq 'no-events') {
        throw (New-PcDiagStubNoEventsError)
    }

    $matches = New-Object System.Collections.ArrayList
    foreach ($record in (Get-PcDiagFixtureLog -LogName $logValue)) {
        if ($null -eq $record) { continue }
        $event = ConvertTo-PcDiagFixtureEvent -Record $record
        if ($event.TimeCreated -lt $since) { continue }
        if ($mode -ne 'ignore-provider') {
            $providerOk = $false
            foreach ($provider in $providers) {
                if ([string]$event.ProviderName -eq $provider) { $providerOk = $true; break }
            }
            if (-not $providerOk) { continue }
            $idOk = $false
            foreach ($wanted in $ids) {
                if ([int]$event.Id -eq $wanted) { $idOk = $true; break }
            }
            if (-not $idOk) { continue }
        }
        [void]$matches.Add($event)
    }

    if ($matches.Count -eq 0) {
        # The real cmdlet raises this instead of returning nothing.
        throw (New-PcDiagStubNoEventsError)
    }

    $result = @($matches.ToArray())
    if ($MaxEvents -gt 0 -and $result.Count -gt $MaxEvents) {
        $result = @($result | Select-Object -First $MaxEvents)
    }
    return $result
}

# ---------------------------------------------------------------------------
# CIM and storage stubs
# ---------------------------------------------------------------------------

function Get-CimInstance {
    <#
      Returns the fixture's "cim" array (optionally filtered by -ClassName), or an
      empty array. Never queries WMI: on Linux there is none.
    #>
    [CmdletBinding()]
    param(
        [string]$ClassName,
        [string]$Namespace,
        [string]$Filter,
        [string]$ComputerName
    )

    Add-PcDiagStubCall -Cmdlet 'Get-CimInstance' -Arguments ([pscustomobject]@{
        ClassName = $ClassName
        Namespace = $Namespace
        Filter    = $Filter
    })

    if ([string]$global:PcDiagStubMode -eq 'throw') {
        throw (New-Object System.Exception([string]$global:PcDiagStubErrorText))
    }

    $rows = @()
    if ($null -ne $global:PcDiagFixture) {
        $property = $null
        try { $property = $global:PcDiagFixture.PSObject.Properties['cim'] } catch { $property = $null }
        if ($null -ne $property -and $null -ne $property.Value) { $rows = @($property.Value) }
    }
    if ([string]::IsNullOrWhiteSpace($ClassName)) { return $rows }

    $selected = @()
    foreach ($row in $rows) {
        $rowClass = [string](Get-PcDiagRecordValue -Record $row -Name 'ClassName' -Default '')
        if ($rowClass -eq $ClassName) { $selected = $selected + @($row) }
    }
    return $selected
}

function Get-PhysicalDisk {
    [CmdletBinding()]
    param([switch]$CanPool, [string]$FriendlyName)

    Add-PcDiagStubCall -Cmdlet 'Get-PhysicalDisk' -Arguments ([pscustomobject]@{ FriendlyName = $FriendlyName })
    if ([string]$global:PcDiagStubMode -eq 'throw') { throw (New-Object System.Exception([string]$global:PcDiagStubErrorText)) }
    if ($null -eq $global:PcDiagFixture) { return @() }
    $property = $null
    try { $property = $global:PcDiagFixture.PSObject.Properties['physical_disks'] } catch { $property = $null }
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    return @($property.Value)
}

function Get-Disk {
    [CmdletBinding()]
    param([int]$Number)

    Add-PcDiagStubCall -Cmdlet 'Get-Disk' -Arguments ([pscustomobject]@{ Number = $Number })
    if ([string]$global:PcDiagStubMode -eq 'throw') { throw (New-Object System.Exception([string]$global:PcDiagStubErrorText)) }
    if ($null -eq $global:PcDiagFixture) { return @() }
    $property = $null
    try { $property = $global:PcDiagFixture.PSObject.Properties['disks'] } catch { $property = $null }
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    $rows = @($property.Value)
    if ($PSBoundParameters.ContainsKey('Number')) {
        return @($rows | Where-Object { [int](Get-PcDiagRecordValue -Record $_ -Name 'Number' -Default -1) -eq $Number })
    }
    return $rows
}

function Get-Volume {
    [CmdletBinding()]
    param([string]$DriveLetter, [string]$UniqueId)

    Add-PcDiagStubCall -Cmdlet 'Get-Volume' -Arguments ([pscustomobject]@{ DriveLetter = $DriveLetter; UniqueId = $UniqueId })
    if ([string]$global:PcDiagStubMode -eq 'throw') { throw (New-Object System.Exception([string]$global:PcDiagStubErrorText)) }
    if ($null -eq $global:PcDiagFixture) { return @() }
    $property = $null
    try { $property = $global:PcDiagFixture.PSObject.Properties['volumes'] } catch { $property = $null }
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    return @($property.Value)
}

function Get-StorageReliabilityCounter {
    [CmdletBinding()]
    param([string]$DiskNumber)

    Add-PcDiagStubCall -Cmdlet 'Get-StorageReliabilityCounter' -Arguments ([pscustomobject]@{ DiskNumber = $DiskNumber })
    if ([string]$global:PcDiagStubMode -eq 'throw') { throw (New-Object System.Exception([string]$global:PcDiagStubErrorText)) }
    return $null
}

function Get-NvmeHealthLog {
    <#
      Replaces only the fetch (the DeviceIoControl P/Invoke in
      Collect-Storage.ps1) with fixture data: a 512-byte zeroed log page when
      the fixture says the health log exists, $null otherwise, which is the
      "no NVMe health log" case of RF-09. The real ConvertFrom-NvmeHealthLog
      still runs, so the offsets are exercised instead of bypassed.
    #>
    param([Parameter(Mandatory = $true)][int]$DiskNumber)

    Add-PcDiagStubCall -Cmdlet 'Get-NvmeHealthLog' -Arguments ([pscustomobject]@{ DiskNumber = $DiskNumber })
    if ([string]$global:PcDiagStubMode -eq 'throw') { throw (New-Object System.Exception([string]$global:PcDiagStubErrorText)) }

    $present = $false
    if ($null -ne $global:PcDiagFixture) {
        $property = $null
        try { $property = $global:PcDiagFixture.PSObject.Properties['nvme_health_log'] } catch { $property = $null }
        if ($null -ne $property -and $null -ne $property.Value) { $present = [bool]$property.Value }
    }
    if (-not $present) { return $null }
    return ,(New-Object byte[] 512)
}

function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$Path, [string]$Name)

    Add-PcDiagStubCall -Cmdlet 'Get-ItemProperty' -Arguments ([pscustomobject]@{ Path = $Path; Name = $Name })
    if ([string]$global:PcDiagStubMode -eq 'throw') { throw (New-Object System.Exception([string]$global:PcDiagStubErrorText)) }
    if ($null -eq $global:PcDiagFixture) { return $null }
    $property = $null
    try { $property = $global:PcDiagFixture.PSObject.Properties['registry'] } catch { $property = $null }
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    foreach ($row in @($property.Value)) {
        if ([string](Get-PcDiagRecordValue -Record $row -Name 'Path' -Default '') -ne $Path) { continue }
        return [pscustomobject]@{ $Name = (Get-PcDiagRecordValue -Record $row -Name 'Value' -Default $null) }
    }
    return $null
}

function Get-HotFix {
    [CmdletBinding()]
    param()

    Add-PcDiagStubCall -Cmdlet 'Get-HotFix' -Arguments $null
    if ([string]$global:PcDiagStubMode -eq 'throw') { throw (New-Object System.Exception([string]$global:PcDiagStubErrorText)) }
    return @()
}

function Get-Service {
    [CmdletBinding()]
    param([string]$Name, [string[]]$DisplayName)

    Add-PcDiagStubCall -Cmdlet 'Get-Service' -Arguments ([pscustomobject]@{ Name = $Name; DisplayName = $DisplayName })
    if ([string]$global:PcDiagStubMode -eq 'throw') { throw (New-Object System.Exception([string]$global:PcDiagStubErrorText)) }
    return @()
}

function fsutil.exe {
    <#
      Locale-independent fsutil output from the fixture ("fsutil" key: an array of
      lines). Defined under the .exe name because that is how the collector
      invokes it; a function outranks an external program of the same name.
    #>
    param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

    Add-PcDiagStubCall -Cmdlet 'fsutil' -Arguments ([pscustomobject]@{ Arguments = @($Arguments) })
    if ([string]$global:PcDiagStubMode -eq 'throw') { throw (New-Object System.Exception([string]$global:PcDiagStubErrorText)) }
    if ($null -eq $global:PcDiagFixture) { return @() }
    $property = $null
    try { $property = $global:PcDiagFixture.PSObject.Properties['fsutil'] } catch { $property = $null }
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    return @($property.Value)
}

function fsutil {
    param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
    return (fsutil.exe @Arguments)
}

function Start-Process {
    <#
      dxdiag must never actually launch: the stub records the call and pretends
      the process ran out of time, which is the EC-07 "timeout" branch.
    #>
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [switch]$Wait,
        [switch]$NoNewWindow,
        [int]$TimeoutSeconds
    )

    Add-PcDiagStubCall -Cmdlet 'Start-Process' -Arguments ([pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList })
    if ([string]$global:PcDiagStubMode -eq 'throw') { throw (New-Object System.Exception([string]$global:PcDiagStubErrorText)) }
    return [pscustomobject]@{ Id = 4242; HasExited = $false; ExitCode = $null }
}

function Get-Process {
    [CmdletBinding()]
    param([string]$Name)

    Add-PcDiagStubCall -Cmdlet 'Get-Process' -Arguments ([pscustomobject]@{ Name = $Name })
    return @()
}
