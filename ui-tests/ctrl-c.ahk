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

Send('exit{Enter}')
Sleep 50
CleanUpWorkTree()