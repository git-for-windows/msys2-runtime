$sleepExe = & cygpath.exe -aw /usr/bin/sleep.exe
$procs = 1..[Environment]::ProcessorCount | ForEach-Object {
    Start-Process -NoNewWindow -PassThru cmd.exe -ArgumentList '/c','for /L %i in (1,1,999999) do @echo . >NUL'
}
& $sleepExe 1
$procs | Stop-Process -Force -ErrorAction SilentlyContinue
