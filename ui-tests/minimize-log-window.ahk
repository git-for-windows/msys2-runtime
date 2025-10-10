#Requires AutoHotkey v2.0
#Include ui-test-library.ahk

for hwnd in WinGetList()
{
    title := WinGetTitle(hwnd)
    if title != ""
    {
        FileAppend 'Got window ' . hwnd . '`n', '*'
	try {
            exe := WinGetProcessName(hwnd)
        } catch as e {
            FileAppend 'Could not get executable for hwnd ' . hwnd . ': ' . e.Message . '`n', '*'
            exe := "<unknown>"
        }
	title := WinGetTitle(hwnd)
        FileAppend 'Got window ' . hwnd . ' ah_exe ' . exe . ' title ' . title . '`n', '*'

        WinMinimize(hwnd)
    }
}
