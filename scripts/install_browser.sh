#!/bin/bash
# install_browser.sh — install Node.js + chrome-devtools-mcp for browser automation
# Generated from scripts/build/src/install_browser.sh.cc — DO NOT EDIT DIRECTLY

set -e


# ---[ @include lib/colors.sh ]---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_step()    { echo -e "\n${BLUE}==>${NC} $1"; }


# ---[ @include lib/os.sh ]---

# Sets OS (macOS | Linux | Windows | Unknown) and DISTRO (ubuntu | debian | …)
detect_os() {
    case "$(uname -s)" in
        Linux*)  OS=Linux  ;;
        Darwin*) OS=macOS  ;;
        CYGWIN*) OS=Windows ;;
        MINGW*)  OS=Windows ;;
        *)       OS=Unknown ;;
    esac
    print_info "Detected OS: $OS"

    if [ "$OS" = "Linux" ] && [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        DISTRO=$ID
        print_info "Detected Linux distribution: $DISTRO"
    else
        DISTRO=unknown
    fi
}

# Returns 0 if the given command is on PATH
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Boolean helpers — use these in business logic instead of inline string comparisons
is_macos()     { [ "$OS" = "macOS" ]; }
is_linux_apt() { [ "$OS" = "Linux" ] && { [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; }; }

# Returns 0 (true) if $1 >= $2  (semantic version comparison)
version_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

# Assert that the current OS/distro is supported (macOS or Ubuntu/Debian).
# Optional $1: hint message printed on failure (e.g. manual install instructions).
# Exits with code 1 on unsupported OS or distro.
assert_supported_os() {
    local hint="${1:-}"
    if [ "$OS" = "Linux" ]; then
        if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
            return 0
        fi
        print_error "Unsupported Linux distribution: $DISTRO"
        [ -n "$hint" ] && print_info "$hint"
        exit 1
    elif [ "$OS" = "macOS" ]; then
        return 0
    else
        print_error "Unsupported OS: $OS"
        [ -n "$hint" ] && print_info "$hint"
        exit 1
    fi
}


# ---[ @include lib/shell.sh ]---

# Sets CURRENT_SHELL (zsh | bash | fish) and SHELL_RC (path to rc file)
detect_shell() {
    local shell_name
    shell_name=$(basename "$SHELL")

    case "$shell_name" in
        zsh)
            CURRENT_SHELL="zsh"
            SHELL_RC="$HOME/.zshrc"
            ;;
        fish)
            CURRENT_SHELL="fish"
            SHELL_RC="$HOME/.config/fish/config.fish"
            ;;
        bash)
            CURRENT_SHELL="bash"
            # macOS uses ~/.bash_profile; Linux uses ~/.bashrc
            if is_macos; then
                SHELL_RC="$HOME/.bash_profile"
            else
                SHELL_RC="$HOME/.bashrc"
            fi
            ;;
        *)
            CURRENT_SHELL="bash"
            SHELL_RC="$HOME/.bashrc"
            ;;
    esac

    print_info "Detected shell: $CURRENT_SHELL (rc file: $SHELL_RC)"
}


# ---[ @include lib/network.sh ]---

# --------------------------------------------------------------------------
# Mirror variables — overridden by detect_network_region()
# --------------------------------------------------------------------------
SLOW_THRESHOLD_MS=5000
NETWORK_REGION="global"   # china | global | unknown
USE_CN_MIRRORS=false

GITHUB_RAW_BASE_URL="https://raw.githubusercontent.com"
DEFAULT_RUBYGEMS_URL="https://rubygems.org"
DEFAULT_NPM_REGISTRY="https://registry.npmjs.org"
DEFAULT_MISE_INSTALL_URL="https://mise.run"

CN_CDN_BASE_URL="https://oss.1024code.com"
CN_ALIYUN_MIRROR="https://mirrors.aliyun.com"
CN_MISE_INSTALL_URL="${CN_CDN_BASE_URL}/mise.sh"
CN_RUBY_PRECOMPILED_URL="${CN_CDN_BASE_URL}/ruby/ruby-{version}.{platform}.tar.gz"
CN_RUBYGEMS_URL="${CN_ALIYUN_MIRROR}/rubygems/"
CN_NPM_REGISTRY="https://registry.npmmirror.com"
CN_NODE_MIRROR_URL="https://cdn.npmmirror.com/binaries/node/"
CN_GEM_BASE_URL="${CN_CDN_BASE_URL}/openclacky"
CN_GEM_LATEST_URL="${CN_GEM_BASE_URL}/latest.txt"

