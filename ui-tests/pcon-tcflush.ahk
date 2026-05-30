#Requires AutoHotkey v2.0
#Include ui-test-library.ahk

; Reproducer for the "tcflush() doesn't actually flush pcon input"
; bug fixed by:
;
;   Cygwin: pty: flush pcon input buffer on tcflush() when pcon is active
;
; Scenario:
;   bash (under mintty)
;     -> cmd.exe                     (activates pseudo console)
;        -> ping -n 30 localhost     (long-running, doesn't read stdin)
;
; While ping runs we type a "leaked-through" marker command into mintty;
; mintty forwards those bytes into the pcon's input buffer, where they
; sit because ping never reads them.  We then press Ctrl-C, which makes
; Cygwin's master::write() observe '\003', synthesise CTRL_C_EVENT
; (killing ping) and call discard_input() to drop pending input.
;
; Before the fix, discard_input() only drained Cygwin-side pipes; the
; bytes still queued inside the pcon's own input buffer survived and were
; handed to cmd.exe at the next prompt, so the marker command ran.  With
; the fix discard_input() also calls FlushConsoleInputBuffer() on the
; duplicated pcon input handle, so the marker is dropped.
;
; The test asserts the marker does NOT appear after Ctrl-C, and types a
; fresh "after flush" marker to prove cmd.exe is still responsive (so a
; missing leaked marker is genuinely due to the flush, not to cmd.exe
; having silently died).

SetWorkTree('git-test-pcon-tcflush')

hwnd := LaunchMintty()
winId := 'ahk_id ' hwnd

; Wait for bash prompt
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

; Launch cmd.exe (activates pseudo console)
WinActivate(winId)
SetKeyDelay 20, 20
SendEvent('{Text}cmd.exe')
SendEvent('{Enter}')

; Wait for cmd.exe prompt
deadline := A_TickCount + 10000
cmdReady := false
while A_TickCount < deadline
{
    capture := CaptureBufferFromMintty(winId)
    if RegExMatch(capture, '[A-Z]:\\[^>\r\n]*>')
    {
        cmdReady := true
        break
    }
    Sleep 500
}
if !cmdReady
{
    Info 'Captured text:'
    Info capture
    ExitWithError 'cmd.exe prompt did not appear'
}
Info 'cmd.exe prompt appeared'

; Start a long-running foreground process that does NOT read stdin.
; 30 pings at the default 1s interval gives us about 30 seconds.
SendEvent('{Text}ping -n 30 localhost')
SendEvent('{Enter}')

deadline := A_TickCount + 10000
pingStarted := false
while A_TickCount < deadline
{
    capture := CaptureBufferFromMintty(winId)
    if InStr(capture, 'Reply from') || InStr(capture, 'Pinging ')
    {
        pingStarted := true
        break
    }
    Sleep 500
}
if !pingStarted
{
    Info 'Captured text:'
    Info capture
    ExitWithError 'ping did not start'
}
Info 'ping is running'

; Let ping run a moment so the prompt is gone and any typed bytes go
; into the pcon's input buffer rather than being interpreted by cmd.exe.
Sleep 1500

leakMarker := 'TYPE_AHEAD_LEAKED_QQQ987'
SendEvent('{Text}echo ' leakMarker)
SendEvent('{Enter}')

; Give the bytes a moment to reach the pcon's input buffer.
Sleep 500

; Ctrl-C: kills ping AND (with the fix) flushes pcon input.
Send '{Ctrl down}c{Ctrl up}'

; Sleep long enough for ping to die and the cmd.exe prompt to come
; back, plus a bit extra so any UN-flushed type-ahead would have been
; processed before our next probe.  We don't poll for the new prompt
; because the old one is still in the buffer; instead the next typed
; marker, by virtue of being echoed, will confirm cmd.exe is alive.
Sleep 4000
Info 'Slept past Ctrl-C; about to send post-flush probe'

; Prove cmd.exe is still responsive: a fresh marker typed AFTER the
; flush must reach cmd.exe and echo.  This rules out a "marker didn't
; appear because cmd.exe is wedged" false pass for the next assertion.
postMarker := 'AFTER_FLUSH_OK_RRR654'
SendEvent('{Text}echo ' postMarker)
SendEvent('{Enter}')

deadline := A_TickCount + 10000
postOk := false
while A_TickCount < deadline
{
    capture := CaptureBufferFromMintty(winId)
    count := 0
    searchPos := 1
    while searchPos := InStr(capture, postMarker, , searchPos)
    {
        count++
        searchPos += StrLen(postMarker)
    }
    if count >= 2
    {
        postOk := true
        break
    }
    Sleep 500
}
if !postOk
{
    Info 'Captured text:'
    Info capture
    ExitWithError 'cmd.exe stopped accepting input after Ctrl-C'
}
Info 'cmd.exe is still responsive after the flush'

; Critical assertion: the leaked-through marker must NOT appear anywhere.
capture := CaptureBufferFromMintty(winId)
if InStr(capture, leakMarker)
{
    Info 'Captured text:'
    Info capture
    ExitWithError 'pcon input was NOT flushed: ' leakMarker ' leaked through Ctrl-C'
}
Info 'pcon input was correctly flushed by Ctrl-C'

; Clean up: exit cmd.exe, then bash.
SendEvent('{Text}exit')
SendEvent('{Enter}')
Sleep 1000
SendEvent('{Text}exit')
SendEvent('{Enter}')
Sleep 1000
ExitApp 0
