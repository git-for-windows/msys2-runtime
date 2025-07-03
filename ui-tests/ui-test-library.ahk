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
   shell := ComObject("WScript.Shell")
   ; Execute a single command via cmd.exe
   exec := shell.Exec(A_ComSpec " /C " command)
   ; Read and return the command's output
   return exec.StdOut.ReadAll()
}

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