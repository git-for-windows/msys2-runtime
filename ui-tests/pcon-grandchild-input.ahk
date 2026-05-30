#Requires AutoHotkey v2.0
#Include ui-test-library.ahk

; Reproducer for the "cmd.exe input dies after a Cygwin grandchild exits"
; bug fixed by:
;
;   Cygwin: pty: keep cmd.exe input alive after a Cygwin grandchild exits
;
; Scenario:
;   bash (under mintty)
;     -> cmd.exe   (activates pseudo console)
;        -> ls.exe (Cygwin grandchild; opens the pty slave then exits)
;
; Before the fix, when ls.exe opens the slave, open_setup() duplicates the
; cygwin master-side native pipe handles into the slave process; closing
; the slave then closes those duplicates, which terminates cmd.exe's input
; pipe.  After ls.exe exits, anything typed at cmd.exe is silently dropped.
;
; The test types into cmd.exe AFTER the Cygwin grandchild has finished and
; asserts that the echoed text appears in the buffer.

SetWorkTree('git-test-pcon-grandchild-input')

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

; Launch cmd.exe to activate pseudo console
WinActivate(winId)
SetKeyDelay 20, 20
SendEvent('{Text}cmd.exe')
SendEvent('{Enter}')

; Wait for cmd.exe prompt: it ends with "<drive>:\...>"
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

; Run cat as a Cygwin grandchild that opens the pty slave and BLOCKS
; on stdin until interrupted.  This matches Yano's bug report: it's
; the Ctrl-C teardown of an interactive cygwin slave under cmd.exe,
; not a quick non-interactive exit, that puts cmd.exe's input pipe
; into the broken state the fix addresses.
SendEvent('{Text}c:\PROGRA~1\Git\usr\bin\cat.exe')
SendEvent('{Enter}')

; Wait for cat to be obviously running by sending a probe line; cat
; echoes back what it reads, so the second occurrence proves cat is
; actively reading from the pty slave.
Sleep 500
catProbe := 'CAT_IS_LISTENING_HEY'
SendEvent('{Text}' catProbe)
SendEvent('{Enter}')

deadline := A_TickCount + 10000
catReady := false
while A_TickCount < deadline
{
    capture := CaptureBufferFromMintty(winId)
    count := 0
    searchPos := 1
    while searchPos := InStr(capture, catProbe, , searchPos)
    {
        count++
        searchPos += StrLen(catProbe)
    }
    if count >= 2
    {
        catReady := true
        break
    }
    Sleep 500
}
if !catReady
{
    Info 'Captured text:'
    Info capture
    ExitWithError 'cat.exe did not echo back probe (not running as grandchild?)'
}
Info 'cat.exe is running and reading stdin'

; Now interrupt cat with Ctrl-C; cat exits and the cygwin slave closes.
; This is the moment that, without the fix, severs cmd.exe's pcon input.
Send '{Ctrl down}c{Ctrl up}'
Sleep 1500
Info 'Sent Ctrl-C to cat'
testMarker := 'POST_GRANDCHILD_OK_XYZ123'
SendEvent('{Text}echo ' testMarker)
SendEvent('{Enter}')

deadline := A_TickCount + 10000
inputOk := false
while A_TickCount < deadline
{
    capture := CaptureBufferFromMintty(winId)
    ; Both the command line and the echo output should contain the marker,
    ; so count occurrences >= 2 to confirm the echo actually ran.
    count := 0
    searchPos := 1
    while searchPos := InStr(capture, testMarker, , searchPos)
    {
        count++
        searchPos += StrLen(testMarker)
    }
    if count >= 2
    {
        Info 'cmd.exe accepted input after Cygwin grandchild exited'
        inputOk := true
        break
    }
    Sleep 500
}
if !inputOk
{
    Info 'Captured text:'
    Info capture
    ExitWithError 'cmd.exe input was lost after Cygwin grandchild exited'
}

; Clean up: exit cmd.exe, then exit bash.
SendEvent('{Text}exit')
SendEvent('{Enter}')
Sleep 1000
SendEvent('{Text}exit')
SendEvent('{Enter}')
Sleep 1000
ExitApp 0
