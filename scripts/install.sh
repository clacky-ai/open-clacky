#!/bin/bash
# OpenClacky Installation Script
# This script automatically detects your system and installs OpenClacky

set -e

# Brand configuration (populated by --brand-name / --command flags)
BRAND_NAME=""
BRAND_COMMAND=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored messages
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_step() {
    echo -e "\n${BLUE}==>${NC} $1"
}

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)     OS=Linux;;
        Darwin*)    OS=macOS;;
        CYGWIN*)    OS=Windows;;
        MINGW*)     OS=Windows;;
        *)          OS=Unknown;;
    esac
    print_info "Detected OS: $OS"

    # Detect Linux distribution
    if [ "$OS" = "Linux" ]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            DISTRO=$ID
            print_info "Detected Linux distribution: $DISTRO"
        else
            DISTRO=unknown
        fi
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Detect current shell type based on $SHELL environment variable
# Sets CURRENT_SHELL (e.g. "zsh", "bash", "fish") and SHELL_RC (rc file path)
detect_shell() {
    local shell_name
    shell_name=$(basename "$SHELL")

    case "$shell_name" in
        zsh)
            CURRENT_SHELL="zsh"
            SHELL_RC="$HOME/.zshrc"
            ;;
        bash)
            CURRENT_SHELL="bash"
            # macOS uses ~/.bash_profile; Linux uses ~/.bashrc
            if [ "$OS" = "macOS" ]; then
                SHELL_RC="$HOME/.bash_profile"
            else
                SHELL_RC="$HOME/.bashrc"
            fi
            ;;
        fish)
            CURRENT_SHELL="fish"
            SHELL_RC="$HOME/.config/fish/config.fish"
            ;;
        *)
            # Fallback: treat as bash
            CURRENT_SHELL="bash"
            SHELL_RC="$HOME/.bashrc"
            ;;
    esac

    print_info "Detected shell: $CURRENT_SHELL (rc file: $SHELL_RC)"
}

# Network-aware installer source selection
SLOW_THRESHOLD_MS=5000
NETWORK_REGION="global"     # "china" | "global" | "unknown"
USE_CN_MIRRORS=false

# --- Upstream (global) defaults ---
GITHUB_RAW_BASE_URL="https://raw.githubusercontent.com"
HOMEBREW_INSTALL_SCRIPT_URL="${GITHUB_RAW_BASE_URL}/Homebrew/install/HEAD/install.sh"
OPENCLACKY_INSTALL_SCRIPT_URL="${GITHUB_RAW_BASE_URL}/clacky-ai/openclacky/main/scripts/install.sh"
DEFAULT_RUBYGEMS_URL="https://rubygems.org"
DEFAULT_NPM_REGISTRY="https://registry.npmjs.org"
DEFAULT_MISE_INSTALL_URL="https://mise.run"

# --- CN mirror provider ---
# Switch this one line to change gem/npm/Node mirrors all at once.
# Aliyun:   https://mirrors.aliyun.com
# Tsinghua: https://mirrors.tuna.tsinghua.edu.cn
CN_MIRROR_BASE="https://mirrors.aliyun.com"

CN_CDN_BASE_URL="https://oss.1024code.com"

# --- CN source URLs (derived from CN_CDN_BASE_URL / CN_MIRROR_BASE) ---
CN_HOMEBREW_INSTALL_SCRIPT_URL="${CN_CDN_BASE_URL}/Homebrew/install/HEAD/install.sh"
CN_MISE_INSTALL_URL="${CN_CDN_BASE_URL}/mise.sh"
CN_RUBY_PRECOMPILED_URL="${CN_CDN_BASE_URL}/ruby/ruby-{version}.{platform}.tar.gz"
CN_RUBYGEMS_URL="${CN_MIRROR_BASE}/rubygems/"
CN_NPM_REGISTRY="https://registry.npmmirror.com"
CN_NODE_MIRROR_URL="${CN_MIRROR_BASE}/nodejs-release/"

