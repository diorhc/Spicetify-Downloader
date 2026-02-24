@echo off
setlocal enabledelayedexpansion
title Spicetify Downloader - Installer
chcp 65001 >nul 2>&1

echo.
echo  ==========================================
echo    Spicetify Downloader - Easy Installer
echo  ==========================================
echo.
echo  This will install everything automatically.
echo  Just wait — no extra steps needed.
echo.

:: ======================================================================
:: 1. Python
:: ======================================================================
echo  [1/5] Checking Python...
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
    winget install Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent
    if errorlevel 1 (
        echo.
        echo  [!] Python install failed.
        echo      Please install manually: https://www.python.org/downloads/
        echo.
        pause & exit /b 1
    )
    :: Refresh PATH so new python is available immediately
    for /f "tokens=*" %%i in ('powershell -NoProfile -Command "[System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('PATH','User')"') do set "PATH=%%i"
    python --version >nul 2>&1
    if errorlevel 1 (
        echo.
        echo  [!] Python installed but not yet available in PATH.
        echo      Please close this window, reopen it, and run install.bat again.
        echo.
        pause & exit /b 1
    )
)
for /f "tokens=2 delims= " %%v in ('python --version 2^>^&1') do set PYVER=%%v
echo         Python %PYVER% — OK

:: Get full path to python.exe
for /f "tokens=*" %%p in ('where python 2^>nul') do (
    set "PYTHON_EXE=%%p"
    goto :got_python
)
:got_python

