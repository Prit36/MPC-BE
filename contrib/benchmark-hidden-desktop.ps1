# Launch MPC-BE repeatedly on a separate, never-shown desktop and collect the
# opt-in startup trace (MPCBE_STARTUP_TRACE). Nothing appears on the user's
# screen. Several executables can be compared; runs are interleaved to reduce
# bias from background load.
#
#   ./contrib/benchmark-hidden-desktop.ps1 -Executable a.exe,b.exe -Media C:/v.mp4 -Runs 15
#
# Times are milliseconds from CreateProcess (launch), so they include loader time.
# An -Executable entry may carry environment variables for that variant:
#   'mpc-be64.exe?MPCBE_EXP_X=1&MPCBE_EXP_Y=1'
param(
    [Parameter(Mandatory = $true)][string[]]$Executable,
    [string]$Media,
    [ValidateRange(1, 200)][int]$Runs = 11,
    [int]$HoldMs = 2500,
    [string]$OutputDirectory = "$PSScriptRoot/../_bin/startup-analysis/hidden",
    [string]$ExtraArgs = '/new',
    # Old builds always wrote a constructor-relative log to a fixed path and
    # labelled decoder delivery as "FIRST FRAME PRESENTED". With this set, that
    # file is collected instead and times are constructor-relative (no launch offset).
    [string]$LegacyLogPath
)

$ErrorActionPreference = 'Stop'
$variantEnv = @($Executable | ForEach-Object { if ($_.Contains('?')) { $_.Substring($_.IndexOf('?') + 1) } else { '' } })
$Executable = @($Executable | ForEach-Object { $p = $_; if ($p.Contains('?')) { $p = $p.Substring(0, $p.IndexOf('?')) }; (Resolve-Path -LiteralPath $p).Path })
if ($Media) { $Media = (Resolve-Path -LiteralPath $Media).Path }
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class HiddenDesktop {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateDesktopW(string name, IntPtr dev, IntPtr mode, int flags, uint access, IntPtr sa);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceCounter(out long v);
    delegate bool EnumProc(IntPtr hwnd, IntPtr lp);
    [DllImport("user32.dll")] static extern bool EnumDesktopWindows(IntPtr desk, EnumProc cb, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);

    static IntPtr desk = IntPtr.Zero;
    public static string Name = "mpcbe-bench-" + Process.GetCurrentProcess().Id;

    public static void Open() {
        if (desk == IntPtr.Zero) {
            desk = CreateDesktopW(Name, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000u /*GENERIC_ALL*/, IntPtr.Zero);
            if (desk == IntPtr.Zero) throw new Exception("CreateDesktop failed " + Marshal.GetLastWin32Error());
        }
    }
    public static void Close() { if (desk != IntPtr.Zero) { CloseDesktop(desk); desk = IntPtr.Zero; } }

    // Returns {launchQpc, exitCode, windowFound}
    public static long[] Run(string exe, string args, string dir, int holdMs) {
        var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si); si.lpDesktop = "WinSta0\\" + Name;
        PROCESS_INFORMATION pi;
        var cmd = new StringBuilder("\"" + exe + "\" " + args);
        long qpc; QueryPerformanceCounter(out qpc);
        if (!CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, dir, ref si, out pi))
            throw new Exception("CreateProcess failed " + Marshal.GetLastWin32Error());
        try {
            WaitForSingleObject(pi.hProcess, (uint)holdMs);
            long found = 0;
            int pid = pi.dwProcessId;
            EnumDesktopWindows(desk, (h, lp) => {
                int wpid; GetWindowThreadProcessId(h, out wpid);
                var sb = new StringBuilder(64); GetClassNameW(h, sb, 64);
                if (wpid == pid && sb.ToString() == "MPC-BE") { PostMessageW(h, 0x0010 /*WM_CLOSE*/, IntPtr.Zero, IntPtr.Zero); found = 1; }
                return true;
            }, IntPtr.Zero);
            uint code = 0xFFFFFFFF;
            if (WaitForSingleObject(pi.hProcess, 15000) != 0) { TerminateProcess(pi.hProcess, 1); WaitForSingleObject(pi.hProcess, 5000); }
            GetExitCodeProcess(pi.hProcess, out code);
            return new long[] { qpc, code, found };
        } finally { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
    }
}
'@

function Read-Metric([string]$trace, [string]$pattern) {
    $m = [regex]::Match($trace, $pattern)
    if ($m.Success) { [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) }
}

