' Runs the command given as arguments with no visible window and returns
' its exit code. Task Scheduler flashes a console when it starts a console
' app directly under an interactive logon; wscript is a GUI-subsystem app,
' so launching through it keeps scheduled runs invisible.
If WScript.Arguments.Count < 1 Then WScript.Quit 1
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
    arg = WScript.Arguments(i)
    If InStr(arg, " ") > 0 Then arg = """" & arg & """"
    cmd = cmd & arg & " "
Next
Set shell = CreateObject("WScript.Shell")
WScript.Quit shell.Run(Trim(cmd), 0, True)
