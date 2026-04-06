#!/bin/bash
# install_system_deps.sh — install system-level build tools
# Generated from scripts/build/src/install_system_deps.sh.cc — DO NOT EDIT DIRECTLY
#
# macOS : Xcode Command Line Tools + Homebrew
# Linux : build-essential + python3 + git + curl (apt, Ubuntu/Debian)

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
CN_MISE_INSTALL_URL="${CN_CDN_BASE_URL}/mise.sh"
CN_RUBY_PRECOMPILED_URL="${CN_CDN_BASE_URL}/ruby/ruby-{version}.{platform}.tar.gz"
CN_RUBYGEMS_URL="https://mirrors.aliyun.com/rubygems/"
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


# ---[ @include lib/apt.sh ]---

# Configure apt mirror for CN region and run apt-get update.
# Guards: only runs on ubuntu/debian ($DISTRO).
# Relies on $USE_CN_MIRRORS set by detect_network_region (network.sh).
setup_apt_mirror() {
    [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ] || return 0

    if [ "$USE_CN_MIRRORS" = true ]; then
        print_info "Region: China — configuring Aliyun apt mirror"
        local codename="${VERSION_CODENAME:-jammy}"
        local components="main restricted universe multiverse"
        local arch; arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
        if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
            local mirror="https://mirrors.aliyun.com/ubuntu-ports/"
        else
            local mirror="https://mirrors.aliyun.com/ubuntu/"
        fi
        sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb ${mirror} ${codename} ${components}
deb ${mirror} ${codename}-updates ${components}
deb ${mirror} ${codename}-backports ${components}
deb ${mirror} ${codename}-security ${components}
EOF
        print_success "apt mirror set to Aliyun"
    else
        print_info "Region: global — using default apt sources"
    fi

    sudo apt-get update -qq
    print_success "apt updated"
}


# ---[ @include lib/brew.sh ]---

# --------------------------------------------------------------------------
# Homebrew CN mirror URLs (Aliyun)
# --------------------------------------------------------------------------
CN_HOMEBREW_INSTALL_SCRIPT_URL="${CN_CDN_BASE_URL}/Homebrew/install/HEAD/install.sh"
CN_HOMEBREW_BREW_GIT_REMOTE="https://mirrors.aliyun.com/homebrew/brew.git"
CN_HOMEBREW_CORE_GIT_REMOTE="https://mirrors.aliyun.com/homebrew/homebrew-core.git"
CN_HOMEBREW_BOTTLE_DOMAIN="https://mirrors.aliyun.com/homebrew/homebrew-bottles"
CN_HOMEBREW_API_DOMAIN="https://mirrors.aliyun.com/homebrew-bottles/api"

HOMEBREW_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

# --------------------------------------------------------------------------
# configure_homebrew_cn_mirrors — export env vars and persist to SHELL_RC
# Only runs when USE_CN_MIRRORS=true
# --------------------------------------------------------------------------
configure_homebrew_cn_mirrors() {
    [ "$USE_CN_MIRRORS" = true ] || return 0

    print_info "Configuring Homebrew CN mirrors..."
    export HOMEBREW_INSTALL_FROM_API=1
    export HOMEBREW_API_DOMAIN="$CN_HOMEBREW_API_DOMAIN"
    export HOMEBREW_BREW_GIT_REMOTE="$CN_HOMEBREW_BREW_GIT_REMOTE"
    export HOMEBREW_CORE_GIT_REMOTE="$CN_HOMEBREW_CORE_GIT_REMOTE"
    export HOMEBREW_BOTTLE_DOMAIN="$CN_HOMEBREW_BOTTLE_DOMAIN"

    if ! grep -q "HOMEBREW_BOTTLE_DOMAIN" "$SHELL_RC" 2>/dev/null; then
        {
            echo ""
            echo "# Homebrew CN mirrors (added by openclacky installer)"
            echo "export HOMEBREW_INSTALL_FROM_API=1"
            echo "export HOMEBREW_API_DOMAIN=\"${CN_HOMEBREW_API_DOMAIN}\""
            echo "export HOMEBREW_BREW_GIT_REMOTE=\"${CN_HOMEBREW_BREW_GIT_REMOTE}\""
            echo "export HOMEBREW_CORE_GIT_REMOTE=\"${CN_HOMEBREW_CORE_GIT_REMOTE}\""
            echo "export HOMEBREW_BOTTLE_DOMAIN=\"${CN_HOMEBREW_BOTTLE_DOMAIN}\""
        } >> "$SHELL_RC"
        print_success "Homebrew CN mirrors written to $SHELL_RC"
    else
        print_success "Homebrew CN mirrors already configured in $SHELL_RC"
    fi
}