# --- Homebrew CN mirrors (path layout differs per provider, update together) ---
# Aliyun:   base=mirrors.aliyun.com, paths below
# Tsinghua: base=mirrors.tuna.tsinghua.edu.cn, paths: /git/homebrew/brew.git, /homebrew-bottles, (no API domain)
CN_HOMEBREW_BREW_GIT_REMOTE="${CN_MIRROR_BASE}/homebrew/brew.git"
CN_HOMEBREW_CORE_GIT_REMOTE="${CN_MIRROR_BASE}/homebrew/homebrew-core.git"
CN_HOMEBREW_BOTTLE_DOMAIN="${CN_MIRROR_BASE}/homebrew/homebrew-bottles"
CN_HOMEBREW_API_DOMAIN="${CN_MIRROR_BASE}/homebrew-bottles/api"

# --- Active values (overridden by detect_network_region) ---
MISE_INSTALL_URL="$DEFAULT_MISE_INSTALL_URL"
RUBYGEMS_INSTALL_URL="$DEFAULT_RUBYGEMS_URL"
NPM_REGISTRY_URL="$DEFAULT_NPM_REGISTRY"
NODE_MIRROR_URL=""           # empty = mise default (nodejs.org)
RUBY_VERSION_SPEC="ruby@3"

# Probe a single URL; echoes the round-trip time in milliseconds, or "timeout".
_probe_url() {
    local url="$1"
    local timeout_sec=5
    local curl_output http_code total_time elapsed_ms

    curl_output=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
        --connect-timeout "$timeout_sec" \
        --max-time "$timeout_sec" \
        "$url" 2>/dev/null) || true
    http_code="${curl_output%% *}"
    total_time="${curl_output#* }"

    if [ -z "$http_code" ] || [ "$http_code" = "000" ] || [ "$http_code" = "$curl_output" ]; then
        echo "timeout"
    else
        elapsed_ms=$(awk -v seconds="$total_time" 'BEGIN { printf "%d", seconds * 1000 }')
        echo "$elapsed_ms"
    fi
}

_is_timed_result() {
    local result="$1"

    [ -n "$result" ] && [ "$result" != "timeout" ] && [ "$result" -ge 0 ] 2>/dev/null
}

_is_slow_or_unreachable() {
    local result="$1"

    if [ "$result" = "timeout" ]; then
        return 0
    fi

    [ "$result" -ge "$SLOW_THRESHOLD_MS" ] 2>/dev/null
}

_format_probe_time() {
    local result="$1"

    if [ "$result" = "timeout" ]; then
        echo "timeout"
    else
        awk -v ms="$result" 'BEGIN { printf "%.1fs", ms / 1000 }'
    fi
}

_print_probe_result() {
    local label="$1"
    local result="$2"

    if [ "$result" = "timeout" ]; then
        print_warning "UNREACHABLE (${result})  ${label}"
    elif _is_slow_or_unreachable "$result"; then
        print_warning "SLOW ($(_format_probe_time "$result"))  ${label}"
    else
        print_success "OK ($(_format_probe_time "$result"))  ${label}"
    fi
}

# Probe a URL up to MAX_RETRIES times; returns the first successful ms or "timeout".
_probe_url_with_retry() {
    local url="$1"
    local max_retries="${2:-2}"
    local attempt result

    for attempt in $(seq 1 "$max_retries"); do
        result=$(_probe_url "$url")
        if [ "$result" != "timeout" ] && ! _is_slow_or_unreachable "$result"; then
            echo "$result"
            return 0
        fi
        # keep last result for reporting
    done
    echo "$result"
}

