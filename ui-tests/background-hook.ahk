#Requires AutoHotkey v2.0

; This script is an integration test for the following scenario:
; A Git hook spawns a background process that outputs some text
; to the console even after Git has exited.

; At some point in time, the Cygwin/MSYS2 runtime left the console
; in a state where it was not possible to navigate the history via
; CursorUp/Down, as reported in https://github.com/microsoft/git/issues/730.
; This was fixed in the Cygwin/MSYS2 runtime, but then regressed again.
; This test is meant to verify that the issue is fixed and remains so.

SetWorkTree() {
    global workTree
    ; First, set the worktree path; This path will be reused
    ; for the `.log` file).
    if A_Args.Length > 0
        workTree := A_Args[1]
    else
    {
        ; Create a unique worktree path in the TEMP directory.
        workTree := EnvGet('TEMP') . '\git-test-background-hook'
        if FileExist(workTree)
        {
            counter := 0
            while FileExist(workTree '-' counter)
                counter++
            workTree := workTree '-' counter
        }
    }
}
SetWorkTree()

Info(text) {
    FileAppend text '`n', workTree '.log'
}

closeWindow := false
childPid := 0
ExitWithError(error) {
    Info 'Error: ' error
    if closeWindow
       WinClose "A"
    else if childPid != 0
        ProcessClose childPid
    ExitApp 1
}

RunWaitOne(command) {
   shell := ComObject("WScript.Shell")
   ; Execute a single command via cmd.exe
   exec := shell.Exec(A_ComSpec " /C " command)
   ; Read and return the command's output
   return exec.StdOut.ReadAll()
}

SetWorkingDir(EnvGet('TEMP'))
Info 'uname: ' RunWaitOne('uname -a')
Info RunWaitOne('git version --build-options')

RunWait('git init "' workTree '"', '', 'Hide')
if A_LastError
    ExitWithError 'Could not initialize Git worktree at: ' workTree

SetWorkingDir(workTree)
if A_LastError
    ExitWithError 'Could not set working directory to: ' workTree

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

CaptureTextFromWindowsTerminal() {
    ControlGetPos &cx, &cy, &cw, &ch, 'Windows.UI.Composition.DesktopWindowContentBridge1', "A"
    titleBarHeight := 54
    scrollBarWidth := 28
    pad := 8

    SavedClipboard := ClipboardAll
    A_Clipboard := ''
    SendMode('Event')
    MouseMove cx + pad, cy + titleBarHeight + pad
    MouseClickDrag 'Left', , , cx + cw - scrollBarWidth, cy + ch - pad, , ''
    MouseClick 'Right'
    ClipWait()
    Result := A_Clipboard
    Clipboard := SavedClipboard
    return Result
}

Info('Setting committer identity')
Send('git config user.name Test{Enter}git config user.email t@e.st{Enter}')

Info('Committing')
Send('git commit --allow-empty -m zOMG{Enter}')
; Wait for the hook to finish printing
While not RegExMatch(CaptureTextFromWindowsTerminal(), '`n49$')
{
    Sleep 100
    if A_Index > 1000
        ExitWithError 'Timed out waiting for commit to finish'
    MouseClick 'WheelDown', , , 20
}
Info('Hook finished')

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
SetWorkingDir(EnvGet('TEMP'))
DirDelete(workTree, true)