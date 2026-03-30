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

# Detect current shell type
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
            CURRENT_SHELL="bash"
            SHELL_RC="$HOME/.bashrc"
            ;;
    esac

    print_info "Detected shell: $CURRENT_SHELL (rc file: $SHELL_RC)"
}

# --------------------------------------------------------------------------
# Network region detection & mirror selection
# --------------------------------------------------------------------------
SLOW_THRESHOLD_MS=5000
NETWORK_REGION="global"
USE_CN_MIRRORS=false

GITHUB_RAW_BASE_URL="https://raw.githubusercontent.com"
DEFAULT_RUBYGEMS_URL="https://rubygems.org"
DEFAULT_MISE_INSTALL_URL="https://mise.run"

CN_CDN_BASE_URL="https://oss.1024code.com"
CN_MISE_INSTALL_URL="${CN_CDN_BASE_URL}/mise.sh"
CN_RUBY_PRECOMPILED_URL="${CN_CDN_BASE_URL}/ruby/ruby-{version}.{platform}.tar.gz"
CN_RUBYGEMS_URL="https://mirrors.aliyun.com/rubygems/"
CN_GEM_BASE_URL="${CN_CDN_BASE_URL}/openclacky"
CN_GEM_LATEST_URL="${CN_GEM_BASE_URL}/latest.txt"

# Active values (overridden by detect_network_region)
MISE_INSTALL_URL="$DEFAULT_MISE_INSTALL_URL"
RUBYGEMS_INSTALL_URL="$DEFAULT_RUBYGEMS_URL"
RUBY_VERSION_SPEC="ruby@3"   # mise will pick latest stable

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
        print_warning "UNREACHABLE  ${label}"
    elif _is_slow_or_unreachable "$result"; then
        print_warning "SLOW ($(_format_probe_time "$result"))  ${label}"
    else
        print_success "OK ($(_format_probe_time "$result"))  ${label}"
    fi
}

_probe_url_with_retry() {
    local url="$1"
    local max_retries="${2:-2}"
    local result

    for _ in $(seq 1 "$max_retries"); do
        result=$(_probe_url "$url")
        if ! _is_slow_or_unreachable "$result"; then
            echo "$result"
            return 0
        fi
    done
    echo "$result"
}

detect_network_region() {
    print_step "Network pre-flight check..."
    echo ""

    print_info "Detecting network region..."
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
            RUBY_VERSION_SPEC="ruby@3.4.8"
            print_info "CN mirrors applied."
        else
            print_warning "CN mirrors unreachable — falling back to global sources."
        fi
    else
        local rubygems_result mise_result
        rubygems_result=$(_probe_url_with_retry "$DEFAULT_RUBYGEMS_URL")
        mise_result=$(_probe_url_with_retry "$DEFAULT_MISE_INSTALL_URL")

        _print_probe_result "RubyGems" "$rubygems_result"
        _print_probe_result "mise.run" "$mise_result"

        _is_slow_or_unreachable "$rubygems_result" && print_warning "RubyGems is slow/unreachable."
        _is_slow_or_unreachable "$mise_result"     && print_warning "mise.run is slow/unreachable."
    fi

    echo ""
}

