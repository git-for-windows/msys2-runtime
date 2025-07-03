#Requires AutoHotkey v2.0
#Include ui-test-library.ahk

; This script is an integration test for the following scenario:
; A Git hook spawns a background process that outputs some text
; to the console even after Git has exited.

; At some point in time, the Cygwin/MSYS2 runtime left the console
; in a state where it was not possible to navigate the history via
; CursorUp/Down, as reported in https://github.com/microsoft/git/issues/730.
; This was fixed in the Cygwin/MSYS2 runtime, but then regressed again.
; This test is meant to verify that the issue is fixed and remains so.

SetWorkTree('git-test-background-hook')

if not FileExist('.git/hooks') and not DirCreate('.git/hooks')
    ExitWithError 'Could not create hooks directory: ' workTree

FileAppend("#!/bin/sh`npowershell -command 'for ($i = 0; $i -lt 50; $i++) { echo $i; sleep -milliseconds 10 }' &`n", '.git/hooks/pre-commit')
if A_LastError
    ExitWithError 'Could not create pre-commit hook: ' A_LastError

Run 'wt.exe -d . ' A_ComSpec ' /d', , , &childPid
if A_LastError
    ExitWithError 'Error launching CMD: ' A_LastError
Info 'Launched CMD: ' childPid
if not WinWait(A_ComSpec, , 9)
    ExitWithError 'CMD window did not appear'
Info 'Got window'
WinActivate
CloseWindow := true
WinMove 0, 0
Info 'Moved window to top left (so that the bottom is not cut off)'

Info('Setting committer identity')
Send('git config user.name Test{Enter}git config user.email t@e.st{Enter}')

Info('Committing')
Send('git commit --allow-empty -m zOMG{Enter}')
; Wait for the hook to finish printing
WaitForRegExInWindowsTerminal('`n49$', 'Timed out waiting for commit to finish', 'Hook finished', 100000)

; Verify that CursorUp shows the previous command
Send('{Up}')
Sleep 150
Text := CaptureTextFromWindowsTerminal()
if not RegExMatch(Text, 'git commit --allow-empty -m zOMG *$')
    ExitWithError 'Cursor Up did not work: ' Text
Info('Match!')

Send('^C')
Send('exit{Enter}')
Sleep 50
CleanUpWorkTree()