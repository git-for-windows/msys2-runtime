#Requires -Version 7.0

param(
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'
# CTRL_C_EVENT reaches every process attached to this console.
if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    throw 'Run this test in a dedicated native Windows console'
}
$root = (Resolve-Path -LiteralPath $RuntimeRoot).ProviderPath
$env:Path = "$root\usr\bin;$env:SystemRoot\System32;$env:SystemRoot"
$env:MSYSTEM = 'MSYS'
if (Test-Path Env:MSYS) {
    Remove-Item Env:MSYS
}
if (Test-Path -LiteralPath $ResultPath) {
    throw "Refusing to overwrite $ResultPath"
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleSignal {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GenerateConsoleCtrlEvent(uint signal, uint group);
}
'@

$bash = Join-Path $root 'usr\bin\bash.exe'
$child = Start-Process -FilePath $bash `
    -ArgumentList @('--noprofile', '--norc', './console-ctrl-c-pipeline.sh') `
    -WorkingDirectory $PSScriptRoot -NoNewWindow -PassThru
$handler = [IntPtr]::Zero
try {
    Start-Sleep -Seconds 3
    if ($child.HasExited) {
        throw "Pipeline exited before Ctrl+C (exit $($child.ExitCode))"
    }
    if (-not [ConsoleSignal]::SetConsoleCtrlHandler($handler, $true)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Cannot ignore Ctrl+C in test driver: $errorCode"
    }
    try {
        if (-not [ConsoleSignal]::GenerateConsoleCtrlEvent(0, 0)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Cannot send Ctrl+C: $errorCode"
        }
        if (-not $child.WaitForExit(5000)) {
            throw 'Cygwin/native pipeline did not stop after Ctrl+C'
        }
    }
    finally {
        if (-not [ConsoleSignal]::SetConsoleCtrlHandler($handler, $false)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Cannot restore Ctrl+C handling: $errorCode"
        }
    }
    if ($child.ExitCode -eq 0) {
        throw 'Pipeline completed normally instead of being interrupted'
    }
    [IO.File]::WriteAllText($ResultPath, "Interrupted`n")
}
catch {
    [IO.File]::WriteAllText($ResultPath, "$($_.Exception.Message)`n")
    throw
}
finally {
    $child.Dispose()
}