detect_network_region() {
    print_step "Network pre-flight check..."
    echo ""

    # -----------------------------------------------------------------------
    # Step 1: Region detection — google.com vs baidu.com
    #   google reachable  → global
    #   google unreachable + baidu reachable → china
    #   both unreachable  → unknown (best-effort, fall through)
    # -----------------------------------------------------------------------
    print_info "Step 1: Detecting network region..."
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
        print_success "Region: global (Google reachable)"
    elif [ "$baidu_ok" = true ]; then
        NETWORK_REGION="china"
        print_success "Region: china (Baidu reachable, Google not)"
    else
        NETWORK_REGION="unknown"
        print_warning "Region: unknown (both Google and Baidu unreachable)"
    fi
    echo ""

    # -----------------------------------------------------------------------
    # Step 2: Probe region-specific sources (retry 2× to avoid false alarms)
    # -----------------------------------------------------------------------
    print_info "Step 2: Probing installation sources (up to 2 retries each)..."

    if [ "$NETWORK_REGION" = "china" ]; then
        # CN sources: Chinese CDN + CN_MIRROR_BASE
        local cdn_result mirror_result
        cdn_result=$(_probe_url_with_retry "$CN_MISE_INSTALL_URL")
        mirror_result=$(_probe_url_with_retry "$CN_MIRROR_BASE")

        _print_probe_result "Chinese CDN (mise/Ruby)" "$cdn_result"
        _print_probe_result "CN mirror (gem/npm/Node/brew)" "$mirror_result"

        local cdn_ok=false mirror_ok=false
        ! _is_slow_or_unreachable "$cdn_result"    && cdn_ok=true
        ! _is_slow_or_unreachable "$mirror_result" && mirror_ok=true

        # Step 3: warn on source failures, but do not abort
        if [ "$cdn_ok" = false ]; then
            print_warning "Chinese CDN is slow/unreachable. mise and Ruby precompiled binaries may fail."
        fi
        if [ "$mirror_ok" = false ]; then
            print_warning "CN mirror (${CN_MIRROR_BASE}) is slow/unreachable. gem/npm/Node installs may be slow."
        fi
        if [ "$cdn_ok" = false ] && [ "$mirror_ok" = false ]; then
            print_warning "All CN mirrors unreachable — falling back to global sources. Expect slow downloads."
        fi

        # Step 4: apply CN sources
        if [ "$cdn_ok" = true ] || [ "$mirror_ok" = true ]; then
            USE_CN_MIRRORS=true
            MISE_INSTALL_URL="$CN_MISE_INSTALL_URL"
            RUBYGEMS_INSTALL_URL="$CN_RUBYGEMS_URL"
            NPM_REGISTRY_URL="$CN_NPM_REGISTRY"
            NODE_MIRROR_URL="$CN_NODE_MIRROR_URL"
            RUBY_VERSION_SPEC="ruby@3.4.8"
            print_info "CN mirrors applied: Chinese CDN (mise/Ruby) + ${CN_MIRROR_BASE} (gem/npm/Node/brew)"
        else
            USE_CN_MIRRORS=false
            print_info "Falling back to global sources despite CN region detection."
        fi

    else
        # Global sources: GitHub / RubyGems / npmjs / mise.run
        local github_result rubygems_result npm_result mise_result
        github_result=$(_probe_url_with_retry "$GITHUB_RAW_BASE_URL")
        rubygems_result=$(_probe_url_with_retry "$DEFAULT_RUBYGEMS_URL")
        npm_result=$(_probe_url_with_retry "$DEFAULT_NPM_REGISTRY")
        mise_result=$(_probe_url_with_retry "$DEFAULT_MISE_INSTALL_URL")

        _print_probe_result "GitHub raw"  "$github_result"
        _print_probe_result "RubyGems"    "$rubygems_result"
        _print_probe_result "npmjs.com"   "$npm_result"
        _print_probe_result "mise.run"    "$mise_result"

        # Step 3: warn on individual source failures
        _is_slow_or_unreachable "$github_result"   && print_warning "GitHub is slow/unreachable. Homebrew and install script updates may fail."
        _is_slow_or_unreachable "$rubygems_result" && print_warning "RubyGems is slow/unreachable. gem install may fail."
        _is_slow_or_unreachable "$npm_result"      && print_warning "npmjs.com is slow/unreachable. npm install may fail."
        _is_slow_or_unreachable "$mise_result"     && print_warning "mise.run is slow/unreachable. mise installation may fail."

        USE_CN_MIRRORS=false
        MISE_INSTALL_URL="$DEFAULT_MISE_INSTALL_URL"
        RUBYGEMS_INSTALL_URL="$DEFAULT_RUBYGEMS_URL"
        NPM_REGISTRY_URL="$DEFAULT_NPM_REGISTRY"
        NODE_MIRROR_URL=""
        RUBY_VERSION_SPEC="ruby@3"
        print_info "Using global upstream sources."
    fi

    echo ""
}


