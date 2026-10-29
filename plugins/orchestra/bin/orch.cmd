@echo off
rem orch launcher for cmd.exe / PowerShell on Windows: runs bin\orch with Python 3.8+ (py launcher or python)
setlocal
set "ORCH_PY=python"
where py >NUL 2>&1 && set "ORCH_PY=py -3"
%ORCH_PY% "%~dp0orch" %*
exit /b %errorlevel%
