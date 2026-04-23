#Requires -Version 5
# OpenClacky Windows Installation Script
#
# Usage (standard):
#   powershell -c "irm https://oss.1024code.com/clacky-ai/openclacky/main/scripts/install.ps1 | iex"
#
# Usage (white-label / custom brand):
#   powershell -c "& ([scriptblock]::Create((irm 'https://oss.1024code.com/clacky-ai/openclacky/main/scripts/install.ps1'))) -BrandName 'MyCLI' -CommandName 'mycli'"
#
#   Parameters:
#     -BrandName    Display name shown in prompts    (default: OpenClacky)
#     -CommandName  CLI command name after install   (default: openclacky)
#
# WSL2 is preferred. If virtualisation is unavailable (e.g. running inside a VM),
# the script automatically falls back to WSL1.
# If WSL is not installed at all, the script enables it and asks you to reboot.
# After rebooting, run the same command again to complete installation.
#
# Development: .\install.ps1 -Local
#   Uses install.sh from the same directory as this script instead of CDN.

param(
    [switch]$Local,
    [string]$BrandName   = "",
    [string]$CommandName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$global:DisplayName = if ($BrandName)   { $BrandName }   else { "OpenClacky" }
$global:DisplayCmd  = if ($CommandName) { $CommandName } else { "openclacky" }

$CLACKY_CDN_BASE_URL   = "https://oss.1024code.com"
$INSTALL_PS1_COMMAND   = "powershell -c `"irm $CLACKY_CDN_BASE_URL/clacky-ai/openclacky/main/scripts/install.ps1 | iex`""
$INSTALL_SCRIPT_URL    = "$CLACKY_CDN_BASE_URL/clacky-ai/openclacky/main/scripts/install.sh"
$UBUNTU_WSL_AMD64_URL        = "$CLACKY_CDN_BASE_URL/ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz"
$UBUNTU_WSL_AMD64_SHA256_URL = "$CLACKY_CDN_BASE_URL/ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz.sha256"
$UBUNTU_WSL_ARM64_URL        = "$CLACKY_CDN_BASE_URL/ubuntu-jammy-wsl-arm64-ubuntu22.04lts.rootfs.tar.gz"
$UBUNTU_WSL_ARM64_SHA256_URL = "$CLACKY_CDN_BASE_URL/ubuntu-jammy-wsl-arm64-ubuntu22.04lts.rootfs.tar.gz.sha256"
$WSL_UPDATE_URL_X64    = "$CLACKY_CDN_BASE_URL/wsl.2.6.3.0.x64.msi"    # Windows x64 (Win10+Win11)
$WSL_UPDATE_URL_ARM64  = "$CLACKY_CDN_BASE_URL/wsl.2.6.3.0.arm64.msi"  # Windows ARM64
$UBUNTU_WSL_DIR        = "$env:SystemDrive\WSL\Ubuntu"

# ===========================================================================
# Shared Helpers
# ===========================================================================

function Write-Info    { param($msg) Write-Host "  [i] $msg" -ForegroundColor Cyan }
function Write-Success { param($msg) Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Warn    { param($msg) Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Write-Fail    { param($msg) Write-Host "  [x] $msg" -ForegroundColor Red }
function Write-Step    { param($msg) Write-Host "`n==> $msg" -ForegroundColor Blue }

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Returns a stable ASCII installer workspace.
# Prefer $env:TEMP, but fallback to C:\Temp if it contains non-ASCII characters
# (e.g. Chinese usernames) which cause wsl.exe --import and related commands to fail.
function Get-SafeTempDir {
    $tempDir = $env:TEMP
    
    # Check if path contains non-ASCII characters
    if ($tempDir -notmatch '[^\x00-\x7F]') {
        return $tempDir
    }
    
    # Fallback to C:\Temp if non-ASCII detected
    $dir = "$env:SystemDrive\Temp"
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return $dir
}

# Robust file download: try curl first (shows progress), fall back to
# Invoke-WebRequest. Returns $true on success, $false on failure.
function Invoke-Download {
    param([string]$Url, [string]$OutFile)
    $ok = $false
    try {
        curl.exe -L --fail --progress-bar $Url -o $OutFile
        $ok = ($LASTEXITCODE -eq 0)
    } catch {}
    if (-not $ok) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
            $ok = $true
        } catch { $ok = $false }
    }
    return $ok
}

