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

; sleep test
Sleep 1500
; The `:;` is needed to force Git to call this via the shell, otherwise `/usr/bin/` would not resolve.
Send('git -c alias.sleep="{!}:;/usr/bin/sleep" sleep 15{Enter}')
Sleep 500
; interrupt sleep; Ideally we'd call `Send('^C')` but that would too quick on GitHub Actions' runners.
; The idea for this work-around comes from https://www.reddit.com/r/AutoHotkey/comments/aok10s/comment/eg57e81/.
Send '{Ctrl down}{c down}'
Sleep 50
Send '{c up}{Ctrl up}'
Sleep 150
; Wait for the `^C` tell-tale that is the PowerShell prompt to appear
WaitForRegExInWindowsTerminal('>[ `n`r]*$', 'Timed out waiting for interrupt', 'Sleep was interrupted as desired')

; ping test (`cat.exe` should be interrupted, too)
Send('git -c alias.c="{!}cat | /c/windows/system32/ping -t localhost" c{Enter}')
Sleep 500
WaitForRegExInWindowsTerminal('Pinging ', 'Timed out waiting for pinging to start', 'Pinging started')
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
        'AuthorizedKeysFile "' . workTree . '\id_rsa.pub"`n',
        'sshd_config')
    sshdOptions := '-f "' . workTree . '\sshd_config" -D -d -d -d -E sshd.log'

    ; Start SSH server
    Info('Starting SSH server')
    Run(openSSHPath . '\sshd.exe ' . sshdOptions, '', 'Hide', &sshdPID)
    if A_LastError
        ExitWithError 'Error starting SSH server: ' A_LastError
    Info('Started SSH server: ' sshdPID)

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
    Send('git -c core.sshCommand="ssh ' . sshOptions . '" clone ' . cloneOptions . '{Enter}')
    Sleep 50
    Info('Waiting for clone to start')
    WinActivate('ahk_id ' . hwnd)
    WaitForRegExInWindowsTerminal('remote: ', 'Timed out waiting for clone to start', 'Clone started', 5000, 'ahk_id ' . hwnd)
    Info('Trying to interrupt clone')
    Send('^C') ; interrupt clone
    Sleep 150
    WaitForRegExInWindowsTerminal('`nfatal: (.*`r?`n){1,3}PS .*>[ `n`r]*$', 'Timed out waiting for clone to be interrupted', 'clone was interrupted as desired')

    if DirExist(largeGitClonePath)
        ExitWithError('`large-clone` was unexpectedly not deleted on interrupt')

    ; Now verify that the SSH-based clone actually works and does not hang
    Info('Re-starting SSH server')
    Run(openSSHPath . '\sshd.exe ' . sshdOptions, '', 'Hide', &sshdPID)
    if A_LastError
        ExitWithError 'Error starting SSH server: ' A_LastError
    Info('Started SSH server: ' sshdPID)

    Info('Starting clone')
    Send('git -c core.sshCommand="ssh ' . sshOptions . '" clone ' . cloneOptions . '{Enter}')
    Sleep 500
    Info('Waiting for clone to finish')
    WinActivate('ahk_id ' . hwnd)
    WaitForRegExInWindowsTerminal('Receiving objects: .*, done\.`r?`nPS .*>[ `n`r]*$', 'Timed out waiting for clone to finish', 'Clone finished', 15000, 'ahk_id ' . hwnd)

    if not DirExist(largeGitClonePath)
        ExitWithError('`large-clone` did not work?!?')
}

Send('exit{Enter}')
Sleep 50
CleanUpWorkTree()