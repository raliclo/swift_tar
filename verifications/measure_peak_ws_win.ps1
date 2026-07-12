# measure_peak_ws_win.ps1 - run one swift_tar encode/decode invocation and
# report elapsed time + peak working set (Windows equivalent of macOS
# "/usr/bin/time -l"'s "maximum resident set size").
#
# Output: "<seconds>|<peakWorkingSetBytes>" on stdout.
#
# Note: comments in this file are English-only on purpose. Windows
# PowerShell 5.1 misreads non-ASCII characters in a BOM-less UTF-8 .ps1
# file (falls back to the system codepage), which corrupts parsing of
# subsequent lines - the same class of issue documented for .bat files
# elsewhere in this project.
param(
    [Parameter(Mandatory)][ValidateSet('encode', 'decode')][string]$Mode,
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][int]$N,
    [Parameter(Mandatory)][string]$Archive,
    [string]$Corpus,
    [string]$Dest
)

if ($Mode -eq 'encode') {
    $argList = @('-c', '-z', '-f', $Archive, '-n', "$N", $Corpus)
} else {
    $argList = @('-x', '-z', '-f', $Archive, '-C', $Dest, '-n', "$N")
}

# PeakWorkingSet64 is unreliable once queried after the process has already
# exited (the handle's memory-info snapshot goes stale/empty). Poll
# WorkingSet64 while the process is still alive instead and track our own
# running max.
$errFile = [System.IO.Path]::GetTempFileName()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $Exe -ArgumentList $argList -PassThru -WindowStyle Hidden -RedirectStandardOutput NUL -RedirectStandardError $errFile
$peak = [int64]0
while (-not $p.HasExited) {
    try {
        $p.Refresh()
        if ($p.WorkingSet64 -gt $peak) { $peak = $p.WorkingSet64 }
    } catch {}
    Start-Sleep -Milliseconds 5
}
$sw.Stop()
Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
"{0:N2}|{1}" -f $sw.Elapsed.TotalSeconds, $peak