# Active values (set by detect_network_region)
MISE_INSTALL_URL="$DEFAULT_MISE_INSTALL_URL"
RUBYGEMS_INSTALL_URL="$DEFAULT_RUBYGEMS_URL"
NPM_REGISTRY_URL="$DEFAULT_NPM_REGISTRY"
NODE_MIRROR_URL=""          # empty = mise default (nodejs.org)
RUBY_VERSION_SPEC="ruby@3"  # CN mode pins to a specific precompiled build

# --------------------------------------------------------------------------
# Internal probe helpers
# --------------------------------------------------------------------------

# Probe a single URL; echoes round-trip time in ms, or "timeout"
_probe_url() {
    local url="$1"
    local out http_code total_time
    out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
        --connect-timeout 5 --max-time 5 "$url" 2>/dev/null) || true
    http_code="${out%% *}"
    total_time="${out#* }"
    if [ -z "$http_code" ] || [ "$http_code" = "000" ] || [ "$http_code" = "$out" ]; then
        echo "timeout"; return
    fi
    awk -v s="$total_time" 'BEGIN { printf "%d", s * 1000 }'
}

# Returns 0 (true) if result is slow or unreachable
_is_slow_or_unreachable() {
    local r="$1"
    [ "$r" = "timeout" ] && return 0
    [ "${r:-9999}" -ge "$SLOW_THRESHOLD_MS" ] 2>/dev/null
}

_format_probe_time() {
    local r="$1"
    [ "$r" = "timeout" ] && echo "timeout" && return
    awk -v ms="$r" 'BEGIN { printf "%.1fs", ms / 1000 }'
}

_print_probe_result() {
    local label="$1" result="$2"
    if [ "$result" = "timeout" ]; then
        print_warning "UNREACHABLE  ${label}"
    elif _is_slow_or_unreachable "$result"; then
        print_warning "SLOW ($(_format_probe_time "$result"))  ${label}"
    else
        print_success "OK ($(_format_probe_time "$result"))  ${label}"
    fi
}

# Probe URL up to max_retries times; returns first fast result or last result
_probe_url_with_retry() {
    local url="$1" max="${2:-2}" result
    for _ in $(seq 1 "$max"); do
        result=$(_probe_url "$url")
        ! _is_slow_or_unreachable "$result" && { echo "$result"; return 0; }
    done
    echo "$result"
}

# --------------------------------------------------------------------------
# detect_network_region — sets USE_CN_MIRRORS and active mirror variables
# --------------------------------------------------------------------------
detect_network_region() {
    print_step "Network pre-flight check..."
    echo ""

    local google_result baidu_result
    google_result=$(_probe_url "https://www.google.com")
    baidu_result=$(_probe_url "https://www.baidu.com")

    _print_probe_result "google.com" "$google_result"
    _print_probe_result "baidu.com"  "$baidu_result"

    local google_ok=false baidu_ok=false
    ! _is_slow_or_unreachable "$google_result" && google_ok=true
    ! _is_slow_or_unreachable "$baidu_result"  && baidu_ok=true

    if [ "$google_ok" = true ]; then
        NETWORK_REGION="global"
        print_success "Region: global"
    elif [ "$baidu_ok" = true ]; then
        NETWORK_REGION="china"
        print_success "Region: china"
    else
        NETWORK_REGION="unknown"
        print_warning "Region: unknown (both unreachable)"
    fi
    echo ""

    if [ "$NETWORK_REGION" = "china" ]; then
        local cdn_result mirror_result
        cdn_result=$(_probe_url_with_retry "$CN_MISE_INSTALL_URL")
        mirror_result=$(_probe_url_with_retry "$CN_RUBYGEMS_URL")

        _print_probe_result "CN CDN (mise/Ruby)" "$cdn_result"
        _print_probe_result "Aliyun (gem)"       "$mirror_result"

        local cdn_ok=false mirror_ok=false
        ! _is_slow_or_unreachable "$cdn_result"    && cdn_ok=true
        ! _is_slow_or_unreachable "$mirror_result" && mirror_ok=true

        if [ "$cdn_ok" = true ] || [ "$mirror_ok" = true ]; then
            USE_CN_MIRRORS=true
            MISE_INSTALL_URL="$CN_MISE_INSTALL_URL"
            RUBYGEMS_INSTALL_URL="$CN_RUBYGEMS_URL"
            NPM_REGISTRY_URL="$CN_NPM_REGISTRY"
            NODE_MIRROR_URL="$CN_NODE_MIRROR_URL"
            RUBY_VERSION_SPEC="ruby@3.4.8"
            print_info "CN mirrors applied"
        else
            print_warning "CN mirrors unreachable — falling back to global sources"
        fi
    else
        local rubygems_result mise_result
        rubygems_result=$(_probe_url_with_retry "$DEFAULT_RUBYGEMS_URL")
        mise_result=$(_probe_url_with_retry "$DEFAULT_MISE_INSTALL_URL")

        _print_probe_result "RubyGems" "$rubygems_result"
        _print_probe_result "mise.run" "$mise_result"

        _is_slow_or_unreachable "$rubygems_result" && print_warning "RubyGems is slow/unreachable."
        _is_slow_or_unreachable "$mise_result"     && print_warning "mise.run is slow/unreachable."

        USE_CN_MIRRORS=false
        RUBY_VERSION_SPEC="ruby@3"
    fi

    echo ""
}


