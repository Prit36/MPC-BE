param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [string]$Media,
    [ValidateRange(1, 101)][int]$Runs = 11,
    [string]$OutputDirectory = "$PSScriptRoot/../_bin/startup-analysis",
    [switch]$LegacyTrace,
    [switch]$NoTrace
)

$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path -LiteralPath $Executable).Path
if ($Media) { $Media = (Resolve-Path -LiteralPath $Media).Path }
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
# WaitForInputIdle can return for a startup helper window. Observe the visible
# main window separately; both measurements include process creation/loader time.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class StartupWindowProbe {
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    public static bool IsPlayerWindow(IntPtr hwnd) {
        var name = new StringBuilder(256);
        return GetClassName(hwnd, name, name.Capacity) > 0 && name.ToString() == "MPC-BE";
    }
}
'@

$rows = foreach ($run in 0..$Runs) {
    $tracePath = Join-Path $OutputDirectory "trace-$run.log"
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    $info.WorkingDirectory = Split-Path $Executable
    if ($Media) { $info.Arguments = '"' + $Media + '" /new' }
    $info.EnvironmentVariables.Remove('MPCBE_STARTUP_TRACE')
    if (!$NoTrace) { $info.EnvironmentVariables['MPCBE_STARTUP_TRACE'] = $tracePath }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $launchQpc = [Diagnostics.Stopwatch]::GetTimestamp()
    $player = [Diagnostics.Process]::Start($info)
    try {
        $visibleMs = $null
        while ($watch.ElapsedMilliseconds -lt 10000 -and !$player.HasExited) {
            $player.Refresh()
            $hwnd = $player.MainWindowHandle
            if ($hwnd -ne [IntPtr]::Zero -and [StartupWindowProbe]::IsWindowVisible($hwnd) -and [StartupWindowProbe]::IsPlayerWindow($hwnd)) {
                $visibleMs = $watch.Elapsed.TotalMilliseconds
                break
            }
            Start-Sleep -Milliseconds 2
        }
        if ($null -eq $visibleMs) { throw 'No visible main window within 10 seconds' }
        $null = $player.WaitForInputIdle(10000)
        $idleMs = $watch.Elapsed.TotalMilliseconds
        Start-Sleep -Milliseconds 1000
        $player.Refresh()
        $cpuMs = $player.TotalProcessorTime.TotalMilliseconds
        $workingSet = $player.WorkingSet64
        $player.Refresh()
        if (!$player.CloseMainWindow()) { throw 'Failed to close test window' }
        if (!$player.WaitForExit(10000)) { throw 'Test process did not exit cleanly' }
        if ($player.ExitCode -ne 0) { throw "Player exited with code $($player.ExitCode)" }
        if ($LegacyTrace) {
            Copy-Item -LiteralPath "$PSScriptRoot/../startup_perf.log" -Destination $tracePath
        }
        $trace = if (!$NoTrace -and (Test-Path -LiteralPath $tracePath)) { Get-Content -LiteralPath $tracePath -Raw } else { '' }
        function Read-Metric([string]$pattern) {
            $match = [regex]::Match($trace, $pattern)
            if ($match.Success) { [double]::Parse($match.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) }
        }
        $firstSample = Read-Metric '\[FIRST SAMPLE RECEIVED:\s+([\d.]+) ms\]'
        # The old baseline mislabeled decoder delivery as presentation.
        if ($LegacyTrace) { $firstSample = Read-Metric '\[FIRST FRAME PRESENTED:\s+([\d.]+) ms\]' }
        $firstPresented = if (!$LegacyTrace) { Read-Metric '\[FIRST FRAME PRESENTED:\s+([\d.]+) ms\]' } else { $null }
        $clock = [regex]::Match($trace, 'QPC origin=(\d+) frequency=(\d+)')
        $constructorDelay = if ($clock.Success) {
            ([double]$clock.Groups[1].Value - $launchQpc) * 1000 / [double]$clock.Groups[2].Value
        } else { $null }
        if ($Media -and !$NoTrace -and $null -eq $firstSample) { throw 'Playback did not deliver a first video sample' }
        if ($run -gt 0) {
            [pscustomobject]@{
                Run = $run
                VisibleWindowMs = [math]::Round($visibleMs, 2)
                InputIdleMs = [math]::Round($idleMs, 2)
                ShowWindowMs = Read-Metric '\[PERF\s+([\d.]+) ms\] After ShowWindow'
                FirstSampleMs = $firstSample
                FirstPresentedMs = $firstPresented
                LaunchToFirstSampleMs = if ($null -ne $constructorDelay -and $null -ne $firstSample) { [math]::Round($constructorDelay + $firstSample, 2) } else { $null }
                LaunchToFirstDrawMs = if ($null -ne $constructorDelay -and $null -ne $firstPresented) { [math]::Round($constructorDelay + $firstPresented, 2) } else { $null }
                CpuMs = $cpuMs
                WorkingSetBytes = $workingSet
                ExitCode = $player.ExitCode
            }
        }
    } finally {
        if (!$player.HasExited) { $player.Kill(); $player.WaitForExit() }
        $player.Dispose()
    }
}
$rows | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'results.csv') -NoTypeInformation
$rows | Format-Table
foreach ($metric in 'VisibleWindowMs', 'InputIdleMs', 'ShowWindowMs', 'FirstSampleMs', 'FirstPresentedMs', 'LaunchToFirstSampleMs', 'LaunchToFirstDrawMs', 'CpuMs', 'WorkingSetBytes') {
    $values = @($rows | ForEach-Object { $_.$metric } | Where-Object { $null -ne $_ } | Sort-Object)
    if ($values.Count) {
        $middle = [int][math]::Floor($values.Count / 2)
        $median = if ($values.Count % 2) { $values[$middle] } else { ($values[$middle - 1] + $values[$middle]) / 2 }
        "$metric median: $([math]::Round($median, 2))"
    }
}
