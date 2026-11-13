# tests/asserts.ps1
#
# Assertion library for the self-contained test suite (RT-01).
#
# Rules:
#   * no Pester, no module, no external dependency; PowerShell 5.1 compatible
#     syntax so the suite also runs on Windows PowerShell;
#   * an assertion RECORDS a failure and returns $false, it never throws, so one
#     bad expectation cannot hide the rest of a test;
#   * every failure carries the test name it happened in, and only the runner
#     decides PASS or FAIL from the failure count of a test;
#   * messages state expected and actual, because "assert failed" is useless a
#     month later.

if ($null -eq $script:TestFailures) { $script:TestFailures = New-Object System.Collections.ArrayList }
if ($null -eq $script:TestAssertions) { $script:TestAssertions = 0 }
if ($null -eq $script:TestCurrentName) { $script:TestCurrentName = '(unknown test)' }

function Set-TestCurrentName {
    param([string]$Name)
    $script:TestCurrentName = [string]$Name
}

function Get-TestCurrentName { return [string]$script:TestCurrentName }

function Get-TestFailureCount { return @($script:TestFailures).Count }

function Get-TestAssertionCount { return [int]$script:TestAssertions }

function Get-TestFailures { return @($script:TestFailures) }

function Clear-TestFailures {
    $script:TestFailures = New-Object System.Collections.ArrayList
    $script:TestAssertions = 0
}

function Get-TestValueText {
    <#
      Renders a value for a failure message: null, string, bool, number, and one
      level of collection. Never recurses deeply, so a cyclic object cannot hang
      the suite.
    #>
    param($Value)

    if ($null -eq $Value) { return '<null>' }
    if ($Value -is [bool]) {
        if ($Value) { return 'True' }
        return 'False'
    }
    if ($Value -is [string]) {
        $text = $Value
        if ($text.Length -gt 160) { $text = $text.Substring(0, 160) + '...' }
        return '"' + $text + '"'
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = New-Object System.Collections.ArrayList
        foreach ($key in @($Value.Keys)) {
            [void]$parts.Add([string]$key + '=' + (Get-TestValueText -Value $Value[$key]))
        }
        return '{' + (($parts.ToArray()) -join ', ') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -gt 8) {
            $head = @()
            $i = 0
            while ($i -lt 8) { $head = $head + @(Get-TestValueText -Value $items[$i]); $i = $i + 1 }
            return '[' + ($head -join ', ') + ', ... ' + [string]$items.Count + ' items]'
        }
        $parts = @()
        foreach ($item in $items) { $parts = $parts + @(Get-TestValueText -Value $item) }
        return '[' + ($parts -join ', ') + ']'
    }
    $text = [string]$Value
    if ($text.Length -gt 160) { $text = $text.Substring(0, 160) + '...' }
    return $text
}

function Add-TestFailure {
    <#
      Records one failure under the current test name. All assertions funnel
      through here so the runner has a single place to count.
    #>
    param([string]$Message)

    $script:TestAssertions = [int]$script:TestAssertions + 1
    $text = [string]$Message
    if ([string]::IsNullOrWhiteSpace($text)) { $text = 'assertion failed' }
    [void]$script:TestFailures.Add([pscustomobject]@{
        Test    = [string]$script:TestCurrentName
        Message = $text
    })
}

function Add-TestPass {
    $script:TestAssertions = [int]$script:TestAssertions + 1
}

function Test-AssertionFailed {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Add-TestPass; return $true }
    Add-TestFailure -Message $Message
    return $false
}

# ---------------------------------------------------------------------------
# Value assertions
# ---------------------------------------------------------------------------

function Assert-True {
    param($Condition, [string]$Message = 'expected a true condition')
    return (Test-AssertionFailed -Condition ([bool]$Condition) -Message ('expected True, got ' + (Get-TestValueText -Value $Condition) + ' :: ' + $Message))
}

function Assert-False {
    param($Condition, [string]$Message = 'expected a false condition')
    return (Test-AssertionFailed -Condition (-not [bool]$Condition) -Message ('expected False, got ' + (Get-TestValueText -Value $Condition) + ' :: ' + $Message))
}

function Assert-Null {
    param($Value, [string]$Message = 'expected null')
    return (Test-AssertionFailed -Condition ($null -eq $Value) -Message ('expected <null>, got ' + (Get-TestValueText -Value $Value) + ' :: ' + $Message))
}

