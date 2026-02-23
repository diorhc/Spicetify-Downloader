@echo off
setlocal enabledelayedexpansion
title Spicetify Downloader — Installer

echo.
echo  ==========================================
echo    Spicetify Downloader — Easy Installer
echo  ==========================================
echo.

:: ── 1. Check Python ──────────────────────────────────────────────────────────
echo  [1/5] Checking Python...
python --version >nul 2>&1
if errorlevel 1 (
    echo.
    echo  [!] Python not found!
    echo      Please install Python 3.8 or newer:
    echo      https://www.python.org/downloads/
    echo.
    echo      Make sure to check "Add Python to PATH" during install.
    echo.
    pause
    exit /b 1
)
for /f "tokens=2 delims= " %%v in ('python --version 2^>^&1') do set PYVER=%%v
echo      Python %PYVER% found. OK

:: ── 2. Install SpotDL ────────────────────────────────────────────────────────
echo.
echo  [2/5] Installing SpotDL (music downloader)...
python -m pip install --quiet --upgrade spotdl
if errorlevel 1 (
    echo  [!] Failed to install SpotDL. Check your internet connection.
    pause
    exit /b 1
)
echo      SpotDL installed. OK

:: ── 3. Copy files ────────────────────────────────────────────────────────────
echo.
echo  [3/5] Copying files...
set "SPICETIFY_PATH=%appdata%\spicetify"
set "CUSTOM_APP_PATH=%SPICETIFY_PATH%\CustomApps\spicetify-downloader"

if not exist "%CUSTOM_APP_PATH%" mkdir "%CUSTOM_APP_PATH%"

copy /Y "custom-app\manifest.json" "%CUSTOM_APP_PATH%\" >nul
copy /Y "custom-app\app.js"        "%CUSTOM_APP_PATH%\" >nul
copy /Y "custom-app\settings.js"   "%CUSTOM_APP_PATH%\" >nul
copy /Y "custom-app\downloader.js" "%CUSTOM_APP_PATH%\" >nul
copy /Y "backend\server.py"        "%SPICETIFY_PATH%\"  >nul
copy /Y "backend\requirements.txt" "%SPICETIFY_PATH%\"  >nul
echo      Done. OK

:: ── 4. Configure Spicetify ───────────────────────────────────────────────────
echo.
echo  [4/5] Configuring Spicetify...
where spicetify >nul 2>&1
if errorlevel 1 (
    echo  [!] Spicetify not found in PATH.
    echo      Please install Spicetify first: https://spicetify.app/docs/getting-started
    pause
    exit /b 1
)
spicetify config custom_apps spicetify-downloader >nul
spicetify apply >nul
echo      Spicetify configured. OK

:: ── 5. Add server to Windows Startup ────────────────────────────────────────
echo.
echo  [5/5] Setting up auto-start (so the server starts with Windows)...
set "STARTUP=%appdata%\Microsoft\Windows\Start Menu\Programs\Startup"
set "VBS=%STARTUP%\SpicetifyDownloaderServer.vbs"

:: Create a VBScript that launches server.py without showing a console window
(
echo Set oShell = CreateObject^("WScript.Shell"^)
echo oShell.Run "pythonw ""%SPICETIFY_PATH%\server.py""", 0, False
) > "%VBS%"

echo      Auto-start configured. OK

:: ─────────────────────────────────────────────────────────────────────────────
echo.
echo  ==========================================
echo    Installation Complete!
echo  ==========================================
echo.
echo  The server will now start automatically every time you log in to Windows.
echo  Starting it now for this session...
echo.

:: Start the server right now in the background (no console window)
start "" /B pythonw "%SPICETIFY_PATH%\server.py"
timeout /t 2 >nul

echo  Done! Open Spotify and you will see "Spicetify Downloader" in the sidebar.
echo.
pause