# Verify SHA256 of a local file against a remote .sha256 file.
# Returns $true on match, or if the checksum file cannot be fetched (non-fatal).
function Test-Sha256 {
    param([string]$FilePath, [string]$Sha256Url)
    $safeTemp = Get-SafeTempDir
    $sha256File = "$safeTemp\download.sha256"
    try {
        if (-not (Invoke-Download -Url $Sha256Url -OutFile $sha256File)) {
            Write-Warn "Could not download checksum file — skipping verification."
            return $true
        }
        $expectedLine = (Get-Content $sha256File -Raw).Trim()
        $expected     = ($expectedLine -split '\s+')[0].ToLower()
        $actual       = (Get-FileHash -Algorithm SHA256 -Path $FilePath).Hash.ToLower()
        if ($actual -ne $expected) {
            Write-Fail "Checksum mismatch!"
            Write-Fail "  Expected : $expected"
            Write-Fail "  Got      : $actual"
            return $false
        }
        Write-Success "Checksum OK."
        return $true
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $sha256File
    }
}

# Use cmd.exe to avoid PS5 NativeCommandError and UTF-16LE mojibake on stderr.
# exit 1 = WSL feature not enabled; exit 0 = WSL is functional.
# Timeout 10s to avoid hanging when WSL is partially initialised.
function Invoke-WslStatusExitCode {
    # Returns the exit code of `wsl --status`.
    # exit 0   = WSL fully enabled (Win11 / distro installed)
    # exit 1   = WSL feature not enabled
    # exit -1  = WSL enabled, no distro installed (Win10 wsl --list)
    # exit -444 = WSL enabled, no distro installed (Win10 wsl --status)
    # Only exit 1 means "WSL is not set up". All other codes mean WSL is functional.
    # Timeout (10s) is treated as exit 1 (WSL completely unresponsive).
    #
    # Note: Start-Process + -Redirect* loses ExitCode. Use System.Diagnostics.Process directly.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $psi.Arguments = "--status"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try { $p = [System.Diagnostics.Process]::Start($psi) } catch { return 1 }
    $finished = $p.WaitForExit(10000)   # 10 seconds
    if (-not $finished) {
        $p.Kill()
        Write-Info "WSL --status timed out (WSL not ready)."
        return 1
    }
    return $p.ExitCode
}

# Returns $true if a distro named exactly "Ubuntu" is registered.
# wsl --list outputs UTF-16LE; switch OutputEncoding to decode correctly.
function Test-UbuntuInstalled {
    $prev = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    try {
        $out = (wsl.exe --list --quiet 2>$null) -join "`n"
    } finally {
        [Console]::OutputEncoding = $prev
    }
    # Whole-line match to avoid false positives from Ubuntu-22.04, Ubuntu-24.04, etc.
    return ($out -match '(?im)^Ubuntu\s*$')
}