:: ======================================================================
:: 2. Spicetify
:: ======================================================================
echo.
echo  [2/5] Checking Spicetify...
where spicetify >nul 2>&1
if errorlevel 1 (
    echo         Not found — installing Spicetify automatically...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -useb https://raw.githubusercontent.com/spicetify/cli/main/install.ps1 | iex" >nul 2>&1
    :: Refresh PATH
    for /f "tokens=*" %%i in ('powershell -NoProfile -Command "[System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('PATH','User')"') do set "PATH=%%i"
    :: Also add common spicetify location
    if exist "%LOCALAPPDATA%\spicetify" set "PATH=%LOCALAPPDATA%\spicetify;!PATH!"
    if exist "%USERPROFILE%\.spicetify" set "PATH=%USERPROFILE%\.spicetify;!PATH!"
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

:: ======================================================================
:: 3. SpotDL (music downloader engine)
:: ======================================================================
echo.
echo  [3/5] Installing music downloader (SpotDL)...
python -m pip install --quiet --upgrade spotdl
if errorlevel 1 (
    echo  [!] SpotDL install failed. Check your internet connection and try again.
    pause & exit /b 1
)
echo         SpotDL — OK

:: ======================================================================
:: 4. FFmpeg (required by SpotDL for audio conversion)
:: ======================================================================
echo.
echo  [4/5] Setting up FFmpeg...
ffmpeg -version >nul 2>&1
if errorlevel 1 (
    echo         FFmpeg not in PATH — downloading via SpotDL...
    python -m spotdl --download-ffmpeg >nul 2>&1
    if errorlevel 1 (
        echo         Trying winget as fallback...
        winget install Gyan.FFmpeg --accept-package-agreements --accept-source-agreements --silent >nul 2>&1
        for /f "tokens=*" %%i in ('powershell -NoProfile -Command "[System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('PATH','User')"') do set "PATH=%%i"
        ffmpeg -version >nul 2>&1
        if errorlevel 1 (
            echo         Trying Python fallback (imageio-ffmpeg)...
            python -m pip install --quiet --upgrade imageio-ffmpeg >nul 2>&1
        )
    )
)
echo         FFmpeg — OK

:: ======================================================================
:: 5. Copy files + configure Spicetify
:: ======================================================================
echo.
echo  [5/5] Setting up the extension in Spotify...

:: Detect Spicetify data path
for /f "tokens=*" %%p in ('spicetify path userdata 2^>nul') do set "SPICETIFY_USERDATA=%%p"
if not defined SPICETIFY_USERDATA set "SPICETIFY_USERDATA=%APPDATA%\spicetify"

set "CUSTOM_APP_PATH=!SPICETIFY_USERDATA!\CustomApps\spicetify-downloader"
set "BACKEND_PATH=!CUSTOM_APP_PATH!\backend"

if not exist "!CUSTOM_APP_PATH!" mkdir "!CUSTOM_APP_PATH!"
if not exist "!BACKEND_PATH!"    mkdir "!BACKEND_PATH!"

:: Copy all custom-app files
copy /Y "custom-app\manifest.json" "!CUSTOM_APP_PATH!\" >nul 2>&1
copy /Y "custom-app\index.js"      "!CUSTOM_APP_PATH!\" >nul 2>&1
copy /Y "custom-app\settings.js"   "!CUSTOM_APP_PATH!\" >nul 2>&1
copy /Y "custom-app\downloader.js" "!CUSTOM_APP_PATH!\" >nul 2>&1
copy /Y "custom-app\app.js"        "!CUSTOM_APP_PATH!\" >nul 2>&1

:: Copy backend files
copy /Y "backend\server.py"        "!BACKEND_PATH!\"    >nul 2>&1
copy /Y "backend\requirements.txt" "!BACKEND_PATH!\"    >nul 2>&1

:: Register custom app and apply
spicetify config custom_apps spicetify-downloader
if errorlevel 1 (
    echo  [!] Warning: could not register custom app. Trying to apply anyway...
)
spicetify apply
if errorlevel 1 (
    echo.
    echo  [!] Spicetify apply failed.
    echo      Close Spotify fully (check system tray), then run install.bat again.
    echo.
    pause & exit /b 1
)
echo         Extension installed — OK

:: ── Auto-start: run server silently on Windows login via VBS ─────────────────
set "SERVER_PY=!BACKEND_PATH!\server.py"
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "VBS=!STARTUP!\SpicetifyDownloaderServer.vbs"

:: Locate pythonw.exe (no console window) next to python.exe
set "PYTHONW_EXE=!PYTHON_EXE:python.exe=pythonw.exe!"
if not exist "!PYTHONW_EXE!" set "PYTHONW_EXE=!PYTHON_EXE!"

:: Write startup VBS that runs server silently on every login
(
    echo Set W = CreateObject^("WScript.Shell"^)
    echo W.Run chr^(34^) ^& "!PYTHONW_EXE!" ^& chr^(34^) ^& " " ^& chr^(34^) ^& "!SERVER_PY!" ^& chr^(34^), 0, False
) > "!VBS!"

:: ── Kill any existing server instances (using PowerShell, not deprecated wmic) ──
echo.
echo  Restarting background server...
powershell -NoProfile -Command "Get-Process python*, pythonw* -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*server.py*' } | Stop-Process -Force -ErrorAction SilentlyContinue" >nul 2>&1

:: Small delay to let port free up
timeout /t 2 /nobreak >nul

:: Start server silently via VBS (same method as auto-start)
if exist "!VBS!" (
    cscript //nologo "!VBS!"
) else (
    start "" "!PYTHONW_EXE!" "!SERVER_PY!"
)

:: Verify server started (give it 5 seconds)
echo  Waiting for server to start...
timeout /t 5 /nobreak >nul
powershell -NoProfile -Command ^
    "try { $r = Invoke-WebRequest 'http://localhost:8765/health' -UseBasicParsing -TimeoutSec 5; if ($r.StatusCode -eq 200) { Write-Host '        Server started — OK' } else { Write-Host '  [!] Server returned HTTP' $r.StatusCode } } catch { Write-Host '  [!] Server not reachable yet — it will start on next login.' }"

:: ======================================================================
echo.
echo  ==========================================
echo    Done! Open Spotify and enjoy.
echo  ==========================================
echo.
echo   How to download music:
echo     - RIGHT-CLICK any playlist, album, or track ^> "Download with SpotDL"
echo     - OR press Ctrl+Shift+D
echo     - OR click the download arrow button in the top bar
echo     - OR open "Spicetify Downloader" in the left sidebar
echo.
echo   Downloaded files go to: %USERPROFILE%\Music\Spotify Downloads
echo.
pause