# ---[ @include lib/mise.sh ]---

# --------------------------------------------------------------------------
# Internal helper — locate the mise binary
# --------------------------------------------------------------------------
_mise_bin() {
    if [ -x "$HOME/.local/bin/mise" ]; then
        echo "$HOME/.local/bin/mise"
    elif command_exists mise; then
        command -v mise
    else
        echo ""
    fi
}

# --------------------------------------------------------------------------
# ensure_mise — install mise if missing, activate it in the current session
# --------------------------------------------------------------------------
ensure_mise() {
    local mise
    mise=$(_mise_bin)

    if [ -n "$mise" ]; then
        print_success "mise already installed: $($mise --version 2>/dev/null || echo 'n/a')"
        export PATH="$HOME/.local/bin:$PATH"
        eval "$($mise activate bash 2>/dev/null)" 2>/dev/null || true
        MISE_BIN="$mise"
        return 0
    fi

    print_step "Installing mise..."
    if curl -fsSL "$MISE_INSTALL_URL" | sh; then
        export PATH="$HOME/.local/bin:$PATH"
        eval "$(~/.local/bin/mise activate bash 2>/dev/null)" 2>/dev/null || true

        # Persist mise activation to shell rc
        local init_line='eval "$(~/.local/bin/mise activate '"$CURRENT_SHELL"')"'
        if ! grep -q "mise activate" "$SHELL_RC" 2>/dev/null; then
            echo "$init_line" >> "$SHELL_RC"
            print_info "Added mise activation to $SHELL_RC"
        fi

        MISE_BIN="$HOME/.local/bin/mise"
        print_success "mise installed"
    else
        print_error "Failed to install mise"
        return 1
    fi
}

# --------------------------------------------------------------------------
# install_ruby_via_mise — install Ruby via mise
#   CN mode: precompiled binary from oss.1024code.com
#   Global:  mise default (precompiled where available)
# --------------------------------------------------------------------------
install_ruby_via_mise() {
    local mise="${MISE_BIN:-$(_mise_bin)}"
    if [ -z "$mise" ]; then
        print_error "mise not found — call ensure_mise first"
        return 1
    fi

    print_info "Installing Ruby via mise ($RUBY_VERSION_SPEC)..."

    if [ "$USE_CN_MIRRORS" = true ]; then
        "$mise" settings ruby.compile=false 2>/dev/null || true
        "$mise" settings ruby.precompiled_url="$CN_RUBY_PRECOMPILED_URL" 2>/dev/null || true
        print_info "Using precompiled Ruby from CN CDN"
    else
        # Enable precompiled binaries globally (mise supports this on common platforms)
        "$mise" settings ruby.compile=false 2>/dev/null || true
        "$mise" settings unset ruby.precompiled_url 2>/dev/null || true
    fi

    if "$mise" use -g "$RUBY_VERSION_SPEC"; then
        eval "$($mise activate bash 2>/dev/null)" 2>/dev/null || true
        local installed
        installed=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null || echo "unknown")
        print_success "Ruby $installed installed"
    else
        print_error "Failed to install Ruby via mise"
        return 1
    fi
}

