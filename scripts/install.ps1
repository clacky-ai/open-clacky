#Requires -Version 5
# OpenClacky Windows Installation Script
# Usage: powershell -c "irm https://oss.1024code.com/install.ps1 | iex"
#
# If WSL is not installed, this script will install it and ask you to reboot.
# After rebooting, run the same command again to complete installation.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CLACKY_CDN_BASE_URL = "https://oss.1024code.com"
$INSTALL_PS1_COMMAND = "powershell -c `"irm $CLACKY_CDN_BASE_URL/install.ps1 | iex`""
$INSTALL_SCRIPT_URL  = "$CLACKY_CDN_BASE_URL/install.sh"
$UBUNTU_WSL_URL      = "$CLACKY_CDN_BASE_URL/ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz"
$WSL_UPDATE_URL      = "$CLACKY_CDN_BASE_URL/wsl_update_x64.msi"
$UBUNTU_WSL_DIR     = "C:\WSL\Ubuntu"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info    { param($msg) Write-Host "  [i] $msg" -ForegroundColor Cyan }
function Write-Success { param($msg) Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Warn    { param($msg) Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Write-Fail    { param($msg) Write-Host "  [x] $msg" -ForegroundColor Red }
function Write-Step    { param($msg) Write-Host "`n==> $msg" -ForegroundColor Blue }

# ---------------------------------------------------------------------------
# WSL check / install
# ---------------------------------------------------------------------------

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# exit 1 = WSL feature not enabled (stub wsl.exe)
# exit -1 = feature enabled but kernel missing
# exit 0 = fully functional
function Test-WslFeatureEnabled {
    & wsl.exe --list 2>&1 | Out-Null
    return ($LASTEXITCODE -ne 1)
}

# Returns $true if WSL2 kernel is present (exit 0)
function Test-WslKernel {
    & wsl.exe --list 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Returns $true if an Ubuntu distro is already registered
function Test-UbuntuInstalled {
    try {
        $out = & wsl --list --quiet 2>&1 | Out-String
        return ($out -match '(?im)^ubuntu')
    } catch {
        return $false
    }
}

function Prompt-Reboot {
    Write-Host ""
    Write-Warn "Please restart your computer."
    Write-Warn "After restarting, run the same command again:"
    Write-Host "  $INSTALL_PS1_COMMAND" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# Enable WSL via dism — works offline, no dependency on Microsoft download servers
function Enable-WslFeatures {
    Write-Step "Enabling WSL components (requires admin)..."
    dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    Write-Success "WSL components enabled."
    Prompt-Reboot
}

function Install-WslKernel {
    $msiPath = "$env:TEMP\wsl_update.msi"
    Write-Step "Downloading WSL2 kernel update..."
    $curlOk = $false
    try { curl -L --progress-bar $WSL_UPDATE_URL -o $msiPath; $curlOk = ($LASTEXITCODE -eq 0) } catch {}
    if (-not $curlOk) {
        Invoke-WebRequest -Uri $WSL_UPDATE_URL -OutFile $msiPath -UseBasicParsing
    }
    Write-Info "Download complete. Installing WSL2 kernel..."
    Start-Process msiexec -Verb RunAs -Wait -ArgumentList "/i","$msiPath","/quiet","/norestart"
    Write-Success "WSL2 kernel installed."
}

# Download Ubuntu rootfs from COS and import into WSL
function Install-Ubuntu {
    $tarPath    = "$env:TEMP\ubuntu-wsl.tar.gz"
    $installDir = $UBUNTU_WSL_DIR

    Write-Step "Downloading Ubuntu (~350MB)..."
    $curlOk = $false
    try { curl -L --progress-bar $UBUNTU_WSL_URL -o $tarPath; $curlOk = ($LASTEXITCODE -eq 0) } catch {}
    if (-not $curlOk) {
        Invoke-WebRequest -Uri $UBUNTU_WSL_URL -OutFile $tarPath -UseBasicParsing
    }
    Write-Success "Download complete."

    Write-Step "Importing Ubuntu into WSL..."
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    wsl --import Ubuntu $installDir $tarPath
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "wsl --import failed."
        exit 1
    }
    Write-Success "Ubuntu imported successfully."
}

function Install-Wsl {
    if (-not (Test-IsAdmin)) {
        Write-Fail "Please re-run this script as Administrator:"
        Write-Host ""
        Write-Host "  Right-click PowerShell -> 'Run as administrator', then:" -ForegroundColor Yellow
        Write-Host "  $INSTALL_PS1_COMMAND" -ForegroundColor Yellow
        exit 1
    }

    if (-not (Test-WslFeatureEnabled)) {
        Enable-WslFeatures
        # Enable-WslFeatures exits after prompting reboot
    }

    if (-not (Test-WslKernel)) {
        Install-WslKernel
    }

    if (-not (Test-UbuntuInstalled)) {
        Install-Ubuntu
    }
}

# ---------------------------------------------------------------------------
# Install OpenClacky inside WSL
# ---------------------------------------------------------------------------
function Run-InstallInWsl {
    Write-Step "Installing OpenClacky inside WSL..."

    wsl -d Ubuntu -u root -- bash -c "cd ~ && curl -fsSL $INSTALL_SCRIPT_URL | bash"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Installation failed inside WSL (exit $LASTEXITCODE)."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Post-install
# ---------------------------------------------------------------------------
function Show-PostInstall {
    Write-Host ""
    Write-Success "OpenClacky installed successfully."
    Write-Host ""
    Write-Info "To use OpenClacky, first enter WSL:"
    Write-Host "   wsl" -ForegroundColor Green
    Write-Host ""
    Write-Info "Then run OpenClacky:"
    Write-Host "   openclacky" -ForegroundColor Green
    Write-Host ""
    Write-Info "Or start the Web UI:"
    Write-Host "   openclacky server" -ForegroundColor Green
    Write-Host "   Then open http://localhost:7070 in your browser"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "OpenClacky Installation Script (Windows)" -ForegroundColor Cyan
Write-Host ""

Install-Wsl

Write-Success "WSL is ready."
Run-InstallInWsl
Show-PostInstall
