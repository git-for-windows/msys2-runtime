#Requires AutoHotkey v2.0
#Include ui-test-library.ahk

SetWorkTree('git-test-ctrl-c')

powerShellPath := EnvGet('SystemRoot') . '\System32\WindowsPowerShell\v1.0\powershell.exe'
Run 'wt.exe -d . "' powerShellPath '"', , , &childPid
if A_LastError
    ExitWithError 'Error launching PowerShell: ' A_LastError
Info 'Launched PowerShell: ' childPid
; Sadly, `WinWait('ahk_pid ' childPid)` does not work because the Windows Terminal window seems
; to be owned by the `wt.exe` process that launched.
;
; Probably should use the trick mentioned in
; https://www.autohotkey.com/boards/viewtopic.php?p=580081&sid=a40d0ce73efff728ffa6b4573dff07b9#p580081
; where the `before` variable is assigned `WinGetList(winTitle).Length` before the `Run` command,
; and a `Loop` is used to wait until [`WinGetList()`](https://www.autohotkey.com/docs/v2/lib/WinGetList.htm)
; returns a different length, in which case the first array element is the new window.
;
; Also: This is crying out loud to be refactored into a function and then also used in `background-hook.ahk`!
hwnd := WinWait(powerShellPath, , 9)
if not hwnd
    ExitWithError 'PowerShell window did not appear'
Info 'Got window'
WinActivate
CloseWindow := true
WinMove 0, 0
Info 'Moved window to top left (so that the bottom is not cut off)'

WaitForRegExInWindowsTerminal('PS [A-Z]:.*>[ `n`r]*$', 'Timed out waiting for PowerShell to start', 'PowerShell prompt appeared', 30000)

; sleep test
Sleep 1500
; The `:;` is needed to force Git to call this via the shell, otherwise `/usr/bin/` would not resolve.
Send('git -c alias.sleep="{!}:;echo __SLEEP_STARTED__;' .
    '/usr/bin/sleep" sleep 15{Enter}')
WaitForRegExInWindowsTerminal(
    '(^|`n)__SLEEP_STARTED__`r?`n',
    'Timed out waiting for sleep to start', 'Sleep started',
    10000, 'ahk_id ' . hwnd)
; interrupt sleep; Ideally we'd call `Send('^C')` but that would too quick on GitHub Actions' runners.
; The idea for this work-around comes from https://www.reddit.com/r/AutoHotkey/comments/aok10s/comment/eg57e81/.
WinActivate('ahk_id ' . hwnd)
Send '{Ctrl down}{c down}'
Sleep 50
Send '{c up}{Ctrl up}'
Sleep 150
; Wait for the `^C` tell-tale that is the PowerShell prompt to appear
WaitForRegExInWindowsTerminal('>[ `n`r]*$', 'Timed out waiting for interrupt', 'Sleep was interrupted as desired')

; ping test (`cat.exe` should be interrupted, too)
Send('git -c alias.c="{!}cat | /c/windows/system32/ping -t localhost" c{Enter}')
Sleep 500
WaitForRegExInWindowsTerminal('Pinging ', 'Timed out waiting for pinging to start', 'Pinging started', 10000)
Send('^C') ; interrupt ping and cat
Sleep 150
; Wait for the `^C` tell-tale to appear
WaitForRegExInWindowsTerminal('Control-C', 'Timed out waiting for pinging to be interrupted', 'Pinging was interrupted as desired')
; Wait for the `^C` tell-tale that is the PowerShell prompt to appear
WaitForRegExInWindowsTerminal('>[ `n`r]*$', 'Timed out waiting for `cat.exe` to be interrupted', '`cat.exe` was interrupted as desired')

; Clone via SSH test; Requires an OpenSSH for Windows `sshd.exe` whose directory needs to be specified via
; the environment variable `OPENSSH_FOR_WINDOWS_DIRECTORY`. The clone will still be performed via Git's
; included `ssh.exe`, to exercise the MSYS2 runtime (which these UI tests are all about).

openSSHPath := EnvGet('OPENSSH_FOR_WINDOWS_DIRECTORY')
if (openSSHPath != '' and FileExist(openSSHPath . '\sshd.exe')) {
    Info('Generate 26M of data')
    largeFilesDirectory := EnvGet('LARGE_FILES_DIRECTORY')
    if largeFilesDirectory == ''
        largeFilesDirectory := workTree . '-large-files'
    largeGitRepoPath := largeFilesDirectory . '\large.git'
    largeGitClonePath := largeFilesDirectory . '\large-clone'
    RunWait('git init --bare -b main "' . largeGitRepoPath . '"', '', 'Hide')
    RunWait('git --git-dir="' . largeGitRepoPath . '" -c alias.c="!(' .
        'printf \"reset refs/heads/main\\n\"; ' .
        'seq 100000 | ' .
        'sed \"s|.*|blob\\nmark :&\\ndata <<E\\n&\\nE\\ncommit refs/heads/main\\n' .
            'committer a <a@b.c> 1234& +0000\\ndata <<E\\n&\\nE\\nM 100644 :& file|\"' .
    ') | git fast-import" c', '', 'Hide')
    Info('Done generating 26M of data')

    ; When running as administrator, `ssh-keygen` will generate files with
    ; too-open permissions by default; Let's adjust them.
    AdjustPermissions(path) {
        if not A_IsAdmin
            return
        RunWait('icacls ' . path . ' /inheritance:r')
        if A_LastError
            ExitWithError 'Could not adjust ACL inheritance of ' . path . ': ' A_LastError
        RunWait('icacls ' . path . ' /remove "NT AUTHORITY\Authenticated Users"')
        if A_LastError
            ExitWithError 'Could not remove authenticated user permission from ' . path . ': ' A_LastError
        RunWait('icacls ' . path . ' /grant "Administrators:(R)"')
        if A_LastError
            ExitWithError 'Could not add admin read permission from ' . path . ': ' A_LastError
    }

    WaitForSshd(expectedPID) {
        deadline := A_TickCount + 60000
        while true {
            if FileExist('sshd.pid') {
                content := ''
                try
                    content := Trim(FileRead('sshd.pid'), ' `t`r`n')
                if content == expectedPID && ProcessExist(expectedPID) {
                    Info('sshd is accepting connections (PID ' . content . ')')
                    return
                }
            }
            if A_TickCount > deadline
                ExitWithError 'sshd did not write its PidFile within 60 seconds'
            Sleep 500
        }
    }

    StartSshd(openSSHPath, sshdOptions, sshdPIDs) {
        try FileDelete('sshd.pid')
        Run(openSSHPath . '\sshd.exe ' . sshdOptions, '', 'Hide', &pid)
        if A_LastError
            ExitWithError 'Error starting SSH server: ' A_LastError
        sshdPIDs.Push(pid)
        Info('Started SSH server: ' . pid)
        WaitForSshd(pid)
        return pid
    }

    StopSshd(pid, openSSHPath, sshdPIDs) {
        if !pid
            return true
        proc := FindProcess(pid)
        executablePath := ''
        if proc
            try executablePath := proc.ExecutablePath
        if executablePath == openSSHPath . '\sshd.exe' {
            Info('Stopping sshd.exe (PID ' . pid . ')')
            try ProcessClose(pid)
            try ProcessWaitClose(pid, 5)
        }
        if !ProcessExist(pid) {
            loop sshdPIDs.Length {
                if sshdPIDs[A_Index] == pid {
                    sshdPIDs.RemoveAt(A_Index)
                    break
                }
            }
        }
        return !ProcessExist(pid)
    }

    CleanUpSshdProcesses(sshdPIDs, openSSHPath, *) {
        for pid in sshdPIDs.Clone()
            StopSshd(pid, openSSHPath, sshdPIDs)
    }

    FindProcess(pid) {
        query := 'SELECT ProcessId, ParentProcessId, Name, CommandLine, ' .
            'ExecutablePath FROM Win32_Process WHERE ProcessId = ' . pid
        for proc in ComObjGet('winmgmts:').ExecQuery(query)
            return proc
        return 0
    }

    ProcessMatches(pid, name, marker) {
        proc := FindProcess(pid)
        if !proc || proc.Name != name
            return false
        commandLine := ''
        try commandLine := proc.CommandLine
        return InStr(commandLine, marker)
    }

    ; Count the regular files (not directories) below `dir`, recursing into
    ; subdirectories and hidden entries such as a `.git` folder.
    CountFilesRecursively(dir) {
        count := 0
        Loop Files, dir . '\*', 'FR'
            count++
        return count
    }

    WatchSshStarts() {
        query := 'SELECT * FROM Win32_ProcessStartTrace ' .
            'WHERE ProcessName = "ssh.exe"'
        return ComObjGet('winmgmts:').ExecNotificationQuery(query)
    }

    WaitForCloneSsh(events, keyPath) {
        deadline := A_TickCount + 15000
        while A_TickCount < deadline {
            try event := events.NextEvent(deadline - A_TickCount)
            catch
                break
            ssh := FindProcess(event.ProcessID)
            if !ssh
                continue
            sshCommandLine := ''
            try sshCommandLine := ssh.CommandLine
            if InStr(sshCommandLine, keyPath)
                return ssh.ProcessId
        }
        return 0
    }

    ; Set up SSH server
    Info('Generating host key')
    RunWait('git -c alias.c="!ssh-keygen -b 4096 -f ssh_host_rsa_key -N \"\"" c', '', 'Hide')
    if A_LastError
        ExitWithError 'Error generating host key: ' A_LastError
    AdjustPermissions('ssh_host_rsa_key')
    AdjustPermissions('ssh_host_rsa_key.pub')
    Info('Generating client key')
    RunWait('git -c alias.c="!ssh-keygen -f id_rsa -N \"\"" c', '', 'Hide')
    if A_LastError
        ExitWithError 'Error generating client key: ' A_LastError
    AdjustPermissions('id_rsa')
    AdjustPermissions('id_rsa.pub')
    FileAppend('Port 2322`n' .
        'HostKey "' . workTree . '\ssh_host_rsa_key"`n' .
        'AuthorizedKeysFile "' . workTree . '\id_rsa.pub"`n' .
        'LogLevel VERBOSE`n' .
        'PidFile "' . workTree . '\sshd.pid"`n',
        'sshd_config')
    sshdOptions := '-f "' . workTree . '\sshd_config" -D -E "' . workTree . '\sshd.log"'
    sshdPIDs := []
    sshdCleanup := CleanUpSshdProcesses.Bind(
        sshdPIDs, openSSHPath)
    OnExit(sshdCleanup)

    ; Start SSH server
    Info('Starting SSH server')
    sshdPID := StartSshd(openSSHPath, sshdOptions, sshdPIDs)

    Info('Starting clone')
    workTreeMSYS := RunWaitOne('git -c alias.cygpath="!cygpath" cygpath -u "' . workTree . '"')
    sshOptions := '-i ' . workTreeMSYS . '/id_rsa -p 2322 -T ' .
        '-o UserKnownHostsFile=' . workTreeMSYS . '/known_hosts ' .
        '-o StrictHostKeyChecking=accept-new '
    ; The `--upload-pack` option is needed because OpenSSH for Windows' default shell
    ; is `cmd.exe`, which does not handle single-quoted strings as Git expects.
    ; An heavy-handed alternative would be to require PowerShell to be configured via
    ; HKLM:\SOFTWARE\OpenSSH's DefaultShell property, for full details see
    ; https://github.com/PowerShell/Win32-OpenSSH/wiki/Setting-up-a-Git-server-on-Windows-using-Git-for-Windows-and-Win32_OpenSSH
    ;
    ; The username is needed because by default, on domain-joined machines MSYS2's
    ; `ssh.exe` prefixes the username with the domain name.
    cloneOptions := '--upload-pack="powershell git upload-pack" "' .
        EnvGet('USERNAME') . '@localhost:' . largeGitRepoPath . '" "' . largeGitClonePath . '"'
    sshStartEvents := WatchSshStarts()
    WinActivate('ahk_id ' . hwnd)
    Send('git -c core.sshCommand="ssh ' . sshOptions . '" clone ' .
        cloneOptions . '{Enter}')
    cloneSshPID := WaitForCloneSsh(
        sshStartEvents, workTreeMSYS . '/id_rsa')
    if !cloneSshPID
        ExitWithError 'Timed out waiting for clone ssh.exe'
    Info('Clone ssh.exe started: ' . cloneSshPID)
    Info('Trying to interrupt clone')
    if !ProcessMatches(cloneSshPID, 'ssh.exe', workTreeMSYS . '/id_rsa')
        ExitWithError 'Clone completed before Ctrl+C could be sent'
    ; Interrupt the clone. A bare `Send('^C')` is too quick to be delivered
    ; reliably on GitHub Actions' runners (see the sleep interrupt above), and
    ; even the deliberate key-down/up sequence is occasionally lost to a
    ; focus/scheduling race. A missed interrupt lets the clone run to completion
    ; (its ssh.exe only exits once the ~26M transfer finishes), so keep
    ; re-issuing the Ctrl+C, re-focusing the window each time, until ssh.exe
    ; actually exits.
    deadline := A_TickCount + 15000
    while ProcessMatches(
        cloneSshPID, 'ssh.exe', workTreeMSYS . '/id_rsa') &&
        A_TickCount < deadline {
        WinActivate('ahk_id ' . hwnd)
        Send '{Ctrl down}{c down}'
        Sleep 50
        Send '{c up}{Ctrl up}'
        checkDeadline := A_TickCount + 600
        while ProcessExist(cloneSshPID) && A_TickCount < checkDeadline
            Sleep 20
    }
    if ProcessMatches(cloneSshPID, 'ssh.exe', workTreeMSYS . '/id_rsa')
        ExitWithError 'Clone ssh.exe did not exit after Ctrl+C'
    Info('clone was interrupted as desired')

    ; Interrupting `git clone` makes it run its `remove_junk` cleanup, which
    ; unlinks every file of the partial clone. On Windows that cleanup races
    ; with the still-terminating child processes: their delete-pending file
    ; handles (and CWDs) keep the now file-less directories busy, so git's
    ; `rmdir` of the empty scaffolding fails and it gives up, permanently
    ; leaving behind an empty `large-clone\.git\{objects,refs}` skeleton. That
    ; benign leftover is not a completed clone, so it must not fail the test:
    ; the interrupt is already proven by the clone's `ssh.exe` having exited
    ; (above) and by the clone content being gone. Wait for every file to
    ; disappear (tolerating empty directories), fail only if actual clone
    ; content survives (i.e. the clone was not aborted), then remove any empty
    ; scaffolding ourselves so the verification clone below starts clean.
    deadline := A_TickCount + 5000
    while DirExist(largeGitClonePath) &&
        CountFilesRecursively(largeGitClonePath) > 0 &&
        A_TickCount < deadline
        Sleep 10
    if DirExist(largeGitClonePath) {
        remainingFiles := CountFilesRecursively(largeGitClonePath)
        if remainingFiles > 0
            ExitWithError('`large-clone` still contained ' . remainingFiles .
                ' file(s) after interrupt (clone was not aborted)')
        ; Only empty scaffolding remains; drop it so the verification clone
        ; below can create the target afresh. The directories may stay briefly
        ; busy while the interrupted clone's children finish exiting, so retry.
        deadline := A_TickCount + 5000
        while DirExist(largeGitClonePath) && A_TickCount < deadline {
            try DirDelete(largeGitClonePath, true)
            if !DirExist(largeGitClonePath)
                break
            Sleep 50
        }
    }

    ; Now verify that the SSH-based clone actually works and does not hang
    Info('Re-starting SSH server')
    if !StopSshd(sshdPID, openSSHPath, sshdPIDs)
        ExitWithError 'Could not stop SSH server before restart'
    sshdPID := StartSshd(openSSHPath, sshdOptions, sshdPIDs)

    Info('Starting clone')
    retries := 5
    cloneResultMarker := 'GIT_CLONE_EXIT_CODE='
    Loop retries {
        WinActivate('ahk_id ' . hwnd)
        Send('git -c core.sshCommand="ssh ' . sshOptions . '" clone ' .
            cloneOptions . '; Write-Output "' . cloneResultMarker .
            '$LASTEXITCODE"{Enter}')
        Sleep 500
        Info('Waiting for clone to finish (attempt ' . A_Index . '/' . retries . ')')
        WinActivate('ahk_id ' . hwnd)
        matchObj := WaitForRegExInWindowsTerminal(
            cloneResultMarker . '([0-9]+)',
            'Timed out waiting for clone to finish',
            'Clone command completed', 15000, 'ahk_id ' . hwnd)

        if matchObj[1] == '0'
            break
        if A_Index == retries
            ExitWithError('Clone failed after ' . retries .
                ' attempts (exit code ' . matchObj[1] . ')')
        Info('Clone failed with exit code ' . matchObj[1] .
            ', restarting SSH server and retrying...')
        if DirExist(largeGitClonePath)
            DirDelete(largeGitClonePath, true)
        if !StopSshd(sshdPID, openSSHPath, sshdPIDs)
            ExitWithError 'Could not stop SSH server before retry'
        sshdPID := StartSshd(openSSHPath, sshdOptions, sshdPIDs)
        Info('Restarted SSH server: ' . sshdPID)
    }

    if not DirExist(largeGitClonePath)
        ExitWithError('`large-clone` did not work?!?')

    CleanUpSshdProcesses(sshdPIDs, openSSHPath)
    if sshdPIDs.Length
        ExitWithError 'Could not stop all SSH servers'
    OnExit(sshdCleanup, 0)
}

; Close the PowerShell window. As with the Ctrl+C interrupts above, a single
; `Send('exit{Enter}')` is occasionally lost to a focus/scheduling race on
; GitHub Actions' runners, which would leave the Windows Terminal window (and
; its OpenConsole/PowerShell processes) behind. Re-issue the exit, re-focusing
; the window each time, until it actually closes; the leading `{Enter}` flushes
; any partial command a half-delivered attempt might have left on the prompt.
deadline := A_TickCount + 20000
while WinExist('ahk_id ' . hwnd) && A_TickCount < deadline {
    try WinActivate('ahk_id ' . hwnd)
    if WinExist('ahk_id ' . hwnd)
        Send('{Enter}exit{Enter}')
    WinWaitClose('ahk_id ' . hwnd, , 3)
}
if WinExist('ahk_id ' . hwnd)
    ExitWithError 'PowerShell window did not close'
Info 'PowerShell window closed'
CleanUpWorkTree()