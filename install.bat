@echo off
setlocal enabledelayedexpansion
title Spicetify Downloader — Installer
chcp 65001 >nul 2>&1

echo.
echo  ==========================================
echo    Spicetify Downloader — Easy Installer
echo  ==========================================
echo.
echo  This will install everything automatically.
echo  Just wait — no extra steps needed.
echo.

:: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
:: 1. Python
:: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo  [1/4] Checking Python...
python --version >nul 2>&1
if errorlevel 1 (
    echo         Not found — installing Python automatically...
    winget --version >nul 2>&1
    if errorlevel 1 (
        echo.
        echo  [!] Cannot install Python automatically on this PC.
        echo      Please install Python 3.8+ from: https://www.python.org/downloads/
        echo      During install, tick "Add Python to PATH", then re-run this file.
        echo.
        pause & exit /b 1
    )
    winget install Python.Python.3 --accept-package-agreements --accept-source-agreements --silent
    if errorlevel 1 (
        echo.
        echo  [!] Python install failed.
        echo      Please install it manually: https://www.python.org/downloads/
        echo.
        pause & exit /b 1
    )
    :: Refresh PATH so python is visible in this session
    for /f "tokens=*" %%i in ('powershell -NoProfile -Command "[System.Environment]::GetEnvironmentVariable(\"PATH\",\"Machine\") + \";\" + [System.Environment]::GetEnvironmentVariable(\"PATH\",\"User\")"') do set "PATH=%%i"
    python --version >nul 2>&1
    if errorlevel 1 (
        echo.
        echo  [!] Python installed but not yet in PATH.
        echo      Please close this window, reopen it, and run install.bat again.
        echo.
        pause & exit /b 1
    )
)
for /f "tokens=2 delims= " %%v in ('python --version 2^>^&1') do set PYVER=%%v
echo         Python %PYVER% — OK

:: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
:: 2. Spicetify
:: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.
echo  [2/4] Checking Spicetify...
where spicetify >nul 2>&1
if errorlevel 1 (
    echo         Not found — installing Spicetify automatically...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "iwr -useb https://raw.githubusercontent.com/spicetify/cli/main/install.ps1 | iex" ^
        >nul 2>&1
    :: Refresh PATH
    for /f "tokens=*" %%i in ('powershell -NoProfile -Command "[System.Environment]::GetEnvironmentVariable(\"PATH\",\"Machine\") + \";\" + [System.Environment]::GetEnvironmentVariable(\"PATH\",\"User\")"') do set "PATH=%%i"
    where spicetify >nul 2>&1
    if errorlevel 1 (
        echo.
        echo  [!] Spicetify installed but not yet in PATH.
        echo      Please close this window, reopen it, and run install.bat again.
        echo.
        pause & exit /b 1
    )
)
for /f "tokens=*" %%v in ('spicetify --version 2^>^&1') do set SPVER=%%v
echo         Spicetify %SPVER% — OK

:: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
:: 3. SpotDL + copy files + configure Spicetify
:: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.
echo  [3/4] Installing music downloader (SpotDL)...
python -m pip install --quiet --upgrade spotdl
if errorlevel 1 (
    echo  [!] SpotDL install failed. Check your internet connection and try again.
    pause & exit /b 1
)
echo         SpotDL — OK

echo.
echo  [4/4] Setting up the extension in Spotify...

set "SPICETIFY_PATH=%appdata%\spicetify"
set "CUSTOM_APP_PATH=%SPICETIFY_PATH%\CustomApps\spicetify-downloader"

if not exist "%CUSTOM_APP_PATH%" mkdir "%CUSTOM_APP_PATH%"

copy /Y "custom-app\manifest.json" "%CUSTOM_APP_PATH%\" >nul 2>&1
copy /Y "custom-app\app.js"        "%CUSTOM_APP_PATH%\" >nul 2>&1
copy /Y "custom-app\settings.js"   "%CUSTOM_APP_PATH%\" >nul 2>&1
copy /Y "custom-app\downloader.js" "%CUSTOM_APP_PATH%\" >nul 2>&1
copy /Y "backend\server.py"        "%SPICETIFY_PATH%\"  >nul 2>&1
copy /Y "backend\requirements.txt" "%SPICETIFY_PATH%\"  >nul 2>&1

spicetify backup apply >nul 2>&1
spicetify config custom_apps spicetify-downloader >nul 2>&1
spicetify apply >nul 2>&1
if errorlevel 1 (
    echo  [!] Spicetify apply failed. Make sure Spotify is closed and try again.
    pause & exit /b 1
)
echo         Extension installed — OK

:: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
:: Auto-start: run server silently on Windows login
:: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set "VBS=%appdata%\Microsoft\Windows\Start Menu\Programs\Startup\SpicetifyDownloaderServer.vbs"
(
    echo Set oShell = CreateObject^("WScript.Shell"^)
    echo oShell.Run "pythonw ""%SPICETIFY_PATH%\server.py""", 0, False
) > "%VBS%"

:: Start right now (no visible window)
start "" /min pythonw "%SPICETIFY_PATH%\server.py"

:: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.
echo  ==========================================
echo    Done! Open Spotify and enjoy.
echo  ==========================================
echo.
echo   How to download music:
echo   1. Open any playlist or album in Spotify
echo   2. Click the Download button (arrow icon)
echo   3. Choose quality and wait
echo.
pause