# Compare version strings
version_ge() {
    # Returns 0 (true) if $1 >= $2
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Check Ruby version
check_ruby() {
    if command_exists ruby; then
        RUBY_VERSION=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
        print_info "Found Ruby version: $RUBY_VERSION"

        if version_ge "$RUBY_VERSION" "3.1.0"; then
            print_success "Ruby version is compatible (>= 3.1.0)"
            return 0
        else
            print_warning "Ruby version $RUBY_VERSION is too old (need >= 3.1.0)"
            return 1
        fi
    else
        print_warning "Ruby is not installed"
        return 1
    fi
}

# Configure CN mirrors permanently in config files so all subsequent tool
# invocations (gem, npm, mise) automatically use the right source.
# Called once after detect_network_region, only when USE_CN_MIRRORS=true.
restore_mirrors() {
    print_step "Restoring original mirror settings..."

    # --- gem: restore ~/.gemrc ---
    local gemrc="$HOME/.gemrc"
    local gemrc_bak="$HOME/.gemrc_clackybak"
    if [ -f "$gemrc_bak" ]; then
        mv "$gemrc_bak" "$gemrc"
        print_success "~/.gemrc restored from backup"
    elif [ -f "$gemrc" ]; then
        rm "$gemrc"
        print_success "~/.gemrc removed (gem will use default rubygems.org)"
    else
        print_info "~/.gemrc — nothing to restore"
    fi

    # --- npm: restore ~/.npmrc ---
    local npmrc="$HOME/.npmrc"
    local npmrc_bak="$HOME/.npmrc_clackybak"
    if [ -f "$npmrc_bak" ]; then
        mv "$npmrc_bak" "$npmrc"
        print_success "~/.npmrc restored from backup"
    elif [ -f "$npmrc" ]; then
        rm "$npmrc"
        print_success "~/.npmrc removed (npm will use default registry)"
    else
        print_info "~/.npmrc — nothing to restore"
    fi

    # --- mise: unset node.mirror_url ---
    local mise_bin=""
    if command_exists mise; then
        mise_bin="mise"
    elif [ -x "$HOME/.local/bin/mise" ]; then
        mise_bin="$HOME/.local/bin/mise"
    fi
    if [ -n "$mise_bin" ]; then
        "$mise_bin" settings unset node.mirror_url 2>/dev/null && \
            print_success "mise node.mirror_url unset"
    else
        print_info "mise not found — node.mirror_url skipped"
    fi

    # --- Homebrew CN mirrors: remove from shell rc file ---
    if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ] && grep -q "HOMEBREW_BOTTLE_DOMAIN" "$SHELL_RC" 2>/dev/null; then
        # Remove the comment line and the three export lines added by the installer
        sed -i.bak '/# Homebrew CN mirrors (added by openclacky installer)/d' "$SHELL_RC"
        sed -i.bak '/HOMEBREW_BREW_GIT_REMOTE/d' "$SHELL_RC"
        sed -i.bak '/HOMEBREW_CORE_GIT_REMOTE/d' "$SHELL_RC"
        sed -i.bak '/HOMEBREW_BOTTLE_DOMAIN/d' "$SHELL_RC"
        rm -f "${SHELL_RC}.bak"
        unset HOMEBREW_BREW_GIT_REMOTE HOMEBREW_CORE_GIT_REMOTE HOMEBREW_BOTTLE_DOMAIN
        print_success "Homebrew CN mirrors removed from $SHELL_RC"
    else
        print_info "Homebrew CN mirrors — nothing to restore"
    fi

    echo ""
    print_success "Done. All mirror settings restored to original."
    echo ""
}

