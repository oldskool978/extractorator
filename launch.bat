@echo off
setlocal EnableDelayedExpansion

cd /d "%~dp0"

if not exist "workspaces\01_payloads" mkdir "workspaces\01_payloads"
if not exist "workspaces\02_extracted" mkdir "workspaces\02_extracted"
if not exist "workspaces\03_recovered" mkdir "workspaces\03_recovered"

echo [*] Initializing Extractorator Framework...
:: Drop the -AutoTarget flag here if you ever want to force a specific version in headless mode.
powershell -NoProfile -ExecutionPolicy Bypass -File ".internals\forge_matrix.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo [!] Fatal: Matrix Forge Execution Failed.
    pause
    exit /b %ERRORLEVEL%
)

call ".internals\.venv\Scripts\activate.bat"

if exist "extractorator.py" (
    python extractorator.py
) else (
    echo [!] Warning: extractorator.py not deployed. Environment active.
    cmd /k
)