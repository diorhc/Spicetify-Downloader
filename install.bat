@echo off
setlocal enabledelayedexpansion
title Spicetify Downloader - Installer
chcp 65001 >nul 2>&1

pushd "%~dp0" >nul 2>&1
if errorlevel 1 (
    echo.
    echo  [!] Cannot access script directory: %~dp0
    echo.
    pause
    exit /b 1
)

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
python -m pip --version >nul 2>&1
if errorlevel 1 (
    python -m ensurepip --upgrade >nul 2>&1
)
python -m pip --version >nul 2>&1
if errorlevel 1 (
    echo  [!] pip is not available in this Python installation.
    call :log "[ERROR] pip missing and ensurepip failed"
    goto :err
)
python -m pip install --upgrade spotdl
if errorlevel 1 (
    echo  [!] SpotDL install failed. Check your internet connection and try again.
    call :log "[ERROR] pip install spotdl failed"
    goto :err
)
echo         SpotDL -- OK
call :log "[OK] SpotDL"

echo         Installing yt-dlp (fallback engine)...
python -m pip install --upgrade yt-dlp
if errorlevel 1 (
    echo  [!] yt-dlp install failed (non-critical, spotdl will still work).
    call :log "[WARN] pip install yt-dlp failed"
) else (
    echo         yt-dlp -- OK
    call :log "[OK] yt-dlp"
)

echo.
echo  No API keys required -- everything works out of the box!

:: ======================================================================
:: 4. FFmpeg
:: ======================================================================
echo.
echo  [4/5] Setting up FFmpeg...
set "FFMPEG_READY=0"
ffmpeg -version >nul 2>&1
if not errorlevel 1 set "FFMPEG_READY=1"

if "!FFMPEG_READY!"=="0" (
    echo         FFmpeg not in PATH - downloading via SpotDL...
    python -m spotdl --download-ffmpeg >nul 2>&1
    ffmpeg -version >nul 2>&1
    if not errorlevel 1 set "FFMPEG_READY=1"
)

if "!FFMPEG_READY!"=="0" (
    echo         Trying winget as fallback...
    winget install Gyan.FFmpeg --accept-package-agreements --accept-source-agreements --silent >nul 2>&1
    call :refresh_path
    ffmpeg -version >nul 2>&1
    if not errorlevel 1 set "FFMPEG_READY=1"
)

if "!FFMPEG_READY!"=="0" (
    echo         Trying Python fallback imageio-ffmpeg...
    python -m pip install --upgrade imageio-ffmpeg >nul 2>&1
    python -c "import imageio_ffmpeg; imageio_ffmpeg.get_ffmpeg_exe()" >nul 2>&1
    if not errorlevel 1 set "FFMPEG_READY=1"
)

if "!FFMPEG_READY!"=="0" (
    echo.
    echo  [!] FFmpeg setup failed.
    echo      Install FFmpeg manually and run install.bat again.
    echo.
    call :log "[ERROR] FFmpeg setup failed after all fallbacks"
    goto :err
)

echo         FFmpeg -- OK
call :log "[OK] FFmpeg"

:: ======================================================================
:: 5. Copy files + configure Spicetify
:: ======================================================================
echo.
echo  [5/5] Setting up the extension in Spotify...

if not exist "custom-app\manifest.json" (
    echo  [!] Missing file: custom-app\manifest.json
    call :log "[ERROR] Missing source file custom-app\\manifest.json"
    goto :err
)
if not exist "custom-app\index.js" (
    echo  [!] Missing file: custom-app\index.js
    call :log "[ERROR] Missing source file custom-app\\index.js"
    goto :err
)
if not exist "custom-app\settings.js" (
    echo  [!] Missing file: custom-app\settings.js
    call :log "[ERROR] Missing source file custom-app\\settings.js"
    goto :err
)
if not exist "custom-app\downloader.js" (
    echo  [!] Missing file: custom-app\downloader.js
    call :log "[ERROR] Missing source file custom-app\\downloader.js"
    goto :err
)
if not exist "custom-app\app.js" (
    echo  [!] Missing file: custom-app\app.js
    call :log "[ERROR] Missing source file custom-app\\app.js"
    goto :err
)
if not exist "backend\server.py" (
    echo  [!] Missing file: backend\server.py
    call :log "[ERROR] Missing source file backend\\server.py"
    goto :err
)
if not exist "backend\requirements.txt" (
    echo  [!] Missing file: backend\requirements.txt
    call :log "[ERROR] Missing source file backend\\requirements.txt"
    goto :err
)

for /f "tokens=*" %%p in ('spicetify path userdata 2^>nul') do set "SPICETIFY_USERDATA=%%p"
if not defined SPICETIFY_USERDATA set "SPICETIFY_USERDATA=%APPDATA%\spicetify"