# Returns 'arm64' or 'amd64'
function Get-CpuArch {
    $arch = (Get-CimInstance Win32_Processor).Architecture
    # 12 = ARM64
    if ($arch -eq 12) { return "arm64" }
    return "amd64"
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

# Download Ubuntu rootfs, verify checksum, import into WSL.
# $WslVersion: 1 or 2
function Install-UbuntuRootfs {
    param([int]$WslVersion)

    $cpuArch = Get-CpuArch
    Write-Info "CPU architecture: $cpuArch"

    if ($cpuArch -eq "arm64") {
        $wslUrl    = $UBUNTU_WSL_ARM64_URL
        $sha256Url = $UBUNTU_WSL_ARM64_SHA256_URL
    } else {
        $wslUrl    = $UBUNTU_WSL_AMD64_URL
        $sha256Url = $UBUNTU_WSL_AMD64_SHA256_URL
    }

    $safeTemp   = Get-SafeTempDir
    $tarPath    = "$safeTemp\ubuntu-wsl-$cpuArch.tar.gz"
    $installDir = $UBUNTU_WSL_DIR

    # Disk space check (~2 GB needed: 350 MB download + ~1.5 GB imported)
    $drive     = Split-Path -Qualifier $installDir
    $freeBytes = (Get-PSDrive ($drive.TrimEnd(':'))).Free
    if ($freeBytes -lt 2GB) {
        Write-Fail "Not enough disk space on $drive."
        Write-Fail "  Available : $([math]::Round($freeBytes / 1GB, 1)) GB"
        Write-Fail "  Required  : ~2 GB"
        exit 1
    }

    # Check if a valid cached tarball exists (skip download if checksum passes)
    $needDownload = $true
    if (Test-Path $tarPath) {
        Write-Info "Found cached Ubuntu rootfs, verifying checksum..."
        if (Test-Sha256 -FilePath $tarPath -Sha256Url $sha256Url) {
            Write-Success "Cache valid — skipping download."
            $needDownload = $false
        } else {
            Write-Warn "Cache corrupted — re-downloading..."
            Remove-Item -Force $tarPath
        }
    }

    try {
        if ($needDownload) {
            Write-Step "Downloading Ubuntu rootfs (~350 MB)..."
            if (-not (Invoke-Download -Url $wslUrl -OutFile $tarPath)) {
                Write-Fail "Failed to download Ubuntu rootfs. Check your network and try again."
                exit 1
            }
            Write-Success "Download complete."

            Write-Step "Verifying checksum..."
            if (-not (Test-Sha256 -FilePath $tarPath -Sha256Url $sha256Url)) {
                Write-Fail "The downloaded file is corrupted. Please try again."
                exit 1
            }
        }

        Write-Step "Importing Ubuntu into WSL$WslVersion (this may take a minute)..."
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        wsl.exe --import Ubuntu $installDir $tarPath --version $WslVersion
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "wsl --import failed (exit $LASTEXITCODE)."
            Write-Fail "Try removing $installDir and running the script again."
            exit 1
        }
        Write-Success "Ubuntu (WSL$WslVersion) imported successfully."
    } finally {
        # Keep the tarball as cache for future runs (e.g. after reboot)
        # Only clean up if import succeeded — leave it for retry otherwise
        if (Test-Path $tarPath) {
            Write-Info "Keeping Ubuntu rootfs cache at $tarPath for future use."
        }
    }
}