configure_cn_mirrors() {
    [ "$USE_CN_MIRRORS" = true ] || return 0

    print_step "Configuring CN mirrors (permanent)..."

    # --- gem: write ~/.gemrc ---
    local gemrc="$HOME/.gemrc"
    if [ -f "$gemrc" ] && grep -q "${CN_RUBYGEMS_URL}" "$gemrc" 2>/dev/null; then
        # Already configured by us — leave it alone
        print_success "gem source already set → ${CN_RUBYGEMS_URL}  (~/.gemrc)"
    else
        # Existing file with different content — back it up then generate a clean one
        if [ -f "$gemrc" ]; then
            mv "$gemrc" "$HOME/.gemrc_clackybak"
            print_info "Backed up existing ~/.gemrc → ~/.gemrc_clackybak"
        fi
        cat > "$gemrc" <<GEMRC
:sources:
  - ${CN_RUBYGEMS_URL}
GEMRC
        print_success "gem source → ${CN_RUBYGEMS_URL}  (~/.gemrc)"
    fi

    # --- npm: write ~/.npmrc ---
    local npmrc="$HOME/.npmrc"
    local npmrc_bak="$HOME/.npmrc_clackybak"
    if [ -f "$npmrc" ] && grep -q "${NPM_REGISTRY_URL}" "$npmrc" 2>/dev/null; then
        # Already configured by us — leave it alone
        print_success "npm registry already set → ${NPM_REGISTRY_URL}  (~/.npmrc)"
    else
        # Back up existing file (once), then write clean config
        if [ -f "$npmrc" ] && [ ! -f "$npmrc_bak" ]; then
            cp "$npmrc" "$npmrc_bak"
            print_info "Backed up existing ~/.npmrc → ~/.npmrc_clackybak"
        fi
        if command_exists npm; then
            npm config set registry "$NPM_REGISTRY_URL" 2>/dev/null && \
                print_success "npm registry → ${NPM_REGISTRY_URL}  (~/.npmrc)"
        else
            echo "registry=${NPM_REGISTRY_URL}" >> "$npmrc"
            print_success "npm registry → ${NPM_REGISTRY_URL}  (~/.npmrc, pre-set)"
        fi
    fi

    # --- mise Node mirror ---
    # Applied inside install_mise_runtime() after mise binary is available.
    # NODE_MIRROR_URL is already set; nothing to do here.

    echo ""
}

# Install via RubyGems
install_via_gem() {
    print_step "Installing via RubyGems..."

    if ! command_exists gem; then
        print_error "RubyGems is not available"
        return 1
    fi

    # Enforce Ruby >= 3.1.0 before attempting gem install
    if ! command_exists ruby; then
        print_error "Ruby is not available"
        return 1
    fi
    RUBY_VERSION=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
    if ! version_ge "$RUBY_VERSION" "3.1.0"; then
        print_error "Ruby $RUBY_VERSION is too old (>= 3.1.0 required)"
        return 1
    fi

    print_info "Installing ${DISPLAY_NAME}..."
    gem install openclacky --no-document

    if [ $? -eq 0 ]; then
        print_success "${DISPLAY_NAME} installed successfully!"
        install_chrome_devtools_mcp
        return 0
    else
        print_error "Gem installation failed"
        return 1
    fi
}

# Install mise for Ruby version management
install_mise_runtime() {
    print_info "Installing mise..."
    if ! command_exists mise; then
        if curl -fsSL "$MISE_INSTALL_URL" | sh; then
            # Add mise activation to the current shell's rc file
            local mise_init_line='eval "$(~/.local/bin/mise activate '"$CURRENT_SHELL"')"'
            if [ -f "$SHELL_RC" ]; then
                echo "$mise_init_line" >> "$SHELL_RC"
            else
                echo "$mise_init_line" > "$SHELL_RC"
            fi
            print_info "Added mise activation to $SHELL_RC"

            export PATH="$HOME/.local/bin:$PATH"
            # Always activate using bash syntax here (this script runs under bash)
            eval "$(~/.local/bin/mise activate bash)"

            print_success "mise installed successfully"
        else
            print_error "Failed to install mise"
            return 1
        fi
    else
        print_success "mise already installed"
    fi

    # Apply CN Node mirror permanently — covers any future `mise install node` too.
    if [ "$USE_CN_MIRRORS" = true ] && [ -n "$NODE_MIRROR_URL" ]; then
        ~/.local/bin/mise settings node.mirror_url="$NODE_MIRROR_URL" 2>/dev/null || true
        print_info "mise Node mirror → ${NODE_MIRROR_URL}"
    fi
}

