' Runs its arguments with no visible window and forwards the exit code: Task
' Scheduler flashes a console for console apps, wscript is GUI-subsystem.

Function QuoteArg(arg)
    Dim i, ch, slashes, out
    If Len(arg) > 0 And InStr(arg, " ") = 0 And InStr(arg, vbTab) = 0 And InStr(arg, """") = 0 Then
        QuoteArg = arg
        Exit Function
    End If
    out = """"
    slashes = 0
    For i = 1 To Len(arg)
        ch = Mid(arg, i, 1)
        If ch = "\" Then
            slashes = slashes + 1
        ElseIf ch = """" Then
            ' Backslashes double only before a quote; a plain Replace would break paths.
            out = out & String(slashes * 2 + 1, "\") & """"
            slashes = 0
        Else
            out = out & String(slashes, "\") & ch
            slashes = 0
        End If
    Next
    ' Trailing backslashes would otherwise escape the closing quote.
    QuoteArg = out & String(slashes * 2, "\") & """"
End Function

If WScript.Arguments.Count < 1 Then WScript.Quit 1
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
    If i > 0 Then cmd = cmd & " "
    cmd = cmd & QuoteArg(WScript.Arguments(i))
Next
Set shell = CreateObject("WScript.Shell")
WScript.Quit shell.Run(cmd, 0, True)
