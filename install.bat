@echo off
setlocal enabledelayedexpansion
title Spicetify Downloader - Installer
chcp 65001 >nul 2>&1

set "LOG=%~dp0install.log"
if exist "%LOG%" del "%LOG%" >nul 2>&1

echo.
echo  ==========================================
echo    Spicetify Downloader - Easy Installer
echo  ==========================================
echo.
echo  This will install everything automatically.
echo  Just wait -- no extra steps needed.
echo.

call :log "=== Spicetify Downloader Install Log ==="

:: ======================================================================
:: 1. Python
:: ======================================================================
echo  [1/5] Checking Python...
python --version >nul 2>&1
if errorlevel 1 (
    echo         Not found - installing Python automatically...
    winget --version >nul 2>&1
    if errorlevel 1 (
        echo.
        echo  [!] Cannot install Python automatically on this PC.
        echo      Please install Python 3.8+ from: https://www.python.org/downloads/
        echo      During install, tick "Add Python to PATH", then re-run this file.
        echo.
        call :log "[ERROR] winget not found, cannot auto-install Python"
        goto :err
    )
    winget install Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent
    if errorlevel 1 (
        echo.
        echo  [!] Python install failed.
        echo      Please install manually: https://www.python.org/downloads/
        echo.
        call :log "[ERROR] winget failed to install Python"
        goto :err
    )
    call :refresh_path
    python --version >nul 2>&1
    if errorlevel 1 (
        echo.
        echo  [!] Python installed but not yet available in PATH.
        echo      Please close this window, reopen it, and run install.bat again.
        echo.
        call :log "[ERROR] Python installed but not in PATH yet"
        goto :err
    )
)
for /f "tokens=2 delims= " %%v in ('python --version 2^>^&1') do set "PYVER=%%v"
echo         Python !PYVER! -- OK
call :log "[OK] Python !PYVER!"

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
    echo         Not found - installing Spicetify automatically...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -useb https://raw.githubusercontent.com/spicetify/cli/main/install.ps1 | iex" >nul 2>&1
    call :refresh_path
    if exist "%LOCALAPPDATA%\spicetify" set "PATH=%LOCALAPPDATA%\spicetify;!PATH!"
    if exist "%USERPROFILE%\.spicetify" set "PATH=%USERPROFILE%\.spicetify;!PATH!"
    where spicetify >nul 2>&1
    if errorlevel 1 (
        echo.
        echo  [!] Spicetify not in PATH after install.
        echo      Please close this window, reopen it, and run install.bat again.
        echo.
        call :log "[ERROR] Spicetify not in PATH after install"
        goto :err
    )
)
for /f "tokens=*" %%v in ('spicetify --version 2^>^&1') do set "SPVER=%%v"
echo         Spicetify !SPVER! -- OK
call :log "[OK] Spicetify !SPVER!"

:: ======================================================================
:: 3. SpotDL
:: ======================================================================
echo.
echo  [3/5] Installing music downloader (SpotDL)...
python -m pip install --quiet --upgrade spotdl
if errorlevel 1 (
    echo  [!] SpotDL install failed. Check your internet connection and try again.
    call :log "[ERROR] pip install spotdl failed"
    goto :err
)
echo         SpotDL -- OK
call :log "[OK] SpotDL"

:: ======================================================================
:: 4. FFmpeg
:: ======================================================================
echo.
echo  [4/5] Setting up FFmpeg...
ffmpeg -version >nul 2>&1
if errorlevel 1 (
    echo         FFmpeg not in PATH - downloading via SpotDL...
    python -m spotdl --download-ffmpeg >nul 2>&1
    if errorlevel 1 (
        echo         Trying winget as fallback...
        winget install Gyan.FFmpeg --accept-package-agreements --accept-source-agreements --silent >nul 2>&1
        call :refresh_path
        ffmpeg -version >nul 2>&1
        if errorlevel 1 (
            echo         Trying Python fallback (imageio-ffmpeg)...
            python -m pip install --quiet --upgrade imageio-ffmpeg >nul 2>&1
        )
    )
)
echo         FFmpeg -- OK
call :log "[OK] FFmpeg"

:: ======================================================================
:: 5. Copy files + configure Spicetify
:: ======================================================================
echo.
echo  [5/5] Setting up the extension in Spotify...

for /f "tokens=*" %%p in ('spicetify path userdata 2^>nul') do set "SPICETIFY_USERDATA=%%p"
if not defined SPICETIFY_USERDATA set "SPICETIFY_USERDATA=%APPDATA%\spicetify"

