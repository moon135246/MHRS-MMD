@echo off
setlocal
set "TASK_PYTHONW=%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\pythonw.exe"
if exist "%TASK_PYTHONW%" (
  start "" "%TASK_PYTHONW%" "%~dp0import_gui.pyw"
  exit /b
)
where pythonw.exe >nul 2>nul
if not errorlevel 1 (
  start "" pythonw.exe "%~dp0import_gui.pyw"
  exit /b
)
where pyw.exe >nul 2>nul
if not errorlevel 1 (
  start "" pyw.exe -3 "%~dp0import_gui.pyw"
  exit /b
)
echo Python 3 with tkinter is required. Please run import_gui.pyw using Python.
pause