function Assert-NotNull {
    param($Value, [string]$Message = 'expected a value')
    return (Test-AssertionFailed -Condition ($null -ne $Value) -Message ('expected a value, got <null> :: ' + $Message))
}

function Test-TestValueEqual {
    <#
      Shared equality rule for Assert-Equal / Assert-NotEqual. Booleans compare
      as booleans, numbers compare numerically (so 2 equals 2.0), everything else
      compares as a case-sensitive string.
    #>
    param($Expected, $Actual)

    if ($null -eq $Expected -and $null -eq $Actual) { return $true }
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    if ($Expected -is [bool] -or $Actual -is [bool]) { return ([bool]$Expected -eq [bool]$Actual) }
    $numeric = @([int], [long], [double], [decimal], [int16], [single])
    $expectedIsNumber = $false
    $actualIsNumber = $false
    foreach ($type in $numeric) {
        if ($Expected -is $type) { $expectedIsNumber = $true }
        if ($Actual -is $type) { $actualIsNumber = $true }
    }
    if ($expectedIsNumber -and $actualIsNumber) { return ([double]$Expected -eq [double]$Actual) }
    return ([string]$Expected -ceq [string]$Actual)
}

function Assert-Equal {
    <#
      Scalar equality. Booleans and numbers compare by value; everything else by
      case-sensitive string, so a locale with a decimal comma cannot invert the
      result of a numeric comparison.
    #>
    param($Expected, $Actual, [string]$Message = '')

    $equal = Test-TestValueEqual -Expected $Expected -Actual $Actual
    $detail = 'expected ' + (Get-TestValueText -Value $Expected) + ', got ' + (Get-TestValueText -Value $Actual)
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $detail = $detail + ' :: ' + $Message }
    return (Test-AssertionFailed -Condition $equal -Message $detail)
}

function Assert-NotEqual {
    param($Expected, $Actual, [string]$Message = '')
    $equal = Test-TestValueEqual -Expected $Expected -Actual $Actual
    $detail = 'expected the values to differ, both are ' + (Get-TestValueText -Value $Expected)
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $detail = $detail + ' :: ' + $Message }
    return (Test-AssertionFailed -Condition (-not $equal) -Message $detail)
}

function Assert-Near {
    param([double]$Expected, [double]$Actual, [double]$Tolerance = 0.05, [string]$Message = '')
    $delta = [math]::Abs($Expected - $Actual)
    $detail = 'expected ' + (Get-TestValueText -Value $Expected) + ' +/- ' + [string]$Tolerance + ', got ' + (Get-TestValueText -Value $Actual)
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $detail = $detail + ' :: ' + $Message }
    return (Test-AssertionFailed -Condition ($delta -le $Tolerance) -Message $detail)
}

function Assert-Match {
    param($Value, [string]$Pattern, [string]$Message = '')
    $text = ''
    if ($null -ne $Value) { $text = [string]$Value }
    $matched = $false
    try { $matched = ($text -match $Pattern) } catch { $matched = $false }
    $detail = 'expected a match for /' + $Pattern + '/, got ' + (Get-TestValueText -Value $Value)
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $detail = $detail + ' :: ' + $Message }
    return (Test-AssertionFailed -Condition $matched -Message $detail)
}

function Assert-NotMatch {
    param($Value, [string]$Pattern, [string]$Message = '')
    $text = ''
    if ($null -ne $Value) { $text = [string]$Value }
    $matched = $true
    try { $matched = ($text -match $Pattern) } catch { $matched = $true }
    $detail = 'expected no match for /' + $Pattern + '/, got ' + (Get-TestValueText -Value $Value)
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $detail = $detail + ' :: ' + $Message }
    return (Test-AssertionFailed -Condition (-not $matched) -Message $detail)
}

function Assert-Contains {
    <#
      Collection membership, or - for a string haystack - an ordinal substring
      search. Both shapes are needed: counters are collections, report lines are
      strings, and an assertion that guesses wrong would pass vacuously.
    #>
    param($Haystack, $Needle, [string]$Message = '')

    $found = $false
    if ($Haystack -is [string]) {
        $found = $Haystack.Contains([string]$Needle)
    } elseif ($null -ne $Haystack) {
        foreach ($item in @($Haystack)) {
            if ([string]$item -ceq [string]$Needle) { $found = $true; break }
        }
    }
    $detail = 'expected ' + (Get-TestValueText -Value $Haystack) + ' to contain ' + (Get-TestValueText -Value $Needle)
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $detail = $detail + ' :: ' + $Message }
    return (Test-AssertionFailed -Condition $found -Message $detail)
}