install_ruby_via_mise() {
    if check_ruby; then
        print_success "Ruby already installed and compatible — skipping Ruby installation"
        return 0
    fi

    print_info "Installing Ruby 3 via mise..."

    if [ "$USE_CN_MIRRORS" = true ]; then
        ~/.local/bin/mise settings ruby.compile=false
        ~/.local/bin/mise settings ruby.precompiled_url="$CN_RUBY_PRECOMPILED_URL"
    else
        ~/.local/bin/mise settings unset ruby.compile >/dev/null 2>&1 || true
        ~/.local/bin/mise settings unset ruby.precompiled_url >/dev/null 2>&1 || true
    fi

    if ~/.local/bin/mise use -g "$RUBY_VERSION_SPEC"; then
        eval "$(~/.local/bin/mise activate bash)"
        print_success "Ruby 3 installed successfully"
    else
        print_error "Failed to install Ruby 3"
        return 1
    fi
}

# Install dependencies and Ruby on macOS
install_macos_dependencies() {
    print_step "Installing macOS dependencies and Ruby..."
    echo ""

    # Configure Homebrew CN mirrors before installing (CN mode only)
    if [ "$USE_CN_MIRRORS" = true ]; then
        print_info "Configuring Homebrew CN mirrors..."
        export HOMEBREW_INSTALL_FROM_API=1
        export HOMEBREW_API_DOMAIN="$CN_HOMEBREW_API_DOMAIN"
        export HOMEBREW_BREW_GIT_REMOTE="$CN_HOMEBREW_BREW_GIT_REMOTE"
        export HOMEBREW_CORE_GIT_REMOTE="$CN_HOMEBREW_CORE_GIT_REMOTE"
        export HOMEBREW_BOTTLE_DOMAIN="$CN_HOMEBREW_BOTTLE_DOMAIN"

        # Persist to shell rc file
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
    fi

    # Install Homebrew (it will automatically install Xcode Command Line Tools if needed)
    print_info "Checking Homebrew installation..."
    if ! command_exists brew; then
        print_info "Installing Homebrew..."
        local brew_install_url="$HOMEBREW_INSTALL_SCRIPT_URL"
        if [ "$USE_CN_MIRRORS" = true ]; then
            brew_install_url="$CN_HOMEBREW_INSTALL_SCRIPT_URL"
        fi
        /bin/bash -c "$(curl -fsSL "$brew_install_url")"

        # Add Homebrew to PATH
        echo 'export PATH="/opt/homebrew/bin:$PATH"' >> "$SHELL_RC"
        export PATH="/opt/homebrew/bin:$PATH"

        print_success "Homebrew installed successfully"
    else
        print_success "Homebrew already installed"
    fi

    # Install build dependencies
    print_info "Installing build dependencies..."
    if brew install openssl@3 libyaml gmp; then
        print_success "Build dependencies installed"
    else
        print_error "Failed to install build dependencies"
        return 1
    fi

    # Install mise for Ruby version management
    # Detect current shell before configuring mise
    detect_shell

    if ! install_mise_runtime; then
        return 1
    fi

    if ! install_ruby_via_mise; then
        return 1
    fi

    # Verify Ruby installation
    if check_ruby; then
        return 0
    else
        print_error "Ruby installation verification failed"
        return 1
    fi
}

