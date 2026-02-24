<#
.SYNOPSIS
    Spicetify Downloader — One-line installer for Windows.
.DESCRIPTION
    Usage:
        iwr -useb https://raw.githubusercontent.com/diorhc/spicetify-downloader/main/install.ps1 | iex

    This script automatically:
      1. Checks / installs Python (via winget)
      2. Checks / installs Spicetify
      3. Installs spotdl + yt-dlp + ffmpeg via pip
      4. Downloads extension files from GitHub
      5. Registers the custom app in Spicetify
      6. Sets up background server auto-start
      7. Applies Spicetify and starts the server

    NO API KEYS REQUIRED — works out of the box.
#>

# Native-command stderr must NOT be treated as a fatal error.
# ErrorActionPreference stays Continue; individual critical steps use -ErrorAction Stop.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# Force UTF-8 so em-dashes and arrows render correctly in all terminals.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $OutputEncoding              = [System.Text.Encoding]::UTF8 } catch {}

# ── Config ──────────────────────────────────────────────────────────────────

$REPO_OWNER   = "diorhc"
$REPO_NAME    = "spicetify-downloader"
$REPO_BRANCH  = "main"
$REPO_RAW     = "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$REPO_BRANCH"
$APP_NAME     = "spicetify-downloader"
$SERVER_PORT  = 8765

# Files to download from GitHub
$CUSTOM_APP_FILES = @(
    "custom-app/manifest.json",
    "custom-app/index.js",
    "custom-app/settings.js",
    "custom-app/downloader.js",
    "custom-app/app.js"
)
$BACKEND_FILES = @(
    "backend/server.py",
    "backend/requirements.txt"
)

# ── Helpers ─────────────────────────────────────────────────────────────────

function Write-Step($num, $total, $msg) {
    Write-Host ""
    Write-Host "  [$num/$total] $msg" -ForegroundColor Cyan
}

function Write-OK($msg) {
    Write-Host "          $msg -- OK" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "          [!] $msg" -ForegroundColor Yellow
}

function Write-Fail($msg) {
    Write-Host ""
    Write-Host "  [!] $msg" -ForegroundColor Red
    Write-Host ""
}

function Test-CommandExists($cmd) {
    $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Update-PathEnvironment {
    $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH    = "$machinePath;$userPath"
}

# ── Banner ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Green
Write-Host "    Spicetify Downloader -- One-Line Installer" -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  No API keys needed. Just wait -- fully automatic." -ForegroundColor Gray
Write-Host ""

$totalSteps = 7

# ── 1. Python ───────────────────────────────────────────────────────────────

Write-Step 1 $totalSteps "Checking Python..."

if (-not (Test-CommandExists "python")) {
    Write-Host "          Not found -- installing Python via winget..." -ForegroundColor Yellow
    if (Test-CommandExists "winget") {
        try { $null = & winget install Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent 2>&1 } catch {}
        Update-PathEnvironment
    }
    if (-not (Test-CommandExists "python")) {
        Write-Fail "Python not found. Install Python 3.8+ from https://www.python.org/downloads/ (tick 'Add to PATH'), then re-run."
        return
    }
}

$pyVer = (python --version 2>&1) -replace 'Python ',''
Write-OK "Python $pyVer"

# Find python.exe path
$pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
$pythonwExe = Join-Path (Split-Path $pythonExe) "pythonw.exe"
if (-not (Test-Path $pythonwExe)) { $pythonwExe = $pythonExe }

# Ensure pip
try { $null = & python -m ensurepip --upgrade 2>&1 } catch {}

# ── 2. Spicetify ───────────────────────────────────────────────────────────

Write-Step 2 $totalSteps "Checking Spicetify..."

if (-not (Test-CommandExists "spicetify")) {
    Write-Host "          Not found -- installing Spicetify..." -ForegroundColor Yellow
    try {
        Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/spicetify/cli/main/install.ps1" |
            Invoke-Expression 2>$null
    } catch {
        Write-Warn "Spicetify download failed. Retrying..."
        Start-Sleep -Seconds 2
        Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/spicetify/cli/main/install.ps1" |
            Invoke-Expression
    }
    Update-PathEnvironment
    # Add common spicetify paths
    if (Test-Path "$env:LOCALAPPDATA\spicetify") {
        $env:PATH = "$env:LOCALAPPDATA\spicetify;$env:PATH"
    }
    if (Test-Path "$env:USERPROFILE\.spicetify") {
        $env:PATH = "$env:USERPROFILE\.spicetify;$env:PATH"
    }
    if (-not (Test-CommandExists "spicetify")) {
        Write-Fail "Spicetify not in PATH. Close this window, reopen, and run the installer again."
        return
    }
}

$spVer = (spicetify --version 2>&1).ToString().Trim()
Write-OK "Spicetify $spVer"

# ── 3. Install spotdl + yt-dlp ─────────────────────────────────────────────

Write-Step 3 $totalSteps "Installing download engines (spotdl + yt-dlp)..."

function Install-PythonPackage([string]$pkg) {
    try {
        $out = & python -m pip install --quiet --upgrade $pkg 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "$pkg install exited $LASTEXITCODE (may still work)"
        } else {
            Write-Host "          $pkg -- OK" -ForegroundColor Green
        }
    } catch {
        Write-Warn "$pkg install error: $_"
    }
}

Install-PythonPackage 'spotdl'
Install-PythonPackage 'yt-dlp'

# ── 4. FFmpeg ───────────────────────────────────────────────────────────────

Write-Step 4 $totalSteps "Setting up FFmpeg..."

$ffmpegReady = Test-CommandExists "ffmpeg"

