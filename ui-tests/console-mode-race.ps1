#Requires -Version 7.0

# Reproduce https://github.com/msys2/msys2-runtime/issues/351 without
# mintty or compiled helpers. Native console handles are essential here.
param(
    [ValidateRange(1, 99)][int]$Count = 99,
    [ValidateRange(1, 10)][int]$ThrottleLimit = 10,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [string]$ExpectedSha256
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RuntimeRoot).ProviderPath
$bash = Join-Path $root 'usr\bin\bash.exe'
$runtime = Join-Path $root 'usr\bin\msys-2.0.dll'
$hash = (Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash
if ($ExpectedSha256 -and $hash -ne $ExpectedSha256) {
    throw "Unexpected runtime DLL hash: $hash"
}
if (Test-Path -LiteralPath $ResultPath) {
    throw "Refusing to overwrite $ResultPath"
}

$env:Path = "$root\usr\bin;$env:SystemRoot\System32;$env:SystemRoot"
$env:MSYSTEM = 'MSYS'
$env:MSYS2_PATH_TYPE = 'strict'
foreach ($name in @('MSYS', 'BASH_ENV', 'ENV')) {
    if (Test-Path -LiteralPath "Env:$name") {
        Remove-Item -LiteralPath "Env:$name"
    }
}
$comspec = Join-Path $env:SystemRoot 'System32\cmd.exe'
$completed = [Collections.Concurrent.ConcurrentBag[int]]::new()
$failures = [Collections.Concurrent.ConcurrentBag[string]]::new()
$started = [DateTime]::UtcNow
$workingDirectory = $PSScriptRoot

Write-Host "RUN_START=$($started.ToString('o'))"
Write-Host "RUN_DLL_SHA256=$hash"
Write-Host 'HELLO FROM MAIN'

1..$Count | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $ErrorActionPreference = 'Stop'
    $id = $_
    $completedJobs = $using:completed
    $failedJobs = $using:failures
    $bashPath = $using:bash
    $shellPath = $using:comspec
    $workingDirectory = $using:workingDirectory
    $child = $null
    try {
        $command = '""{0}" -c "./console-race-leaf.sh {1}""' -f $bashPath, $id
        # Keep the inherited console handles instead of piping child output.
        $child = Start-Process -FilePath $shellPath `
            -ArgumentList @('/d', '/s', '/c', $command) `
            -WorkingDirectory $workingDirectory -NoNewWindow -Wait -PassThru
        if ($child.ExitCode -ne 0) {
            throw "cmd.exe/bash exited $($child.ExitCode)"
        }
        Start-Sleep -Milliseconds (Get-Random -Minimum 0 -Maximum 7906)
        $completedJobs.Add($id)
    }
    catch {
        $failedJobs.Add("Job ${id}: $($_.Exception.Message)")
    }
    finally {
        if ($child) {
            $child.Dispose()
        }
    }
}

$ids = @($completed.ToArray() | Sort-Object)
$errors = @($failures.ToArray())
$allPassed = $errors.Count -eq 0 -and $ids.Count -eq $Count
if ($allPassed) {
    for ($i = 0; $i -lt $Count; $i++) {
        if ($ids[$i] -ne ($i + 1)) {
            $allPassed = $false
            break
        }
    }
}
$duration = [DateTime]::UtcNow - $started
$report = [pscustomobject]@{
    passed = $allPassed
    startedAt = $started.ToString('o')
    elapsedSeconds = [Math]::Round($duration.TotalSeconds, 3)
    requested = $Count
    throttle = $ThrottleLimit
    completed = $ids
    failures = $errors
    dllSha256 = $hash
}
$json = ($report | ConvertTo-Json -Depth 4) + [Environment]::NewLine
[IO.File]::WriteAllText($ResultPath, $json)
if (-not $allPassed) {
    $message = "Reproducer failed: $($errors -join '; ')"
    $message += "; completed $($ids.Count)/$Count jobs"
    throw $message
}
Write-Host 'END OF MAIN'