# --------------------------------------------------------------------------
# Version comparison
# --------------------------------------------------------------------------
version_ge() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# --------------------------------------------------------------------------
# Ruby check (>= 2.6.0)
# --------------------------------------------------------------------------
check_ruby() {
    if command_exists ruby; then
        RUBY_VERSION=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
        print_info "Found Ruby $RUBY_VERSION"

        if version_ge "$RUBY_VERSION" "2.6.0"; then
            print_success "Ruby $RUBY_VERSION is compatible (>= 2.6.0)"
            return 0
        else
            print_warning "Ruby $RUBY_VERSION is too old (need >= 2.6.0)"
            return 1
        fi
    else
        print_warning "Ruby not found"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Configure gem source (CN mirror if needed)
# --------------------------------------------------------------------------
configure_gem_source() {
    local gemrc="$HOME/.gemrc"

    if [ "$USE_CN_MIRRORS" = true ]; then
        # CN: point gem source to Aliyun mirror
        if [ -f "$gemrc" ] && grep -q "${CN_RUBYGEMS_URL}" "$gemrc" 2>/dev/null; then
            print_success "gem source already → ${CN_RUBYGEMS_URL}"
        else
            [ -f "$gemrc" ] && mv "$gemrc" "$HOME/.gemrc_clackybak"
            cat > "$gemrc" <<GEMRC
:sources:
  - ${CN_RUBYGEMS_URL}
GEMRC
            print_success "gem source → ${CN_RUBYGEMS_URL}"
        fi
    else
        # Global: restore original gemrc if we were the ones who changed it
        if [ -f "$gemrc" ] && grep -q "${CN_RUBYGEMS_URL}" "$gemrc" 2>/dev/null; then
            if [ -f "$HOME/.gemrc_clackybak" ]; then
                mv "$HOME/.gemrc_clackybak" "$gemrc"
                print_info "gem source restored from backup"
            else
                rm "$gemrc"
                print_info "gem source restored to default"
            fi
        fi
    fi
}

# --------------------------------------------------------------------------
# mise: install (if missing) and optionally activate
# --------------------------------------------------------------------------
install_mise() {
    if ! command_exists mise && [ ! -x "$HOME/.local/bin/mise" ]; then
        print_info "Installing mise..."
        if curl -fsSL "$MISE_INSTALL_URL" | sh; then
            # Add mise activation to shell rc
            local mise_init_line='eval "$(~/.local/bin/mise activate '"$CURRENT_SHELL"')"'
            if [ -f "$SHELL_RC" ]; then
                echo "$mise_init_line" >> "$SHELL_RC"
            else
                echo "$mise_init_line" > "$SHELL_RC"
            fi
            print_info "Added mise activation to $SHELL_RC"
            export PATH="$HOME/.local/bin:$PATH"
            eval "$(~/.local/bin/mise activate bash)"
            print_success "mise installed"
        else
            print_error "Failed to install mise"
            return 1
        fi
    else
        export PATH="$HOME/.local/bin:$PATH"
        eval "$(~/.local/bin/mise activate bash)" 2>/dev/null || true
        print_success "mise already installed"
    fi
}

# --------------------------------------------------------------------------
# Install Ruby via mise (precompiled when CN mirrors active)
# --------------------------------------------------------------------------
install_ruby_via_mise() {
    print_info "Installing Ruby via mise ($RUBY_VERSION_SPEC)..."

    if [ "$USE_CN_MIRRORS" = true ]; then
        ~/.local/bin/mise settings ruby.compile=false
        ~/.local/bin/mise settings ruby.precompiled_url="$CN_RUBY_PRECOMPILED_URL"
        print_info "Using precompiled Ruby from CN CDN"
    else
        ~/.local/bin/mise settings unset ruby.compile       >/dev/null 2>&1 || true
        ~/.local/bin/mise settings unset ruby.precompiled_url >/dev/null 2>&1 || true
    fi

    if ~/.local/bin/mise use -g "$RUBY_VERSION_SPEC"; then
        eval "$(~/.local/bin/mise activate bash)"
        print_success "Ruby installed via mise"
    else
        print_error "Failed to install Ruby via mise"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Ensure Ruby >= 2.6 is available (install if needed)
# --------------------------------------------------------------------------
ensure_ruby() {
    print_step "Checking Ruby..."

    if check_ruby; then
        return 0
    fi

    # No suitable Ruby — install via mise
    print_step "Installing Ruby via mise..."
    detect_shell

    if ! install_mise; then
        return 1
    fi

    if ! install_ruby_via_mise; then
        return 1
    fi

    # Verify
    if check_ruby; then
        return 0
    else
        print_error "Ruby installation verification failed"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Linux: install build deps before mise/Ruby (compile fallback)
# --------------------------------------------------------------------------
install_linux_build_deps() {
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        print_step "Installing build dependencies..."

        if [ "$USE_CN_MIRRORS" = true ]; then
            print_info "Configuring apt mirror (Aliyun)..."
            local codename="${VERSION_CODENAME:-jammy}"
            local mirror_base="https://mirrors.aliyun.com/ubuntu/"
            local components="main restricted universe multiverse"
            sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb ${mirror_base} ${codename} ${components}
deb ${mirror_base} ${codename}-updates ${components}
deb ${mirror_base} ${codename}-backports ${components}
deb ${mirror_base} ${codename}-security ${components}
EOF
        fi

        sudo apt update
        sudo apt install -y build-essential libssl-dev libyaml-dev zlib1g-dev libgmp-dev git
        print_success "Build dependencies installed"
    fi
}

# --------------------------------------------------------------------------
# Set GEM_HOME to user directory when system Ruby gem dir is not writable
# (avoids needing sudo for gem install)
# --------------------------------------------------------------------------
setup_gem_home() {
    local gem_dir
    gem_dir=$(gem environment gemdir 2>/dev/null || true)

    # Gem dir is writable (e.g. mise-managed Ruby) — nothing to do
    if [ -w "$gem_dir" ]; then
        return 0
    fi

    # System Ruby: redirect gems to ~/.gem/ruby/<api_version>
    local ruby_api
    ruby_api=$(ruby -e 'puts RbConfig::CONFIG["ruby_version"]' 2>/dev/null)

    export GEM_HOME="$HOME/.gem/ruby/${ruby_api}"
    export GEM_PATH="$HOME/.gem/ruby/${ruby_api}"
    export PATH="$HOME/.gem/ruby/${ruby_api}/bin:$PATH"

    print_info "System Ruby detected — gems will install to ~/.gem/ruby/${ruby_api}"

    # Persist to shell rc (use $HOME so the line is portable)
    if [ -n "$SHELL_RC" ] && ! grep -q "GEM_HOME" "$SHELL_RC" 2>/dev/null; then
        {
            echo ""
            echo "# Ruby user gem dir (added by openclacky installer)"
            echo "export GEM_HOME=\"\$HOME/.gem/ruby/${ruby_api}\""
            echo "export GEM_PATH=\"\$HOME/.gem/ruby/${ruby_api}\""
            echo "export PATH=\"\$HOME/.gem/ruby/${ruby_api}/bin:\$PATH\""
        } >> "$SHELL_RC"
        print_info "GEM_HOME written to $SHELL_RC"
    fi
}

# --------------------------------------------------------------------------
# gem install openclacky
# --------------------------------------------------------------------------
install_via_gem() {
    print_step "Installing ${DISPLAY_NAME} via gem..."

    configure_gem_source
    setup_gem_home

    if [ "$USE_CN_MIRRORS" = true ]; then
        # CN: download .gem from OSS, install dependencies from Aliyun mirror
        print_info "Fetching latest version from OSS..."
        local cn_version
        cn_version=$(curl -fsSL "$CN_GEM_LATEST_URL" | tr -d '[:space:]')
        print_info "Latest version: ${cn_version}"

        local gem_url="${CN_GEM_BASE_URL}/openclacky-${cn_version}.gem"
        local gem_file="/tmp/openclacky-${cn_version}.gem"
        print_info "Downloading openclacky-${cn_version}.gem from OSS..."
        curl -fsSL "$gem_url" -o "$gem_file"
        print_info "Installing gem and dependencies from Aliyun mirror..."
        gem install "$gem_file" --no-document --source "$CN_RUBYGEMS_URL"
    else
        print_info "Installing gem and dependencies from RubyGems..."
        gem install openclacky --no-document
    fi

    if [ $? -eq 0 ]; then
        print_success "${DISPLAY_NAME} installed successfully!"
        return 0
    else
        print_error "gem install failed"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Parse CLI args
# --------------------------------------------------------------------------
parse_args() {
    for arg in "$0" "$@"; do
        case "$arg" in
            --brand-name=*)
                BRAND_NAME="${arg#--brand-name=}"
                ;;
            --command=*)
                BRAND_COMMAND="${arg#--command=}"
                ;;
        esac
    done
    DISPLAY_NAME="${BRAND_NAME:-OpenClacky}"
}

# --------------------------------------------------------------------------
# Brand setup
# --------------------------------------------------------------------------
setup_brand() {
    [ -z "$BRAND_NAME" ] && return 0

    local clacky_dir="$HOME/.clacky"
    local brand_file="$clacky_dir/brand.yml"
    mkdir -p "$clacky_dir"

    print_step "Configuring brand: $BRAND_NAME"

    cat > "$brand_file" <<YAML
product_name: "${BRAND_NAME}"
package_name: "${BRAND_COMMAND}"
YAML
    print_success "Brand config written to $brand_file"

    if [ -n "$BRAND_COMMAND" ]; then
        # Install wrapper in the same directory as the openclacky binary so it is
        # always on PATH regardless of whether we are running as root or a normal user.
        local clacky_bin bin_dir
        clacky_bin=$(command -v openclacky 2>/dev/null || true)
        if [ -n "$clacky_bin" ]; then
            bin_dir=$(dirname "$clacky_bin")
        else
            print_warning "openclacky binary not found in PATH; skipping wrapper install"
            return 0
        fi

        local wrapper="$bin_dir/$BRAND_COMMAND"
        cat > "$wrapper" <<WRAPPER
#!/bin/sh
exec openclacky "\$@"
WRAPPER
        chmod +x "$wrapper"
        print_success "Wrapper installed: $wrapper"
    fi
}

# --------------------------------------------------------------------------
# Post-install info
# --------------------------------------------------------------------------
show_post_install_info() {
    local cmd="${BRAND_COMMAND:-openclacky}"

    echo ""
    echo -e "  ${GREEN}${DISPLAY_NAME} installed successfully!${NC}"
    echo ""
    echo "  Reload your shell:"
    echo ""
    echo -e "    ${YELLOW}source ${SHELL_RC}${NC}"
    echo ""
    echo -e "  ${GREEN}Web UI${NC} (recommended):"
    echo "    $cmd server"
    echo "    Open http://localhost:7070"
    echo ""
    echo -e "  ${GREEN}Terminal${NC}:"
    echo "    $cmd"
    echo ""
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo ""
    echo "${DISPLAY_NAME} Installation"
    echo ""

    detect_os
    detect_shell
    detect_network_region

    # Linux: install build deps first (needed if mise has to compile Ruby)
    if [ "$OS" = "Linux" ]; then
        if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
            install_linux_build_deps
        else
            print_error "Unsupported Linux distribution: $DISTRO"
            print_info "Please install Ruby >= 2.6.0 manually and run: gem install openclacky"
            exit 1
        fi
    elif [ "$OS" != "macOS" ]; then
        print_error "Unsupported OS: $OS"
        print_info "Please install Ruby >= 2.6.0 manually and run: gem install openclacky"
        exit 1
    fi

    if ! ensure_ruby; then
        print_error "Could not install a compatible Ruby"
        exit 1
    fi

    if install_via_gem; then
        setup_brand
        show_post_install_info
        exit 0
    else
        print_error "Failed to install ${DISPLAY_NAME}"
        exit 1
    fi
}

main "$@"