# --------------------------------------------------------------------------
# install_node_via_mise — install Node.js 22 via mise
# --------------------------------------------------------------------------
install_node_via_mise() {
    local mise="${MISE_BIN:-$(_mise_bin)}"
    if [ -z "$mise" ]; then
        print_error "mise not found — call ensure_mise first"
        return 1
    fi

    # Skip if compatible Node is already active
    if command_exists node; then
        local ver major
        ver=$(node --version 2>/dev/null | sed 's/v//')
        major="${ver%%.*}"
        if [ "${major:-0}" -ge 22 ] 2>/dev/null; then
            print_success "Node.js v${ver} already satisfies >= 22 — skipping"
            return 0
        fi
    fi

    # Apply CN Node mirror if needed
    if [ "$USE_CN_MIRRORS" = true ] && [ -n "$NODE_MIRROR_URL" ]; then
        "$mise" settings node.mirror_url="$NODE_MIRROR_URL" 2>/dev/null || true
        print_info "Node mirror → ${NODE_MIRROR_URL}"
    fi

    print_info "Installing Node.js 22 via mise..."
    if "$mise" use -g node@22; then
        eval "$($mise activate bash 2>/dev/null)" 2>/dev/null || true
        print_success "Node.js $(node --version 2>/dev/null) installed"
    else
        print_error "Failed to install Node.js via mise"
        return 1
    fi
}


# Chrome DMG — update CHROME_VERSION when re-uploading a newer build to OSS
CHROME_VERSION="134"
DEFAULT_CHROME_DMG_URL="https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg"
CN_CHROME_DMG_URL="${CN_CDN_BASE_URL}/browsers/googlechrome-mac-${CHROME_VERSION}.dmg"

# --------------------------------------------------------------------------
# Ensure Chrome is installed (macOS only)
# Downloads DMG to Desktop, opens it, then exits with instructions.
# Re-run the script after Chrome is installed.
# --------------------------------------------------------------------------
ensure_chrome_macos() {
    print_step "Checking Google Chrome..."

    if [ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ]; then
        print_success "Google Chrome already installed"
        return 0
    fi

    print_warning "Google Chrome not found — downloading..."
    local dmg_url="$DEFAULT_CHROME_DMG_URL"
    if [ "$USE_CN_MIRRORS" = true ]; then
        dmg_url="$CN_CHROME_DMG_URL"
        print_info "Using OSS mirror (Chrome ${CHROME_VERSION})"
    else
        print_info "Using official Google download"
    fi

    local dmg_path="$HOME/Desktop/googlechrome.dmg"
    print_info "Downloading Chrome (~238 MB) to Desktop..."
    curl -L --progress-bar "$dmg_url" -o "$dmg_path" || {
        print_error "Download failed"
        print_info "Please download manually: ${dmg_url}"
        exit 1
    }

    print_success "Downloaded: ${dmg_path}"
    print_info "Opening DMG installer..."
    open "$dmg_path"
    echo ""
    print_info "Drag 'Google Chrome' to Applications, then re-run this script."
    exit 0
}

# --------------------------------------------------------------------------
# install_chrome_devtools_mcp — npm global install
# --------------------------------------------------------------------------
install_chrome_devtools_mcp() {
    print_step "Installing chrome-devtools-mcp..."

    if [ "$USE_CN_MIRRORS" = true ]; then
        npm config set registry "$NPM_REGISTRY_URL" 2>/dev/null || true
        print_info "npm registry → ${NPM_REGISTRY_URL}"
    fi

    if npm install -g chrome-devtools-mcp@latest 2>/dev/null; then
        print_success "chrome-devtools-mcp installed"
    else
        print_error "chrome-devtools-mcp installation failed"
        print_info "Try manually: npm install -g chrome-devtools-mcp@latest"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    echo ""
    echo "Browser Automation Setup"
    echo "========================"

    detect_os
    detect_shell
    detect_network_region

    is_macos && ensure_chrome_macos

    print_step "Checking Node.js..."
    ensure_mise || exit 1
    install_node_via_mise || exit 1

    install_chrome_devtools_mcp || exit 1

    echo ""
    print_success "Done. Browser automation is ready."
    echo ""
}

main "$@"