[HiddenDesktop]::Open()
$freq = [Diagnostics.Stopwatch]::Frequency
$rows = New-Object System.Collections.Generic.List[object]
try {
    foreach ($run in 0..$Runs) {
        for ($i = 0; $i -lt $Executable.Count; $i++) {
            $exe = $Executable[$i]
            $tracePath = Join-Path $OutputDirectory ("trace-{0}-{1}.log" -f $i, $run)
            Remove-Item -LiteralPath $tracePath -ErrorAction SilentlyContinue
            $env:MPCBE_STARTUP_TRACE = $tracePath
            $setVars = @()
            foreach ($kv in ($variantEnv[$i] -split '&' | Where-Object { $_ })) {
                $name, $value = $kv -split '=', 2
                Set-Item -Path "Env:\$name" -Value $value
                $setVars += $name
            }
            try {
                $arguments = if ($Media) { '"' + $Media + '" ' + $ExtraArgs } else { $ExtraArgs }
                $r = [HiddenDesktop]::Run($exe, $arguments, (Split-Path $exe), $HoldMs)
            } finally {
                Remove-Item Env:\MPCBE_STARTUP_TRACE
                foreach ($name in $setVars) { Remove-Item -Path "Env:\$name" -ErrorAction SilentlyContinue }
            }
            if ($LegacyLogPath -and (Test-Path -LiteralPath $LegacyLogPath)) {
                Copy-Item -LiteralPath $LegacyLogPath -Destination $tracePath -Force
            }
            $trace = if (Test-Path -LiteralPath $tracePath) { Get-Content -LiteralPath $tracePath -Raw } else { '' }
            if ($LegacyLogPath) { $trace = $trace -replace 'FIRST FRAME PRESENTED', 'FIRST SAMPLE RECEIVED' }
            $clock = [regex]::Match($trace, 'QPC origin=(\d+) frequency=(\d+)')
            $pre = if ($clock.Success) { ([double]$clock.Groups[1].Value - $r[0]) * 1000.0 / $freq } elseif ($LegacyLogPath) { 0.0 } else { $null }
            if ($run -eq 0) { continue } # warm-up run
            $row = [ordered]@{ Exe = $i; Run = $run; CtorMs = $null }
            if ($null -ne $pre) { $row.CtorMs = [math]::Round($pre, 2) }
            $patterns = [ordered]@{
                ShowWindowMs    = '\[PERF\s+([\d.]+) ms\] After ShowWindow'
                WarmupEndMs     = '\[PERF\s+([\d.]+) ms\] Graphics driver warmup end'
                RenderFileEndMs = '\[PERF\s+([\d.]+) ms\] m_pGB->RenderFile after'
                FirstSampleMs   = '\[FIRST SAMPLE RECEIVED:\s+([\d.]+) ms\]'
                FirstPresentMs  = '\[FIRST FRAME PRESENTED:\s+([\d.]+) ms\]'
            }
            foreach ($key in $patterns.Keys) {
                $v = Read-Metric $trace $patterns[$key]
                $row[$key] = $null
                if ($null -ne $v -and $null -ne $pre) { $row[$key] = [math]::Round($v + $pre, 2) }
            }
            $row.ExitCode = $r[1]
            $row.Window = $r[2]
            $rows.Add([pscustomobject]$row)
        }
    }
} finally {
    [HiddenDesktop]::Close()
}

$rows | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'results.csv') -NoTypeInformation
for ($i = 0; $i -lt $Executable.Count; $i++) {
    "== [$i] $($Executable[$i]) $($variantEnv[$i])"
    $sel = @($rows | Where-Object { $_.Exe -eq $i })
    foreach ($metric in 'CtorMs', 'ShowWindowMs', 'WarmupEndMs', 'RenderFileEndMs', 'FirstSampleMs', 'FirstPresentMs') {
        $values = @($sel | ForEach-Object { $_.$metric } | Where-Object { $null -ne $_ } | Sort-Object)
        if ($values.Count) {
            $mid = [int][math]::Floor($values.Count / 2)
            $median = if ($values.Count % 2) { $values[$mid] } else { ($values[$mid - 1] + $values[$mid]) / 2 }
            '{0,-16} median {1,8:N1}  min {2,8:N1}  max {3,8:N1}  (n={4})' -f $metric, $median, $values[0], $values[-1], $values.Count
        }
    }
    $bad = @($sel | Where-Object { $_.ExitCode -ne 0 -or $_.Window -ne 1 }).Count
    if ($bad) { "  WARNING: $bad run(s) with nonzero exit code or no window" }
}