# Install OpenClacky inside the Ubuntu WSL distro.
function Run-InstallInWsl {
    Write-Step "Installing $DisplayName inside WSL..."

    if ($Local) {
        # Convert Windows path to WSL path (e.g. C:\foo\bar -> /mnt/c/foo/bar)
        $scriptDir = Split-Path -Parent $MyInvocation.PSCommandPath
        $localScript = Join-Path $scriptDir "install.sh"
        if (-not (Test-Path $localScript)) {
            Write-Fail "Local mode: install.sh not found at $localScript"
            exit 1
        }
        $wslPath = ($localScript -replace '\', '/') -replace '^([A-Za-z]):', { '/mnt/' + $args[0].Groups[1].Value.ToLower() }
        Write-Info "Local mode: using $wslPath"
        wsl.exe -d Ubuntu -u root -- bash $wslPath --brand-name=$BrandName --command=$CommandName
    } else {
        wsl.exe -d Ubuntu -u root -- bash -c "cd ~ && curl -fsSL $INSTALL_SCRIPT_URL | bash -s -- --brand-name=$BrandName --command=$CommandName"
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Installation failed inside WSL (exit $LASTEXITCODE)."
        Write-Fail "You can retry manually:"
        Write-Host "  wsl -d Ubuntu -u root -- bash -c `"curl -fsSL $INSTALL_SCRIPT_URL | bash`"" -ForegroundColor Yellow
        exit 1
    }
}

function Show-PostInstall {
    param([int]$WslVersion)
    Write-Host ""
    Write-Success "$DisplayName installed successfully (WSL$WslVersion)."
    Write-Host ""
    Write-Info "To use $DisplayName, first enter WSL:"
    Write-Host "   wsl" -ForegroundColor Green
    Write-Host ""
    Write-Info "Then run ${DisplayName}:"
    Write-Host "   $DisplayCmd" -ForegroundColor Green
    Write-Host ""
    Write-Info "Or start the Web UI:"
    Write-Host "   $DisplayCmd server" -ForegroundColor Green
    Write-Host "   Then open http://localhost:7070 in your browser"
    Write-Host ""
}

# ===========================================================================
# Registry helpers  (HKCU:\Software\OpenClacky\Install)
# ===========================================================================
$REG_ROOT = "HKCU:\Software\OpenClacky\Install"

function Get-InstallReg {
    param([string]$Name, $Default = $null)
    try {
        $val = (Get-ItemProperty -Path $REG_ROOT -Name $Name -ErrorAction Stop).$Name
        return $val
    } catch {
        return $Default
    }
}

function Set-InstallReg {
    param([string]$Name, $Value)
    if (-not (Test-Path $REG_ROOT)) {
        New-Item -Path $REG_ROOT -Force | Out-Null
    }
    Set-ItemProperty -Path $REG_ROOT -Name $Name -Value $Value
}

function Remove-InstallReg {
    param([string]$Name)
    try {
        Remove-ItemProperty -Path $REG_ROOT -Name $Name -ErrorAction Stop
    } catch {}
}

# ===========================================================================
# WSL2 Path — preferred, requires hardware virtualisation
# ===========================================================================

# Returns $true if WSL2 is actually usable by doing a real probe import.
# A 512-byte zero-filled tar (valid EOF block) is used as minimal rootfs.
# Probe import succeeds   → WSL2 usable
# Probe import fails (HCS_E_HYPERV_NOT_INSTALLED etc.) → WSL1 only
function Test-VirtualisationSupported {
    # Probe WSL2 with a minimal tar (512 zero bytes = valid tar EOF block)
    # Called only after WSL feature is confirmed enabled (Main already checked).
    Write-Info "Probing WSL2 availability..."

    $safeTemp = Get-SafeTempDir
    $probeTar = "$safeTemp\wsl_probe.tar"
    $probeDir = "$safeTemp\wsl_probe"
    $ok = $false
    try {
        $bytes = New-Object byte[] 512
        [System.IO.File]::WriteAllBytes($probeTar, $bytes)
        New-Item -ItemType Directory -Force -Path $probeDir | Out-Null

        Write-Info "[probe] Running: wsl --import WslProbe $probeDir $probeTar --version 2"
        wsl.exe --import WslProbe $probeDir $probeTar --version 2 >$null 2>$null
        $importExit = $LASTEXITCODE
        Write-Info "[probe] wsl --import exit code: $importExit"
        $ok = ($importExit -eq 0)
        if ($ok) {
            wsl.exe --unregister WslProbe 2>$null | Out-Null
            Write-Info "[probe] WslProbe unregistered."
        }
    } catch {
        Write-Info "[probe] Exception caught: $_"
        $ok = $false
    } finally {
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $probeDir
        Remove-Item -Force -ErrorAction SilentlyContinue $probeTar
    }

    Write-Info "[probe] Final result: ok=$ok"
    if ($ok) {
        Write-Info "WSL2 probe passed — using WSL2."
    } else {
        Write-Info "WSL2 probe failed (Hyper-V not available) — falling back to WSL1."
    }
    return $ok
}

# Download and install the WSL2 kernel MSI from our CDN.
function Install-WslKernel {
    $cpuArch = Get-CpuArch

    # Select the correct MSI for this CPU architecture.
    if ($cpuArch -eq "arm64") {
        $url = $WSL_UPDATE_URL_ARM64
    } else {
        $url = $WSL_UPDATE_URL_X64
    }

    $safeTemp = Get-SafeTempDir
    $msiPath = "$safeTemp\wsl_update.msi"
    Write-Step "Downloading WSL kernel update ($cpuArch)..."
    if (-not (Invoke-Download -Url $url -OutFile $msiPath)) {
        Write-Fail "Failed to download WSL kernel update. Check your network and try again."
        exit 1
    }
    Write-Info "Installing WSL kernel..."
    Start-Process msiexec -Wait -ArgumentList "/i", $msiPath, "/quiet", "/norestart"
    Write-Success "WSL kernel installed."
    Remove-Item -Force -ErrorAction SilentlyContinue $msiPath
}

# Enable WSL + VirtualMachinePlatform features, install kernel MSI, then reboot.
function Enable-WslFeatures {
    Write-Step "Enabling WSL components..."
    dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    Write-Success "WSL components enabled."
    Install-WslKernel
    Set-InstallReg -Name "InstallPhase" -Value "wsl-pending"
    Prompt-Reboot
}

# Full WSL2 install path. Called only after WSL feature is confirmed enabled
# and WSL2 probe has passed.
function Install-WithWsl2 {
    Write-Step "WSL2 mode selected."
    if (Test-UbuntuInstalled) {
        Write-Info "Ubuntu (WSL) already installed — skipping import."
    } else {
        wsl.exe --set-default-version 2 2>$null
        Install-UbuntuRootfs -WslVersion 2
    }
}

# ===========================================================================
# WSL1 Path — fallback when virtualisation is unavailable (e.g. inside a VM)
# ===========================================================================

# Full WSL1 install path. Called only after WSL feature is confirmed enabled
# and WSL2 probe has failed (Hyper-V not available).
function Install-WithWsl1 {
    Write-Step "WSL1 mode selected."
    if (Test-UbuntuInstalled) {
        Write-Info "Ubuntu (WSL) already installed — skipping import."
    } else {
        Install-UbuntuRootfs -WslVersion 1
    }
}

# ===========================================================================
# Main
# ===========================================================================
Write-Host ""
Write-Host "$DisplayName Installation Script (Windows)" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-IsAdmin)) {
    Write-Fail "Please re-run this script as Administrator:"
    Write-Host ""
    Write-Host "  Right-click PowerShell -> 'Run as administrator', then:" -ForegroundColor Yellow
    Write-Host "  $INSTALL_PS1_COMMAND" -ForegroundColor Yellow
    exit 1
}

# Check minimum Windows version: WSL1 requires Build 16215 (Win10 1709).
$osBuild = [System.Environment]::OSVersion.Version.Build
if ($osBuild -lt 16215) {
    Write-Fail "Unsupported Windows version (Build $osBuild)."
    Write-Fail "WSL requires Windows 10 Build 16215 (version 1709) or later."
    Write-Fail "Please update Windows and try again."
    exit 1
}
Write-Info "Windows Build $osBuild — OK."

# Step 1: Ensure WSL feature is enabled (same for WSL1 and WSL2)
Write-Step "Checking WSL status..."
$wslCode = Invoke-WslStatusExitCode
Write-Info "WSL --status exit code: $wslCode"
$installPhase = Get-InstallReg -Name "InstallPhase" -Default ""
Write-Info "InstallPhase: '$installPhase'"

if ($installPhase -eq "" -and $wslCode -ne 0) {
    # First run and WSL not ready: enable WSL features and reboot.
    Enable-WslFeatures
    # Always exits (prompts reboot)
}

# phase == wsl-pending + code 1: reboot happened but WSL still not ready.
if ($installPhase -eq "wsl-pending" -and $wslCode -eq 1) {
    Write-Warn "WSL features were enabled but WSL is still not ready."
    Write-Warn "Please reboot your computer and run the installer again."
    Write-Warn "If this keeps happening, please contact our support team."
    exit 1
}

# wslCode != 1 (0, -1, -444, 50, etc.): WSL is functional, continue.
Remove-InstallReg -Name "InstallPhase"

# Step 2: Probe whether WSL2 actually works
$virt = Test-VirtualisationSupported
Write-Info "[main] Test-VirtualisationSupported returned: $virt"
if ($virt) {
    Install-WithWsl2
    $wslVersion = 2
} else {
    Write-Info "[main] WSL2 unavailable, falling back to WSL1..."
    Install-WithWsl1
    $wslVersion = 1
}

Write-Success "WSL is ready."
Run-InstallInWsl
Set-InstallReg -Name "WslVersion" -Value $wslVersion
Show-PostInstall -WslVersion $wslVersion
