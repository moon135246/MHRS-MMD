@echo off
setlocal
chcp 65001 >nul
set "TASK_STARTED="
set "TASK_OLD_PYTHON="
set "TASK_CHECK_PYTHON="
if not exist "%~dp0bootstrap.py" (
  echo 缺少 bootstrap.py，请重新解压完整的 MMD转换器_1.0.3 文件夹。
  echo.
  echo bootstrap.py is missing. Extract the complete MMD converter 1.0.3 folder.
  pause
  exit /b 11
)
if exist "%~dp0python\python.exe" call :try_python "%~dp0python\python.exe"
if not defined TASK_STARTED for /f "delims=" %%P in ('where py.exe 2^>nul') do if not defined TASK_STARTED call :try_python "%%P" -3
if not defined TASK_STARTED for /f "delims=" %%P in ('where python.exe 2^>nul ^| findstr /i /v "WindowsApps"') do if not defined TASK_STARTED call :try_python "%%P"
if not defined TASK_STARTED if exist "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" call :try_python "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
if not defined TASK_STARTED if exist "%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe" call :try_python "%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if defined TASK_STARTED exit /b 0
if defined TASK_CHECK_PYTHON (
  "%TASK_CHECK_PYTHON%" %TASK_CHECK_ARGS% "%~dp0bootstrap.py" --explain
) else if defined TASK_OLD_PYTHON (
  echo Python 版本过低：需要 Python 3.9 或更高版本，并包含 Tcl/Tk 和 IDLE。
  echo.
  echo Python is too old. Python 3.9 or newer with Tcl/Tk and IDLE is required.
) else (
  echo 未找到可用的 Python。请安装 Python 3.9 或更高版本，勾选 Tcl/Tk 和 IDLE，以及“添加到 PATH”。
  echo.
  echo Python was not found. Install Python 3.9 or newer with Tcl/Tk and IDLE, and enable Add Python to PATH.
)
pause
exit /b 1

:try_python
"%~1" %~2 -c "import sys; sys.exit(0 if sys.version_info >= (3,9) else 9)" >nul 2>nul
if errorlevel 9 set "TASK_OLD_PYTHON=1"
if errorlevel 1 exit /b
"%~1" %~2 "%~dp0bootstrap.py" --check >nul 2>nul
if errorlevel 1 (
  set "TASK_CHECK_PYTHON=%~1"
  set "TASK_CHECK_ARGS=%~2"
  exit /b
)
"%~1" %~2 "%~dp0bootstrap.py"
if errorlevel 1 exit /b
set "TASK_STARTED=1"
exit /b
