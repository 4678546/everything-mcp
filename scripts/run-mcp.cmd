@echo off
rem everything-mcp launcher.
rem Picks the interpreter created by scripts\setup.ps1 (venv, then --target
rem site-packages fallback, then a portable runtime\python), and finally falls
rem back to a python interpreter on PATH.
setlocal
for %%I in ("%~dp0..") do set "ROOT=%%~fI"

if not defined EVERYTHING_ES_PATH set "EVERYTHING_ES_PATH=%ROOT%\bin\es.exe"
if not defined EVERYTHING_EXE set "EVERYTHING_EXE=%ROOT%\runtime\everything\everything.exe"
if not defined EVERYTHING_MCP_INSTANCE set "EVERYTHING_MCP_INSTANCE=everything-mcp"

set "BUNDLE_PYTHONPATH=%ROOT%\mcp"
if exist "%ROOT%\runtime\site-packages" set "BUNDLE_PYTHONPATH=%BUNDLE_PYTHONPATH%;%ROOT%\runtime\site-packages"
set "PYTHONPATH=%BUNDLE_PYTHONPATH%;%PYTHONPATH%"

if exist "%ROOT%\runtime\venv\Scripts\python.exe" (
  "%ROOT%\runtime\venv\Scripts\python.exe" -m everything_mcp %*
  exit /b %ERRORLEVEL%
)
if exist "%ROOT%\runtime\python\python.exe" (
  "%ROOT%\runtime\python\python.exe" -m everything_mcp %*
  exit /b %ERRORLEVEL%
)
python -m everything_mcp %*
exit /b %ERRORLEVEL%
