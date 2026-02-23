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
echo  Just wait - no extra steps needed.
echo.

:: ======================================================================
:: 1. Python
:: ======================================================================
echo  [1/4] Checking Python...
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
        pause ^& exit /b 1
    )
    winget install Python.Python.3 --accept-package-agreements --accept-source-agreements --silent
    if errorlevel 1 (
        echo.
        echo  [!] Python install failed.
        echo      Please install it manually: https://www.python.org/downloads/
        echo.
        pause ^& exit /b 1
    )
    for /f "tokens=*" %%i in ('powershell -NoProfile -Command "[System.Environment]::GetEnvironmentVariable(\"PATH\",\"Machine\") + \";\" + [System.Environment]::GetEnvironmentVariable(\"PATH\",\"User\")"') do set "PATH=%%i"
    python --version >nul 2>&1
    if errorlevel 1 (
        echo.
        echo  [!] Python installed but not yet available.
        echo      Please close this window, reopen it, and run install.bat again.
        echo.
        pause ^& exit /b 1
    )
)
for /f "tokens=2 delims= " %%v in ('python --version 2^>^&1') do set PYVER=%%v
echo         Python %PYVER% - OK

:: Get full path to python.exe (needed for VBS and direct launch)
for /f "tokens=*" %%p in ('where python 2^>nul') do (
    set "PYTHON_EXE=%%p"
    goto :got_python
)
:got_python

:: ======================================================================
:: 2. Spicetify
:: ======================================================================
echo.
echo  [2/4] Checking Spicetify...
where spicetify >nul 2>&1
if errorlevel 1 (
    echo         Not found - installing Spicetify automatically...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -useb https://raw.githubusercontent.com/spicetify/cli/main/install.ps1 | iex" >nul 2>&1
    for /f "tokens=*" %%i in ('powershell -NoProfile -Command "[System.Environment]::GetEnvironmentVariable(\"PATH\",\"Machine\") + \";\" + [System.Environment]::GetEnvironmentVariable(\"PATH\",\"User\")"') do set "PATH=%%i"
    where spicetify >nul 2>&1
    if errorlevel 1 (
        echo.
        echo  [!] Spicetify installed but not yet in PATH.
        echo      Please close this window, reopen it, and run install.bat again.
        echo.
        pause ^& exit /b 1
    )
)
for /f "tokens=*" %%v in ('spicetify --version 2^>^&1') do set SPVER=%%v
echo         Spicetify %SPVER% - OK

:: ======================================================================
:: 3. SpotDL
:: ======================================================================
echo.
echo  [3/4] Installing music downloader (SpotDL)...
python -m pip install --quiet --upgrade spotdl
if errorlevel 1 (
    echo  [!] SpotDL install failed. Check your internet connection and try again.
    pause ^& exit /b 1
)
echo         SpotDL - OK

:: ======================================================================
:: 4. Copy files + configure Spicetify
:: ======================================================================
echo.
echo  [4/4] Setting up the extension in Spotify...

:: Detect actual Spicetify data path (works on both old and new versions)
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
copy /Y "backend\server.py"        "!BACKEND_PATH!\"    >nul 2>&1
copy /Y "backend\requirements.txt" "!BACKEND_PATH!\"    >nul 2>&1

spicetify config custom_apps spicetify-downloader >nul 2>&1
spicetify apply
if errorlevel 1 (
    echo.
    echo  [!] Spicetify apply failed.
    echo      Close Spotify fully, then run install.bat again.
    echo.
    pause ^& exit /b 1
)
echo         Extension installed - OK

:: ======================================================================
:: Auto-start: run server silently on Windows login via VBS
:: ======================================================================
set "SERVER_PY=!BACKEND_PATH!\server.py"
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "VBS=!STARTUP!\SpicetifyDownloaderServer.vbs"

:: Write VBS using chr(34) to avoid quoting issues in paths
(
    echo Set W = CreateObject^("WScript.Shell"^)
    echo W.Run chr^(34^) ^& "!PYTHON_EXE!" ^& chr^(34^) ^& " " ^& chr^(34^) ^& "!SERVER_PY!" ^& chr^(34^), 0, False
) > "!VBS!"

:: Kill any old server, start fresh (use pythonw for background execution)
taskkill /f /im pythonw.exe >nul 2>&1
start "" /min "!PYTHON_EXE!" "!SERVER_PY!"

:: ======================================================================
echo.
echo  ==========================================
echo    Done! Open Spotify and enjoy.
echo  ==========================================
echo.
echo   How to download music:
echo   1. Open any playlist or album in Spotify
echo   2. RIGHT-CLICK the playlist/album and choose "Download with SpotDL"
echo      OR press Ctrl+Shift+D
echo      OR open "Spicetify Downloader" in the left sidebar
echo.
pause