set "CUSTOM_APP_PATH=!SPICETIFY_USERDATA!\CustomApps\spicetify-downloader"
set "BACKEND_PATH=!CUSTOM_APP_PATH!\backend"

if not exist "!CUSTOM_APP_PATH!" mkdir "!CUSTOM_APP_PATH!"
if not exist "!BACKEND_PATH!"    mkdir "!BACKEND_PATH!"

copy /Y "custom-app\manifest.json" "!CUSTOM_APP_PATH!\" >nul 2>&1
copy /Y "custom-app\index.js"      "!CUSTOM_APP_PATH!\" >nul 2>&1
copy /Y "custom-app\settings.js"   "!CUSTOM_APP_PATH!\" >nul 2>&1
copy /Y "custom-app\downloader.js" "!CUSTOM_APP_PATH!\" >nul 2>&1
copy /Y "custom-app\app.js"        "!CUSTOM_APP_PATH!\" >nul 2>&1
copy /Y "backend\server.py"        "!BACKEND_PATH!\"    >nul 2>&1
copy /Y "backend\requirements.txt" "!BACKEND_PATH!\"    >nul 2>&1
call :log "[OK] Files copied to !CUSTOM_APP_PATH!"

spicetify config custom_apps spicetify-downloader
if errorlevel 1 (
    echo  [!] Warning: could not register custom app. Trying to apply anyway...
    call :log "[WARN] spicetify config custom_apps returned error"
)
spicetify apply
if errorlevel 1 (
    echo.
    echo  [!] Spicetify apply failed.
    echo      Close Spotify fully (check system tray), then run install.bat again.
    echo.
    call :log "[ERROR] spicetify apply failed"
    goto :err
)
echo         Extension installed -- OK
call :log "[OK] spicetify apply"

::  Auto-start VBS 
set "SERVER_PY=!BACKEND_PATH!\server.py"
set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "VBS=!STARTUP_DIR!\SpicetifyDownloaderServer.vbs"

set "PYTHONW_EXE=!PYTHON_EXE:python.exe=pythonw.exe!"
if not exist "!PYTHONW_EXE!" set "PYTHONW_EXE=!PYTHON_EXE!"

(
    echo Set W = CreateObject^("WScript.Shell"^)
    echo W.Run chr^(34^) ^& "!PYTHONW_EXE!" ^& chr^(34^) ^& " " ^& chr^(34^) ^& "!SERVER_PY!" ^& chr^(34^), 0, False
) > "!VBS!"

::  Kill any existing server instances 
echo.
echo  Restarting background server...
powershell -NoProfile -Command "Get-Process python,pythonw -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue" >nul 2>&1

timeout /t 2 /nobreak >nul

if exist "!VBS!" (
    cscript //nologo "!VBS!"
) else (
    start "" "!PYTHONW_EXE!" "!SERVER_PY!"
)

echo  Waiting for server to start...
timeout /t 5 /nobreak >nul
powershell -NoProfile -Command "try { $r = Invoke-WebRequest http://localhost:8765/health -UseBasicParsing -TimeoutSec 5; if ($r.StatusCode -eq 200) { Write-Host '        Server started -- OK' } else { Write-Host '  [!] Server returned HTTP '$r.StatusCode } } catch { Write-Host '  [!] Server not reachable yet -- it will start on next login.' }"
call :log "[OK] Done"

echo.
echo  ==========================================
echo    Done! Open Spotify and enjoy.
echo  ==========================================
echo.
echo   How to download music:
echo     - RIGHT-CLICK any playlist, album, or track ^> "Download with SpotDL"
echo     - OR press Ctrl+Shift+D
echo     - OR click the download arrow button in the top bar
echo.
echo   Downloaded files: %USERPROFILE%\Music\Spotify Downloads
echo.
echo   Install log: %LOG%
echo.
echo Press any key to exit...
pause
goto :EOF

:: ======================================================================
:: Subroutines
:: ======================================================================
:err
echo.
echo  ==========================================
echo   [!] Installation stopped.
echo   See log file for details: %LOG%
echo  ==========================================
echo.
pause
exit /b 1

:log
echo %~1 >> "%LOG%" 2>&1
goto :EOF

:refresh_path
for /f "usebackq tokens=*" %%i in (`powershell -NoProfile -Command "[System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('PATH','User')"`) do set "PATH=%%i"
goto :EOF