# --------------------------------------------------------------------------
# restore_homebrew_cn_mirrors — remove CN mirror lines from SHELL_RC
# --------------------------------------------------------------------------
restore_homebrew_cn_mirrors() {
    if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ] && grep -q "HOMEBREW_BOTTLE_DOMAIN" "$SHELL_RC" 2>/dev/null; then
        sed -i.bak '/# Homebrew CN mirrors (added by openclacky installer)/d' "$SHELL_RC"
        sed -i.bak '/HOMEBREW_INSTALL_FROM_API/d' "$SHELL_RC"
        sed -i.bak '/HOMEBREW_API_DOMAIN/d' "$SHELL_RC"
        sed -i.bak '/HOMEBREW_BREW_GIT_REMOTE/d' "$SHELL_RC"
        sed -i.bak '/HOMEBREW_CORE_GIT_REMOTE/d' "$SHELL_RC"
        sed -i.bak '/HOMEBREW_BOTTLE_DOMAIN/d' "$SHELL_RC"
        rm -f "${SHELL_RC}.bak"
        unset HOMEBREW_BREW_GIT_REMOTE HOMEBREW_CORE_GIT_REMOTE HOMEBREW_BOTTLE_DOMAIN
        print_success "Homebrew CN mirrors removed from $SHELL_RC"
    else
        print_info "Homebrew CN mirrors — nothing to restore"
    fi
}

# --------------------------------------------------------------------------
# ensure_homebrew — install Homebrew if missing, add to PATH
# --------------------------------------------------------------------------
ensure_homebrew() {
    if command_exists brew; then
        print_success "Homebrew already installed"
        return 0
    fi

    print_info "Installing Homebrew..."
    local brew_url="$HOMEBREW_INSTALL_SCRIPT_URL"
    [ "$USE_CN_MIRRORS" = true ] && brew_url="$CN_HOMEBREW_INSTALL_SCRIPT_URL"

    if /bin/bash -c "$(curl -fsSL "$brew_url")"; then
        # Add Homebrew to PATH (Apple Silicon default path)
        echo 'export PATH="/opt/homebrew/bin:$PATH"' >> "$SHELL_RC"
        export PATH="/opt/homebrew/bin:$PATH"
        print_success "Homebrew installed"
    else
        print_error "Failed to install Homebrew"
        return 1
    fi
}

_clt_installed() {
    [ -e "/Library/Developer/CommandLineTools/usr/bin/git" ]
}

ensure_xcode_clt() {
    print_step "Checking Xcode Command Line Tools..."
    _clt_installed && { print_success "Xcode CLT already installed"; return 0; }

    print_info "Xcode CLT not found — attempting headless install via softwareupdate..."
    local clt_placeholder="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    touch "$clt_placeholder"

    local clt_label
    clt_label=$(softwareupdate -l 2>/dev/null \
        | grep -B 1 -E 'Command Line Tools' \
        | awk -F'*' '/^ *\*/ {print $2}' \
        | sed -e 's/^ *Label: //' -e 's/^ *//' \
        | sort -V | tail -n1)

    local headless_ok=false
    if [ -n "$clt_label" ]; then
        print_info "Found package: $clt_label"
        if softwareupdate -i "$clt_label" --agree-to-license 2>/dev/null; then
            xcode-select --switch "/Library/Developer/CommandLineTools" 2>/dev/null || true
            headless_ok=true
        elif sudo -n softwareupdate -i "$clt_label" --agree-to-license 2>/dev/null; then
            sudo xcode-select --switch "/Library/Developer/CommandLineTools" 2>/dev/null || true
            headless_ok=true
        fi
    else
        print_warning "softwareupdate could not find a CLT package"
    fi

    rm -f "$clt_placeholder"

    if _clt_installed; then
        print_success "Xcode CLT installed successfully"
        return 0
    fi

    [ "$headless_ok" = false ] && print_warning "Headless install failed (sudo password required or package not found)"
    print_error "Could not install Xcode CLT automatically."
    echo ""
    echo "  Please run this command and re-run this script:"
    echo "    sudo xcode-select --install"
    echo ""
    return 1
}

ensure_linux_deps() {
    print_step "Checking Linux build dependencies..."

    local missing=()
    command_exists gcc     || missing+=("build-essential")
    command_exists python3 || missing+=("python3")
    command_exists git     || missing+=("git")
    command_exists curl    || missing+=("curl")

    if [ ${#missing[@]} -eq 0 ]; then
        print_success "All dependencies already installed"
        return 0
    fi

    print_info "Missing: ${missing[*]}"

    detect_network_region
    setup_apt_mirror
    sudo apt-get install -y "${missing[@]}"
    print_success "Dependencies installed"
}

# --------------------------------------------------------------------------
# Verify key tools are present
# --------------------------------------------------------------------------
verify_deps() {
    print_step "Verifying installed tools..."
    local failed=false
    for tool in python3 git curl make; do
        if command_exists "$tool"; then
            print_success "$tool  $(command -v "$tool")"
        else
            print_warning "$tool  not found"
            failed=true
        fi
    done
    [ "$failed" = true ] && print_warning "Some tools still missing. You may need to restart your shell."
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    echo ""
    echo "System Dependencies Setup"
    echo "========================="

    detect_os
    print_info "OS: $OS"
    [ "$OS" = "Linux" ] && print_info "Distro: $DISTRO"
    echo ""

    assert_supported_os

    case "$OS" in
        macOS)
            detect_shell
            ensure_xcode_clt  || exit 1
            detect_network_region
            configure_homebrew_cn_mirrors
            ensure_homebrew   || exit 1
            ;;
        Linux) ensure_linux_deps || exit 1 ;;
    esac

    verify_deps
    echo ""
    print_success "Done. System dependencies are ready."
    echo ""
}

main "$@"