# Install dependencies and Ruby on Ubuntu/Debian
install_ubuntu_dependencies() {
    print_step "Installing Ubuntu dependencies and Ruby..."
    echo ""

    if [ "$USE_CN_MIRRORS" = true ]; then
        print_info "Configuring apt mirror (${CN_MIRROR_BASE})..."
        local codename="${VERSION_CODENAME:-jammy}"
        local mirror_base="${CN_MIRROR_BASE}/ubuntu/"
        local common_components="main restricted universe multiverse"
        sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb ${mirror_base} ${codename} ${common_components}
deb ${mirror_base} ${codename}-updates ${common_components}
deb ${mirror_base} ${codename}-backports ${common_components}
deb ${mirror_base} ${codename}-security ${common_components}
EOF
        print_success "Mirror configured"
    else
        print_info "Using default apt sources"
    fi

    # Update package list
    print_info "Updating package list..."
    if sudo apt update; then
        print_success "Package list updated"
    else
        print_error "Failed to update package list"
        return 1
    fi

    # Install build dependencies
    print_info "Installing build dependencies..."
    if sudo apt install -y build-essential libssl-dev libyaml-dev zlib1g-dev libgmp-dev git; then
        print_success "Build dependencies installed"
    else
        print_error "Failed to install build dependencies"
        return 1
    fi

    # Detect current shell before configuring mise
    detect_shell

    # In WSL, Windows paths (e.g. /mnt/c/Windows/system32) are appended to PATH.
    # mise scans PATH directories for mise.toml and errors on untrusted files found there.
    # Auto-trust the Windows system32 directory to suppress those errors.
    export MISE_TRUSTED_CONFIG_PATHS="/mnt/c/Windows/system32"

    # Install mise for Ruby version management
    if ! install_mise_runtime; then
        return 1
    fi

    if ! install_ruby_via_mise; then
        return 1
    fi

    # Verify Ruby installation
    if check_ruby; then
        return 0
    else
        print_error "Ruby installation verification failed"
        return 1
    fi
}

# Suggest Ruby installation
# Parse command-line arguments.
#
# Supported flags:
#   --brand-name=VALUE   Human-readable brand name (e.g. "JohnAI")
#   --command=VALUE      CLI command to install as a wrapper (e.g. "johncli")
#
# Usage from install command:
#   /bin/bash -c "$(curl -sSL .../install.sh)" -- --brand-name="JohnAI" --command="johncli"
#
# Note: bash -c passes positional args starting at $0, so real flags are in $@
# when invoked with the `--` separator; they land in $1..$N of the script.
parse_args() {
    for arg in "$0" "$@"; do
        case "$arg" in
            --brand-name=*)
                BRAND_NAME="${arg#--brand-name=}"
                ;;
            --command=*)
                BRAND_COMMAND="${arg#--command=}"
                ;;
            --restore-mirrors)
                RESTORE_MIRRORS=true
                ;;
        esac
    done
    # Global display name: brand name if provided, otherwise fall back to OpenClacky
    DISPLAY_NAME="${BRAND_NAME:-OpenClacky}"
}

# Write brand configuration and install the wrapper command.
#
# Creates ~/.clacky/brand.yml with brand metadata and, if a custom command
# name was requested, installs a thin wrapper script at ~/.local/bin/<command>
# that simply delegates to openclacky.
setup_brand() {
    [ -z "$BRAND_NAME" ] && return 0

    local clacky_dir="$HOME/.clacky"
    local brand_file="$clacky_dir/brand.yml"
    mkdir -p "$clacky_dir"

    print_step "Configuring brand: $BRAND_NAME"

    # Write brand.yml — minimal entry; license_key is filled in later via
    # the CLI or WebUI activation flow.
    cat > "$brand_file" <<YAML
product_name: "${BRAND_NAME}"
package_name: "${BRAND_COMMAND}"
YAML

    print_success "Brand configuration written to $brand_file"

    # Install wrapper command if a custom command name was provided.
    if [ -n "$BRAND_COMMAND" ]; then
        local bin_dir="$HOME/.local/bin"
        mkdir -p "$bin_dir"

        local wrapper="$bin_dir/$BRAND_COMMAND"
        cat > "$wrapper" <<WRAPPER
#!/bin/sh
exec openclacky "\$@"
WRAPPER
        chmod +x "$wrapper"
        print_success "Wrapper command installed: $wrapper"

        # Remind user to add ~/.local/bin to PATH if needed.
        case ":$PATH:" in
            *":$bin_dir:"*) ;;
            *)
                print_warning "Add the following to your shell profile so '$BRAND_COMMAND' is available:"
                echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
                ;;
        esac
    fi
}

