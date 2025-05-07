#Requires AutoHotkey v2.0
#Include ui-test-library.ahk

; Reproducer for Takashi Yano's scenario (3) from
; https://inbox.sourceware.org/cygwin-patches/20260508115113.6d73486274ab131bee493fe2@nifty.ne.jp/
;
;   "Run 'sleep 10' in cmd.exe and enter 'ps\n' while sleeping and
;    press Ctrl-C.  'ps' will be executed after terminating 'sleep'
;    by Ctrl-C."
;
; Yano's discard_input.patch (split here into two commits: "flush pcon
; input buffer on tcflush() when pcon is active" and "keep Ctrl-C and
; NOFLSH signal chars in the pcon input stream") fixes this jointly.
;
; The earlier (Y/N)?-batch-prompt and partial-line-cancel versions of
; this test both passed equally against patched and unpatched runtimes;
; cmd.exe's batch termination prompt and interactive line cancel are
; both driven by CTRL_C_EVENT alone and don't require the stdin '\003'
; byte that commit 4 enables.  Yano's exact scenario 3 is the closest
; we have to a definitive repro of the combined fix.
;
; The test:
;   1. launches cmd.exe under bash (activates pseudo console),
;   2. starts a long-running Cygwin grandchild via the full Git-for-
;      Windows path: c:\PROGRA~1\Git\usr\bin\sleep.exe 10,
;   3. types a fresh command "echo TYPE_AHEAD_<marker><Enter>" while
;      sleep is still running, so the bytes queue up wherever the
;      runtime decides to route them,
;   4. sends Ctrl-C to terminate sleep,
;   5. types "echo FRESH_<marker><Enter>" once cmd.exe is responsive
;      again,
;   6. asserts FRESH_<marker> appears in cmd.exe's output (cmd.exe
;      is alive),
;   7. asserts TYPE_AHEAD_<marker> appears AT MOST ONCE in the
;      captured buffer (i.e. just the typed echo command, NOT also
;      cmd.exe's executed output of it).  If the type-ahead leaked
;      through the runtime's signal handling and got executed by
;      cmd.exe after sleep died, TYPE_AHEAD_<marker> shows up at
;      least twice (typed + executed).

SetWorkTree('git-test-pcon-ctrl-c-cmd')

hwnd := LaunchMintty()
winId := 'ahk_id ' hwnd

; Wait for bash prompt.
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

; Launch cmd.exe.  Pcon activates the moment cmd.exe takes the
; foreground.
WinActivate(winId)
SetKeyDelay 20, 20
SendEvent('{Text}cmd.exe')
SendEvent('{Enter}')

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

typeAheadMarker := 'TYPE_AHEAD_LEAKED_KKK321'
freshMarker := 'FRESH_LINE_OK_MMM456'

; Start the long-running Cygwin grandchild.  10s is enough to type
; the type-ahead and let it settle before the Ctrl-C.
SendEvent('{Text}c:\PROGRA~1\Git\usr\bin\sleep.exe 10')
SendEvent('{Enter}')
Sleep 1500
Info 'Sleep started'

; Type a full command line WHILE sleep is still running.  In Yano's
; scenario these bytes are buffered somewhere that the Ctrl-C-driven
; teardown is supposed to clear; without the fix the buffered command
; gets executed by cmd.exe once sleep is terminated.
SendEvent('{Text}echo ' typeAheadMarker)
SendEvent('{Enter}')
Sleep 500
Info 'Typed type-ahead command while sleep is running'

; Now send Ctrl-C to terminate sleep.
Send '{Ctrl down}c{Ctrl up}'
Sleep 1500
Info 'Sent Ctrl-C to terminate sleep'

; Type a fresh command and execute it to confirm cmd.exe is alive
; and to give any leaked type-ahead time to manifest in the buffer
; before our assertion.
SendEvent('{Text}echo ' freshMarker)
SendEvent('{Enter}')

deadline := A_TickCount + 10000
freshOk := false
while A_TickCount < deadline
{
    capture := CaptureBufferFromMintty(winId)
    count := 0
    searchPos := 1
    while searchPos := InStr(capture, freshMarker, , searchPos)
    {
        count++
        searchPos += StrLen(freshMarker)
    }
    if count >= 2
    {
        freshOk := true
        break
    }
    Sleep 500
}
if !freshOk
{
    Info 'Captured text:'
    Info capture
    ExitWithError 'cmd.exe did not execute the fresh command (input wedged?)'
}
Info 'cmd.exe executed the fresh command after Ctrl-C'

; Critical assertion: the type-ahead command must NOT have been
; executed.  If it leaked through, cmd.exe ran "echo TYPE_AHEAD_..."
; and the marker appears at least twice (typed line + echoed output).
capture := CaptureBufferFromMintty(winId)
count := 0
searchPos := 1
while searchPos := InStr(capture, typeAheadMarker, , searchPos)
{
    count++
    searchPos += StrLen(typeAheadMarker)
}
if count > 1
{
    Info 'Captured text:'
    Info capture
    ExitWithError 'Type-ahead was executed by cmd.exe after Ctrl-C: ' typeAheadMarker ' appeared ' count ' times'
}
Info 'Type-ahead was successfully discarded by Ctrl-C'

; Cleanup
SendEvent('{Text}exit')
SendEvent('{Enter}')
Sleep 1000
SendEvent('{Text}exit')
SendEvent('{Enter}')
Sleep 1000
ExitApp 0