set "CUSTOM_APP_PATH=!SPICETIFY_USERDATA!\CustomApps\spicetify-downloader"
set "BACKEND_PATH=!CUSTOM_APP_PATH!\backend"

if not exist "!CUSTOM_APP_PATH!" mkdir "!CUSTOM_APP_PATH!"
if not exist "!BACKEND_PATH!"    mkdir "!BACKEND_PATH!"

copy /Y "custom-app\manifest.json" "!CUSTOM_APP_PATH!\" >nul 2>&1
if errorlevel 1 goto :copy_err
copy /Y "custom-app\index.js"      "!CUSTOM_APP_PATH!\" >nul 2>&1
if errorlevel 1 goto :copy_err
copy /Y "custom-app\settings.js"   "!CUSTOM_APP_PATH!\" >nul 2>&1
if errorlevel 1 goto :copy_err
copy /Y "custom-app\downloader.js" "!CUSTOM_APP_PATH!\" >nul 2>&1
if errorlevel 1 goto :copy_err
copy /Y "custom-app\app.js"        "!CUSTOM_APP_PATH!\" >nul 2>&1
if errorlevel 1 goto :copy_err
copy /Y "backend\server.py"        "!BACKEND_PATH!\"    >nul 2>&1
if errorlevel 1 goto :copy_err
copy /Y "backend\requirements.txt" "!BACKEND_PATH!\"    >nul 2>&1
if errorlevel 1 goto :copy_err
call :log "[OK] Files copied to !CUSTOM_APP_PATH!"

goto :copy_ok

:copy_err
echo  [!] Failed to copy one or more extension files.
call :log "[ERROR] Copy operation failed"
goto :err

:copy_ok

spicetify config custom_apps spicetify-downloader
if errorlevel 1 (
    echo  [!] Warning: could not register custom app. Trying to apply anyway...
    call :log "[WARN] spicetify config custom_apps returned error"
)
spicetify apply
if errorlevel 1 (
    echo.
    echo  [!] Spicetify apply failed.
    echo      Close Spotify fully ^(check system tray^), then run install.bat again.
    echo.
    call :log "[ERROR] spicetify apply failed"
    goto :err
)
echo         Extension installed -- OK
call :log "[OK] spicetify apply"

set "SERVER_PY=!BACKEND_PATH!\server.py"
set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "STARTUP_CMD=!STARTUP_DIR!\SpicetifyDownloaderServer.cmd"

:: Find pythonw.exe (no-console Python) in the same directory as python.exe
for %%f in ("!PYTHON_EXE!") do set "PYTHONW_EXE=%%~dpfpythonw.exe"
if not exist "!PYTHONW_EXE!" set "PYTHONW_EXE=!PYTHON_EXE!"

:: Register auto-start via Startup folder (more reliable across locked Task Scheduler policies)
(
    echo @echo off
    echo start "" "!PYTHONW_EXE!" "!SERVER_PY!"
) > "!STARTUP_CMD!"
if errorlevel 1 (
    echo  [!] Note: Startup entry could not be written ^(non-critical^).
    call :log "[WARN] Startup entry creation failed - non-critical"
) else (
    call :log "[OK] Startup entry created for auto-start on logon"
)

::  Kill any running server instances 
echo.
echo  Restarting background server...
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object {$_.CommandLine -like '*server.py*'} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA 0 }" >nul 2>&1
timeout /t 2 /nobreak >nul

:: Launch server now in background
start "" "!PYTHONW_EXE!" "!SERVER_PY!" >nul 2>&1
if errorlevel 1 start /B "" "!PYTHON_EXE!" "!SERVER_PY!"

echo  Waiting for server to start...
set "SERVER_OK=0"
for /l %%i in (1,1,15) do (
    if "!SERVER_OK!"=="0" (
        timeout /t 1 /nobreak >nul
        powershell -NoProfile -Command "try{Invoke-WebRequest 'http://localhost:8765/health' -UseBasicParsing -TimeoutSec 2 | Out-Null; exit 0}catch{exit 1}" >nul 2>&1
        if not errorlevel 1 set "SERVER_OK=1"
    )
)
if "!SERVER_OK!"=="1" (
    echo         Server started -- OK
    call :log "[OK] Server started"
) else (
    echo  [!] Server not responding yet.
    echo      It will start automatically on next Windows login.
    echo      Or run install.bat again to retry.
    call :log "[WARN] Server did not respond during install"
)
call :log "[OK] Done"

echo.
echo  ==========================================
echo    Done^! Open Spotify and enjoy.
echo  ==========================================
echo.
echo   How to download music:
echo     - Open album/playlist and click Spotify's default Download button
echo     - RIGHT-CLICK any playlist, album, or track ^> "Download for Offline"
echo     - OR press Ctrl+Shift+D
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