# Main installation logic
main() {
    parse_args "$@"

    # --restore-mirrors: undo CN mirror config and exit
    if [ "${RESTORE_MIRRORS:-false}" = true ]; then
        restore_mirrors
        exit 0
    fi

    echo ""
    echo "${DISPLAY_NAME} Installation"
    echo ""

    detect_os
    detect_shell
    detect_network_region
    configure_cn_mirrors

    # Install dependencies and Ruby (always run, handles already-installed gracefully)
    if [ "$OS" = "macOS" ]; then
        if ! install_macos_dependencies; then
            print_error "Failed to install dependencies"
            exit 1
        fi
    elif [ "$OS" = "Linux" ]; then
        if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
            if ! install_ubuntu_dependencies; then
                print_error "Failed to install dependencies"
                exit 1
            fi
        else
            print_error "Unsupported Linux distribution: $DISTRO"
            print_info "Please install Ruby manually and run: gem install openclacky"
            exit 1
        fi
    else
        print_error "Unsupported OS: $OS"
        print_info "Please install Ruby manually and run: gem install openclacky"
        exit 1
    fi

    # Install via gem
    if install_via_gem; then
        setup_brand
        show_post_install_info
        exit 0
    else
        print_error "Failed to install ${DISPLAY_NAME}"
        exit 1
    fi
}

# Install agent-browser (browser automation tool)
# This step is optional — failures are silently skipped with a hint.
install_chrome_devtools_mcp() {
    print_step "Installing chrome-devtools-mcp..."

    if ! command_exists npm; then
        local mise_bin=""
        if command_exists mise; then
            mise_bin="mise"
        elif [ -x "$HOME/.local/bin/mise" ]; then
            mise_bin="$HOME/.local/bin/mise"
        fi

        if [ -n "$mise_bin" ]; then
            print_info "Installing Node.js via mise..."
            "$mise_bin" install node@22 > /dev/null 2>&1 || true
            "$mise_bin" use -g node@22 > /dev/null 2>&1 || true
            eval "$("$mise_bin" activate bash 2>/dev/null)" 2>/dev/null || true
        fi
    else
        print_success "Node.js already installed — $(node --version 2>/dev/null)"
    fi

    if ! command_exists npm; then
        print_warning "Node.js/npm not found. Browser automation will not be available."
        print_info "To enable browser support, install Node.js and run: npm install -g chrome-devtools-mcp"
        return 0
    fi

    if npm install -g chrome-devtools-mcp > /dev/null 2>&1; then
        print_success "chrome-devtools-mcp installed"
    else
        print_warning "chrome-devtools-mcp installation failed. Browser automation may not work."
        print_info "To install manually: npm install -g chrome-devtools-mcp"
    fi
}

# Post-installation information
show_post_install_info() {
    local cmd="${BRAND_COMMAND:-openclacky}"

    echo ""
    echo -e "  ${GREEN}${DISPLAY_NAME} installed successfully!${NC}"
    echo ""
    echo "  First, reload your shell environment:"
    echo ""
    echo -e "    ${YELLOW}source ${SHELL_RC}${NC}"
    echo ""
    echo "  Then pick how you want to start:"
    echo ""
    echo -e "  ${GREEN}Web UI${NC} (recommended):"
    echo "    $cmd server"
    echo "    Open http://localhost:7070 in your browser"
    echo ""
    echo -e "  ${GREEN}Terminal mode${NC}:"
    echo "    $cmd"
    echo ""
}

# Run main installation
main "$@"