function Assert-NotContains {
    param($Haystack, $Needle, [string]$Message = '')

    $found = $false
    if ($Haystack -is [string]) {
        $found = $Haystack.Contains([string]$Needle)
    } elseif ($null -ne $Haystack) {
        foreach ($item in @($Haystack)) {
            if ([string]$item -ceq [string]$Needle) { $found = $true; break }
        }
    }
    $detail = 'expected ' + (Get-TestValueText -Value $Haystack) + ' NOT to contain ' + (Get-TestValueText -Value $Needle)
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $detail = $detail + ' :: ' + $Message }
    return (Test-AssertionFailed -Condition (-not $found) -Message $detail)
}

function Assert-LessOrEqual {
    param($Value, $Max, [string]$Message = '')
    $ok = $false
    try { $ok = ([double]$Value -le [double]$Max) } catch { $ok = $false }
    $detail = 'expected ' + (Get-TestValueText -Value $Value) + ' <= ' + (Get-TestValueText -Value $Max)
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $detail = $detail + ' :: ' + $Message }
    return (Test-AssertionFailed -Condition $ok -Message $detail)
}

function Assert-GreaterOrEqual {
    param($Value, $Min, [string]$Message = '')
    $ok = $false
    try { $ok = ([double]$Value -ge [double]$Min) } catch { $ok = $false }
    $detail = 'expected ' + (Get-TestValueText -Value $Value) + ' >= ' + (Get-TestValueText -Value $Min)
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $detail = $detail + ' :: ' + $Message }
    return (Test-AssertionFailed -Condition $ok -Message $detail)
}

function Assert-Count {
    param($Collection, [int]$Expected, [string]$Message = '')
    $actual = @($Collection).Count
    $detail = 'expected ' + [string]$Expected + ' items, got ' + [string]$actual
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $detail = $detail + ' :: ' + $Message }
    return (Test-AssertionFailed -Condition ($actual -eq $Expected) -Message $detail)
}

# ---------------------------------------------------------------------------
# Error assertions
# ---------------------------------------------------------------------------

function Assert-Throws {
    <#
      Runs -Script and requires a terminating error. -Code matches the
      FullyQualifiedErrorId or the exception message (that is where the toolkit's
      PROVIDER_FILTER_REQUIRED / ID_FILTER_REQUIRED tokens live); -Pattern is a
      regex on the message. A script that returns normally is a failure, and so
      is one that throws the wrong error.
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [string]$Code = '',
        [string]$Pattern = '',
        [string]$Message = ''
    )

    $threw = $false
    $errorText = ''
    $errorId = ''
    try {
        $null = & $Script
    } catch {
        $threw = $true
        try { $errorText = [string]$_.Exception.Message } catch { $errorText = '' }
        try { $errorId = [string]$_.FullyQualifiedErrorId } catch { $errorId = '' }
    }

    if (-not $threw) {
        Add-TestFailure -Message ('expected a terminating error, nothing was thrown :: ' + $Message)
        return $false
    }

    $ok = $true
    if (-not [string]::IsNullOrWhiteSpace($Code)) {
        $codeOk = ($errorId.Contains($Code) -or $errorText.Contains($Code))
        if (-not $codeOk) {
            Add-TestFailure -Message ('expected error code ' + $Code + ', got "' + $errorId + '" / "' + $errorText + '" :: ' + $Message)
            $ok = $false
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Pattern)) {
        $patternOk = $false
        try { $patternOk = ($errorText -match $Pattern) } catch { $patternOk = $false }
        if (-not $patternOk) {
            Add-TestFailure -Message ('expected the error message to match /' + $Pattern + '/, got "' + $errorText + '" :: ' + $Message)
            $ok = $false
        }
    }
    if ($ok) { Add-TestPass }
    return $ok
}

function Assert-NoThrow {
    param([Parameter(Mandatory = $true)][scriptblock]$Script, [string]$Message = '')
    try {
        $null = & $Script
        Add-TestPass
        return $true
    } catch {
        $text = ''
        try { $text = [string]$_.Exception.Message } catch { $text = '' }
        Add-TestFailure -Message ('expected no error, got "' + $text + '" :: ' + $Message)
        return $false
    }
}