if (-not $ffmpegReady) {
    Write-Host "          Downloading FFmpeg via spotdl..." -ForegroundColor Yellow
    try {
        $null = Write-Output 'y' | & python -m spotdl --download-ffmpeg 2>&1
    } catch {}
    $ffmpegReady = Test-CommandExists "ffmpeg"
}

if (-not $ffmpegReady) {
    # Check spotdl-managed ffmpeg locations
    $spotdlFfmpeg = Join-Path $env:USERPROFILE ".spotdl\ffmpeg.exe"
    if (Test-Path $spotdlFfmpeg) {
        $env:PATH = (Split-Path $spotdlFfmpeg) + ";$env:PATH"
        $ffmpegReady = $true
    }
}

if (-not $ffmpegReady -and (Test-CommandExists "winget")) {
    Write-Host "          Trying winget..." -ForegroundColor Yellow
    try { $null = & winget install Gyan.FFmpeg --accept-package-agreements --accept-source-agreements --silent 2>&1 } catch {}
    Update-PathEnvironment
    $ffmpegReady = Test-CommandExists "ffmpeg"
}

if (-not $ffmpegReady) {
    Write-Host "          Trying imageio-ffmpeg..." -ForegroundColor Yellow
    try { $null = & python -m pip install --quiet --upgrade imageio-ffmpeg 2>&1 } catch {}
    try {
        $managed = & python -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())" 2>&1
        if ($managed -and (Test-Path ($managed.ToString().Trim()))) { $ffmpegReady = $true }
    } catch {}
}

if ($ffmpegReady) {
    Write-OK "FFmpeg"
} else {
    Write-Warn "FFmpeg not found -- downloads may fail without it."
    Write-Warn "Install manually: https://ffmpeg.org/download.html"
}

# ── 5. Download extension files from GitHub ─────────────────────────────────

Write-Step 5 $totalSteps "Downloading extension files..."

# Detect spicetify userdata path
$spicetifyUserdata = $null
try {
    $spicetifyUserdata = (& spicetify path userdata 2>&1).ToString().Trim()
} catch { $spicetifyUserdata = "" }
if (-not $spicetifyUserdata) {
    $spicetifyUserdata = Join-Path $env:APPDATA "spicetify"
}

$customAppPath = Join-Path $spicetifyUserdata "CustomApps\$APP_NAME"
$backendPath   = Join-Path $customAppPath "backend"

New-Item -ItemType Directory -Force -Path $customAppPath | Out-Null
New-Item -ItemType Directory -Force -Path $backendPath   | Out-Null

$downloadFailed = $false

foreach ($file in $CUSTOM_APP_FILES) {
    $fileName = Split-Path $file -Leaf
    $destPath = Join-Path $customAppPath $fileName
    $url      = "$REPO_RAW/$file"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $destPath -ErrorAction Stop
    } catch {
        Write-Warn "Failed to download: $file"
        $downloadFailed = $true
    }
}

foreach ($file in $BACKEND_FILES) {
    $fileName = Split-Path $file -Leaf
    $destPath = Join-Path $backendPath $fileName
    $url      = "$REPO_RAW/$file"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $destPath -ErrorAction Stop
    } catch {
        Write-Warn "Failed to download: $file"
        $downloadFailed = $true
    }
}

if ($downloadFailed) {
    Write-Warn "Some files failed to download. Check your internet and retry."
} else {
    Write-OK "Files downloaded to $customAppPath"
}

# ── 6. Configure Spicetify ──────────────────────────────────────────────────

Write-Step 6 $totalSteps "Configuring Spicetify..."

try { $null = & spicetify config custom_apps $APP_NAME 2>&1 } catch {}
try { $null = & spicetify apply 2>&1 } catch {}
if ($LASTEXITCODE -ne 0) {
    Write-Warn "spicetify apply failed. Close Spotify fully and re-run this installer."
} else {
    Write-OK "Spicetify configured"
}

# ── 7. Auto-start + launch server ──────────────────────────────────────────

Write-Step 7 $totalSteps "Setting up background server..."

$serverPy  = Join-Path $backendPath "server.py"
$startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$startupCmd = Join-Path $startupDir "SpicetifyDownloaderServer.cmd"

# Create startup script
@"
@echo off
start "" "$pythonwExe" "$serverPy"
"@ | Set-Content -Path $startupCmd -Encoding ASCII

Write-Host "          Auto-start registered" -ForegroundColor Gray

# Kill any running server
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -like '*server.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Start-Sleep -Seconds 1

# Start server now
Start-Process -FilePath $pythonwExe -ArgumentList "`"$serverPy`"" -WindowStyle Hidden

# Wait for server to be ready
$serverOK = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$SERVER_PORT/health" -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($resp -and $resp.StatusCode -eq 200) {
            $serverOK = $true
            break
        }
    } catch {}
}

if ($serverOK) {
    Write-OK "Server started on port $SERVER_PORT"
} else {
    Write-Warn "Server not responding yet. It will start on next login."
}

# ── Done ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Green
Write-Host "    Installation Complete!" -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  No API keys needed -- everything works out of the box!" -ForegroundColor Gray
Write-Host ""
Write-Host "  How to download music:" -ForegroundColor White
Write-Host "    - Open album/playlist and click Spotify's Download button" -ForegroundColor Gray
Write-Host "    - Right-click any track/playlist/album > 'Download for Offline'" -ForegroundColor Gray
Write-Host "    - Press Ctrl+Shift+D" -ForegroundColor Gray
Write-Host ""
Write-Host "  To listen offline in Spotify:" -ForegroundColor White
Write-Host "    Settings > Local Files > Add: $env:USERPROFILE\Music\Spotify Downloads" -ForegroundColor Gray
Write-Host ""
Write-Host "  Open Spotify and enjoy!" -ForegroundColor Green
Write-Host ""
