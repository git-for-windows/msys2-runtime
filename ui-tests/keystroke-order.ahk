#Requires AutoHotkey v2.0
#Include ui-test-library.ahk

; Reproducer for https://github.com/git-for-windows/git/issues/5632
;
; Keystroke reordering: when a non-MSYS2 process runs in the foreground
; of a PTY, keystrokes typed into bash arrive out of order because the
; MSYS2 runtime's transfer_input() can reorder bytes across pipe buffers.
;
; The test types characters interleaved with backspaces while a non-MSYS
; foreground process (powershell launching MSYS sleep) runs under CPU
; stress. If backspace bytes get reordered relative to the characters
; they should delete, readline produces wrong output.
;
; The test runs in two phases:
;   Phase 1 (pcon enabled):  the default mode, exercises the pseudo
;       console oscillation code paths in master::write().
;   Phase 2 (disable_pcon):  sets MSYS=disable_pcon so that pseudo
;       console is never created, exercising the non-pcon input routing
;       and verifying that typeahead is preserved correctly.

SetWorkTree('git-test-keystroke-order')

testString := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'

hwnd := LaunchMintty()
winId := 'ahk_id ' hwnd

; Wait for bash prompt via HTML export (Ctrl+F5).
deadline := A_TickCount + 60000
while A_TickCount < deadline
{
    capture := CaptureBufferFromMintty(winId)
    if InStr(capture, '$ ')
        break
    Sleep 500
}
if !InStr(capture, '$ ')
    ExitWithError 'Timed out waiting for bash prompt'
Info 'Bash prompt appeared'

stressCmd := 'powershell.exe -File ' StrReplace(A_ScriptDir, '\', '/') '/cpu-stress.ps1'
Info 'Foreground command: ' stressCmd

; === Phase 1: pcon enabled (default) ===
Info '=== Phase 1: pcon enabled ==='
mismatch := RunKeystrokeTest(winId, stressCmd, testString, 5)

if !mismatch
{
    ; === Phase 2: disable_pcon ===
    Info '=== Phase 2: disable_pcon ==='
    WinActivate(winId)
    SetKeyDelay 20, 20
    SendEvent('{Text}export MSYS=disable_pcon')
    SendEvent('{Enter}')
    Sleep 500

    mismatch := RunKeystrokeTest(winId, stressCmd, testString, 5)
}

WinActivate(winId)
SetKeyDelay 20, 20
Send '{Ctrl down}c{Ctrl up}'
Sleep 500
SendEvent('{Text}exit')
SendEvent('{Enter}')
Sleep 1000
ExitApp mismatch ? 1 : 0

; Run the keystroke reordering test for a given number of iterations.
; Returns true if a mismatch was detected, false if all iterations passed.
RunKeystrokeTest(winId, stressCmd, testString, maxIterations) {
    mismatch := false
    chunkSize := 2

    Loop maxIterations
    {
        iteration := A_Index
        Info 'Iteration ' iteration ' of ' maxIterations

        WinActivate(winId)

        ; 1. Launch foreground stress process
        SetKeyDelay 20, 20
        SendEvent('{Text}' stressCmd)
        SendEvent('{Enter}')

        ; 2. Type with backspaces: send chunkSize chars + ",;" + BS*2 at a time.
        SetKeyDelay 1, 1
        Sleep 500
        offset := 1
        while offset <= StrLen(testString)
        {
            chunk := SubStr(testString, offset, chunkSize)
            SendEvent('{Text}' chunk ',;')
            SendEvent('{Backspace}{Backspace}')
            offset += chunkSize
        }

        ; 3. Poll the HTML export for what readline rendered after "$ ".
        ;    The HTML shows the final screen state (backspaces already applied).
        Sleep 2000
        deadline := A_TickCount + 30000
        while A_TickCount < deadline
        {
            text := CaptureBufferFromMintty(winId)

            ; Find the last "$ " and extract the text after it
            lastPrompt := 0
            pos := 1
            while pos := InStr(text, '$ ', , pos)
            {
                lastPrompt := pos
                pos += 2
            }
            if lastPrompt > 0
            {
                after := Trim(SubStr(text, lastPrompt + 2))
                ; Take first "word" (up to whitespace or end)
                spPos := InStr(after, ' ')
                if spPos > 0
                    after := SubStr(after, 1, spPos - 1)

                if after = testString
                {
                    Info 'Iteration ' iteration ': OK'
                    break
                }
                if InStr(after, 'powershell') || InStr(after, 'sleep') || after = ''
                {
                    ; Stress command or bare prompt -- keep waiting
                }
                else if SubStr(testString, 1, StrLen(after)) != after
                {
                    Info 'MISMATCH in iteration ' iteration '!'
                    Info 'Expected: ' testString
                    Info 'Got:      ' after
                    mismatch := true
                    break
                }
            }
            Sleep 500
        }

        if A_TickCount >= deadline
        {
            Info 'TIMEOUT in iteration ' iteration
            mismatch := true
            break
        }
        if mismatch
            break

        ; Clear readline buffer for next iteration
        SetKeyDelay 20, 20
        Send '{Ctrl down}u{Ctrl up}'
        Sleep 300
    }

    if !mismatch
        Info 'All ' maxIterations ' iterations passed'

    return mismatch
}
