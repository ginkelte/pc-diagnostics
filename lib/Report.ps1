# lib/Report.ps1
#
# Renderer seam. These two functions are the ONLY consumers of the snapshot
# object (section 4.4), which is what makes them testable on Linux with fixtures.
#
# PART B OWNS THIS FILE. Only the signatures exist here so that
# Invoke-PcDiagnostics.ps1 loads and runs end to end while the renderers are
# still being written. Both stubs are inert: they write nothing and return
# nothing. Do not add rendering logic here without also filling in the section
# contract of section 8.2.

function New-FullReport {
    <#
      Renders sections 01-14 of the report and writes it to -Path as UTF-8
      without a byte order mark, with CRLF line endings (RF-03, RNF-05).

      A degraded run is a valid artifact: a section that could not be collected
      renders "SECTION UNAVAILABLE: <collector> (<reason>)" and never a zero.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    # TODO(part-b): render the 14 fixed sections in order and write the file.
    return
}

function Format-QuickReport {
    <#
      Returns the Quick-mode console lines in the fixed row order of RF-28
      (title, header, baseline, 10 counter rows, volume lines, NVMe lines,
      "state: <path>"), capped at 24 lines. No progress lines, no file paths
      other than the state path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        $Previous = $null
    )

    # TODO(part-b): return the quick table rows.
    return @()
}
