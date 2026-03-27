#Requires -Version 5
# OpenClacky Windows Installation Script
# Usage: powershell -c "irm https://oss.1024code.com/clacky-ai/openclacky/main/scripts/install.ps1 | iex"
#
# If WSL is not installed, this script will install it and ask you to reboot.
# After rebooting, run the same command again to complete installation.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CLACKY_CDN_BASE_URL = "https://oss.1024code.com"
$INSTALL_PS1_COMMAND = "powershell -c `"irm $CLACKY_CDN_BASE_URL/clacky-ai/openclacky/main/scripts/install.ps1 | iex`""
$INSTALL_SCRIPT_URL  = "$CLACKY_CDN_BASE_URL/clacky-ai/openclacky/main/scripts/install_simple.sh"
$UBUNTU_WSL_URL      = "$CLACKY_CDN_BASE_URL/ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz"
$WSL_UPDATE_URL      = "$CLACKY_CDN_BASE_URL/wsl_update_x64.msi"  # Windows 10
$WSL_UPDATE_URL_WIN11 = "$CLACKY_CDN_BASE_URL/wsl.2.6.3.0.x64.msi"  # Windows 11
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
# exit 0 = fully functional
#
# Use cmd.exe to run wsl and discard stderr: native wsl.exe writes localized
# install hints to stderr; in Windows PowerShell 5.x with $ErrorActionPreference
# Stop, stderr merged via 2>&1 becomes NativeCommandError and can terminate the
# script (and mojibake when console encoding mismatches).
function Invoke-WslListExitCode {
    cmd.exe /c "wsl.exe --list 1>nul 2>nul"
    return $LASTEXITCODE
}

# Returns $true if an Ubuntu distro is already registered
# wsl --list outputs UTF-16LE; temporarily switch OutputEncoding to decode correctly
function Test-UbuntuInstalled {
    $prev = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    try {
        $out = (wsl.exe --list --quiet 2>$null) -join "`n"
    } finally {
        [Console]::OutputEncoding = $prev
    }
    return ($out -match '(?im)^ubuntu')
}

function Prompt-Reboot {
    Write-Host ""
    Write-Warn "Please restart your computer."
    Write-Warn "After restarting, run the same command again:"
    Write-Host "  $INSTALL_PS1_COMMAND" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 0
}

# Enable WSL via dism — works offline, no dependency on Microsoft download servers.
# Also installs the WSL2 kernel MSI immediately so that after reboot wsl.exe is
# fully functional and won't show the "WSL must be updated" interactive prompt,
# which would cause this script to loop endlessly on re-run.
function Enable-WslFeatures {
    Write-Step "Enabling WSL components (requires admin)..."
    dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    Write-Success "WSL components enabled."

    # Install kernel MSI right away — without this the stub wsl.exe keeps
    # returning exit code 1 ("must be updated") after every reboot, causing
    # this script to re-enable features and prompt for reboot in a loop.
    Install-WslKernel

    Prompt-Reboot
}

function Install-WslKernel {
    $build = [System.Environment]::OSVersion.Version.Build

    # WSL2 requires Windows 10 build 19041 (version 2004) or later
    if ($build -lt 19041) {
        Write-Fail "Your Windows version is too old to run OpenClacky."
        Write-Fail "Please upgrade to Windows 10 (2020 or later) or Windows 11."
        exit 1
    }

    # Windows 11 (build >= 22000) requires the new full WSL2 package MSI;
    # the legacy wsl_update_x64.msi (v5.x) fails with error 1603 on Windows 11.
    $isWin11 = ($build -ge 22000)
    $url = if ($isWin11) { $WSL_UPDATE_URL_WIN11 } else { $WSL_UPDATE_URL }

    $msiPath = "$env:TEMP\wsl_update.msi"
    Write-Step "Downloading WSL2 kernel update..."
    $curlOk = $false
    try { curl -L --progress-bar $url -o $msiPath; $curlOk = ($LASTEXITCODE -eq 0) } catch {}
    if (-not $curlOk) {
        Invoke-WebRequest -Uri $url -OutFile $msiPath -UseBasicParsing
    }
    Write-Info "Download complete. Installing WSL2 kernel..."
    Start-Process msiexec -Wait -ArgumentList "/i","$msiPath","/quiet","/norestart"
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
    Write-Step "Checking WSL status..."
    $wslCode = Invoke-WslListExitCode
    Write-Info "WSL check result: exit code $wslCode"

    if ($wslCode -eq 1) {
        Enable-WslFeatures
        # Enable-WslFeatures exits after prompting reboot
    }

    if (-not (Test-UbuntuInstalled)) {
        Install-Ubuntu
    }
}

# ---------------------------------------------------------------------------
# Ensure Hyper-V hypervisor is active (required for WSL2)
# ---------------------------------------------------------------------------
function Ensure-HyperV {
    $hypervisorPresent = (Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent
    if ($hypervisorPresent) { return }

    Write-Step "Enabling Hyper-V hypervisor..."
    bcdedit /set hypervisorlaunchtype auto | Out-Null
    Write-Success "Hyper-V enabled."
    Write-Host ""
    Write-Warn "A restart is required to apply the changes."
    Write-Warn "After restarting, run the same command again:"
    Write-Host "  $INSTALL_PS1_COMMAND" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to restart now"
    Restart-Computer -Force
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

# All subsequent operations (bcdedit, dism, wsl) require admin privileges
if (-not (Test-IsAdmin)) {
    Write-Fail "Please re-run this script as Administrator:"
    Write-Host ""
    Write-Host "  Right-click PowerShell -> 'Run as administrator', then:" -ForegroundColor Yellow
    Write-Host "  $INSTALL_PS1_COMMAND" -ForegroundColor Yellow
    exit 1
}

Ensure-HyperV
Install-Wsl

Write-Success "WSL is ready."
Run-InstallInWsl
Show-PostInstall
