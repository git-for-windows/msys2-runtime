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

; Capture the Windows Terminal buffer via the exportBuffer action (Ctrl+Shift+F12).
; Requires a portable WT with settings.json that maps Ctrl+Shift+F12 to exportBuffer
; writing to <script-dir>/wt-buffer-export.txt.
CaptureBufferFromWindowsTerminal(winTitle := '') {
    static exportFile := A_ScriptDir . '\wt-buffer-export.txt'
    if FileExist(exportFile)
        FileDelete exportFile
    if winTitle != ''
        WinActivate winTitle
    Sleep 200
    Send '^+{F12}'
    deadline := A_TickCount + 3000
    while !FileExist(exportFile) && A_TickCount < deadline
        Sleep 50
    if !FileExist(exportFile)
        return ''
    Sleep 100
    return FileRead(exportFile)
}

WaitForRegExInWindowsTerminal(regex, errorMessage, successMessage, timeout := 5000, winTitle := '') {
    timeout := timeout + A_TickCount
    ; Wait for the regex to match in the terminal output
    while true
    {
        capturedText := CaptureBufferFromWindowsTerminal(winTitle)
        if RegExMatch(capturedText, regex)
            break
        Sleep 100
        if A_TickCount > timeout {
            Info('Captured text:`n' . capturedText)
            ExitWithError errorMessage
        }
    }
    Info(successMessage)
}