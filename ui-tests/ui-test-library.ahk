; Reusable library functions for the UI tests.

SetWorkTree(defaultName) {
    global workTree
    ; First, set the worktree path; This path will be reused
    ; for the `.log` file).
    if A_Args.Length > 0
        workTree := A_Args[1]
    else
    {
        ; Create a unique worktree path in the TEMP directory.
        workTree := EnvGet('TEMP') . '\' . defaultName
        if FileExist(workTree)
        {
            counter := 0
            while FileExist(workTree '-' counter)
                counter++
            workTree := workTree '-' counter
        }
    }

    SetWorkingDir(EnvGet('TEMP'))
    Info 'uname: ' RunWaitOne('git -c alias.uname="!uname" uname -a')
    Info RunWaitOne('git version --build-options')

    RunWait('git init "' workTree '"', '', 'Hide')
    if A_LastError
        ExitWithError 'Could not initialize Git worktree at: ' workTree

    SetWorkingDir(workTree)
    if A_LastError
        ExitWithError 'Could not set working directory to: ' workTree
}

CleanUpWorkTree() {
    global workTree
    SetWorkingDir(EnvGet('TEMP'))
    Info 'Cleaning up worktree: ' workTree
    DirDelete(workTree, true)
}

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
    SavedClipboard := ClipboardAll
    shell := ComObject("WScript.Shell")
    ; Execute a single command via cmd.exe
    exec := shell.Run(A_ComSpec " /C " command " | clip", 0, true)
    if exec != 0
        ExitWithError 'Error executing command: ' command
    ; Read and return the command's output, trimming trailing newlines.
    Result := RegExReplace(A_Clipboard, '`r?`n$', '')
    Clipboard := SavedClipboard
    return Result
}

; This function is quite the hack. It assumes that the Windows Terminal is the active window,
; then drags the mouse diagonally across the window to select all text and then copies it.
;
; This is fragile! If any other window becomes active, or if the mouse is moved,
; the function will not work as intended.
;
; An alternative would be to use `ControlSend`, e.g.
; `ControlSend '+^a', 'Windows.UI.Input.InputSite.WindowClass1', 'ahk_id ' . hwnd
; This _kinda_ works, the text is selected (all text, in fact), but the PowerShell itself
; _also_ processes the keyboard events and therefore they leave ugly and unintended
; `^Ac` characters in the prompt. So that alternative is not really usable.
CaptureTextFromWindowsTerminal(winTitle := '') {
    if winTitle != ''
        WinActivate winTitle
    ControlGetPos &cx, &cy, &cw, &ch, 'Windows.UI.Composition.DesktopWindowContentBridge1', "A"
    titleBarHeight := 54
    scrollBarWidth := 28
    pad := 8

    SavedClipboard := ClipboardAll
    A_Clipboard := ''
    SendMode('Event')
    if winTitle != ''
        WinActivate winTitle
    MouseMove cx + pad, cy + titleBarHeight + pad
    if winTitle != ''
        WinActivate winTitle
    MouseClickDrag 'Left', , , cx + cw - scrollBarWidth, cy + ch - pad, , ''
    if winTitle != ''
        WinActivate winTitle
    MouseClick 'Right'
    ClipWait()
    Result := A_Clipboard
    Clipboard := SavedClipboard
    return Result
}

WaitForRegExInWindowsTerminal(regex, errorMessage, successMessage, timeout := 5000, winTitle := '') {
    timeout := timeout + A_TickCount
    ; Wait for the regex to match in the terminal output
    while true
    {
        capturedText := CaptureTextFromWindowsTerminal(winTitle)
        if RegExMatch(capturedText, regex)
            break
        Sleep 100
        if A_TickCount > timeout {
            Info('Captured text:`n' . capturedText)
            ExitWithError errorMessage
        }
        if winTitle != ''
            WinActivate winTitle
        MouseClick 'WheelDown', , , 20
    }
    Info(successMessage)
}