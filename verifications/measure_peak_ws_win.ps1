# measure_peak_ws_win.ps1 - run one swift_tar encode/decode invocation and
# report elapsed time + peak working set (Windows equivalent of macOS
# "/usr/bin/time -l"'s "maximum resident set size").
#
# Output: "<seconds>|<peakWorkingSetBytes>" on stdout.
#
# ---------------------------------------------------------------------------
# WHY THIS IS STILL POWERSHELL, 2026-08-18
#
# The project's scripting policy is zsh for everything except UAC elevation
# shims, and this is not one. It is a deliberate, measured exception: nothing
# reachable from zsh can sample a short-lived process often enough to see its
# peak. Every alternative was tried on a 0.6 s swift_tar encode whose true peak
# is ~58-59 MB:
#
#   tasklist, polled in a zsh loop
#       One poll costs 49-255 ms, so a 0.6 s run yields ONE OR TWO samples.
#       Three runs reported 51.9, 58.1 and 48.1 MB -- the last is 18% low. The
#       peak is caught by luck or not at all.
#
#   typeperf "\Process(swift_tar)\Working Set Peak"
#       This is the counter that would fix the sampling problem outright, since
#       the OS tracks the peak itself and one read would be enough. But typeperf
#       takes 1504 ms just to produce its first sample, and against the 0.6 s run
#       it captured ZERO readings.
#
#   wmic process get PeakWorkingSetSize
#       Removed from Windows 11; neither wmic nor System32\wbem\WMIC.exe exists.
#
# PowerShell polls WorkingSet64 every 5 ms in-process with no spawn per sample,
# giving ~120 samples over the same run and a spread of under 1.5 MB across
# repeats. That fidelity is the whole point of the measurement, so the script
# stays as it is until a zsh-reachable peak counter exists.
#
# If you replace it, reproduce the comparison above rather than assuming: a
# version that merely runs is not a version that measures.
#
# The Traditional Chinese half of this note is in todo/todo.md, under
# "PowerShell scripts", not here. This file's own header (above) records that
# PowerShell 5.1 misreads non-ASCII characters in a BOM-less UTF-8 .ps1 and
# corrupts the parsing of everything after them, so the project's bilingual rule
# gives way to the file's documented constraint rather than the other way round.
# A first attempt did add the Chinese text here, and it happened to parse and run
# correctly -- which is not evidence that it is safe, only that this code page
# was kind.
# ---------------------------------------------------------------------------
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
