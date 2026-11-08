@echo off
rem orch launcher for cmd.exe / PowerShell on Windows: runs bin\orch with Python 3.8+ (py launcher or python).
rem Through -c rather than as a script argument: the Python install manager's py and python read a script's first
rem line, and bin\orch starts with #!/bin/sh for POSIX shells, which they would warn about on every call.
setlocal
set "ORCH_PY=python"
where py >NUL 2>&1 && set "ORCH_PY=py -3"
%ORCH_PY% -c "import runpy, sys; sys.argv[0] = r'%~dp0orch'; runpy.run_path(sys.argv[0], run_name='__main__')" %*
exit /b %errorlevel%
