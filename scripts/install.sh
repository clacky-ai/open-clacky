#!/bin/bash
# install.sh — OpenClacky installer
# Generated from scripts/build/src/install.sh.cc — DO NOT EDIT DIRECTLY

set -e

# Brand configuration (populated by --brand-name / --command flags)
BRAND_NAME=""
BRAND_COMMAND=""


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


# ---[ @include lib/apt.sh ]---

# Configure apt mirror for CN region and run apt-get update.
# Guards: only runs on ubuntu/debian ($DISTRO).
# Relies on $USE_CN_MIRRORS set by detect_network_region (network.sh).
setup_apt_mirror() {
    [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ] || return 0

    if [ "$USE_CN_MIRRORS" = true ]; then
        print_info "Region: China — configuring Aliyun apt mirror"

        if [ -f /etc/apt/sources.list ]; then
            sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
            print_info "Backed up /etc/apt/sources.list to sources.list.bak"
        fi

        if [ "$DISTRO" = "debian" ]; then
            local codename="${VERSION_CODENAME:-bookworm}"
            local components="main contrib non-free non-free-firmware"
            local mirror="${CN_ALIYUN_MIRROR}/debian/"
            local security_mirror="${CN_ALIYUN_MIRROR}/debian-security/"
            sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb ${mirror} ${codename} ${components}
deb ${mirror} ${codename}-updates ${components}
deb ${mirror} ${codename}-backports ${components}
deb ${security_mirror} ${codename}-security ${components}
EOF
        else
            local codename="${VERSION_CODENAME:-jammy}"
            local components="main restricted universe multiverse"
            local arch; arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
            if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
                local mirror="${CN_ALIYUN_MIRROR}/ubuntu-ports/"
            else
                local mirror="${CN_ALIYUN_MIRROR}/ubuntu/"
            fi
            sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb ${mirror} ${codename} ${components}
deb ${mirror} ${codename}-updates ${components}
deb ${mirror} ${codename}-backports ${components}
deb ${mirror} ${codename}-security ${components}
EOF
        fi

        print_success "apt mirror set to Aliyun"
    else
        print_info "Region: global — using default apt sources"
    fi

    sudo apt-get update -qq
    print_success "apt updated"
}



# ---[ @include lib/gem.sh ]---

configure_gem_source() {
    local gemrc="$HOME/.gemrc"

    if [ "$USE_CN_MIRRORS" = true ]; then
        if grep -q "${CN_RUBYGEMS_URL}" "$gemrc" 2>/dev/null; then
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

restore_gemrc() {
    local gemrc="$HOME/.gemrc"
    local gemrc_bak="$HOME/.gemrc_clackybak"
    if [ -f "$gemrc_bak" ]; then
        mv "$gemrc_bak" "$gemrc"
        print_success "~/.gemrc restored from backup"
    elif [ -f "$gemrc" ]; then
        rm "$gemrc"
        print_success "~/.gemrc removed"
    else
        print_info "~/.gemrc — nothing to restore"
    fi
}

# --------------------------------------------------------------------------
# Redirect GEM_HOME to user dir when system Ruby gem dir is not writable
# --------------------------------------------------------------------------
setup_gem_home() {
    local gem_dir
    gem_dir=$(gem environment gemdir 2>/dev/null || true)
    [ -w "$gem_dir" ] && return 0

    local ruby_api
    ruby_api=$(ruby -e 'puts RbConfig::CONFIG["ruby_version"]' 2>/dev/null)
    export GEM_HOME="$HOME/.gem/ruby/${ruby_api}"
    export GEM_PATH="$HOME/.gem/ruby/${ruby_api}"
    export PATH="$HOME/.gem/ruby/${ruby_api}/bin:$PATH"
    print_info "System Ruby detected — gems will install to ~/.gem/ruby/${ruby_api}"

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

restore_gem_home() {
    [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ] || return 0
    grep -q "GEM_HOME" "$SHELL_RC" 2>/dev/null || return 0
    # Remove the block written by setup_gem_home (comment + 3 export lines)
    local tmp
    tmp=$(mktemp)
    grep -v "# Ruby user gem dir (added by openclacky installer)" "$SHELL_RC" \
        | grep -v "export GEM_HOME=" \
        | grep -v "export GEM_PATH=" \
        | grep -v "/.gem/ruby/" \
        > "$tmp" && mv "$tmp" "$SHELL_RC"
    print_success "GEM_HOME removed from $SHELL_RC"
}


# --------------------------------------------------------------------------
# Ensure Ruby >= 2.6 is available
# macOS: uses system Ruby or user-installed Ruby
# Linux: tries apt first; if missing or too old, prints manual install hint
# --------------------------------------------------------------------------
check_ruby() {
    command_exists ruby || return 1
    local ver; ver=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
    version_ge "$ver" "2.6.0" && { print_success "Ruby $ver — OK"; return 0; }
    print_warning "Ruby $ver too old (need >= 2.6.0)"; return 1
}

ensure_ruby() {
    print_step "Checking Ruby..."
    check_ruby && return 0

    if is_linux_apt; then
        print_info "Installing Ruby via apt..."
        sudo apt-get install -y ruby ruby-dev 2>/dev/null && check_ruby && return 0
        print_warning "apt Ruby install failed or version too old"
    fi

    return 1
}

# --------------------------------------------------------------------------
# gem install openclacky
# --------------------------------------------------------------------------
install_via_gem() {
    print_step "Installing ${DISPLAY_NAME} via gem..."
    configure_gem_source
    setup_gem_home

    local target source_args=()
    if [ "$USE_CN_MIRRORS" = true ]; then
        print_info "Fetching latest version from OSS..."
        local cn_version; cn_version=$(curl -fsSL "$CN_GEM_LATEST_URL" | tr -d '[:space:]')
        print_info "Latest version: ${cn_version}"
        local gem_url="${CN_GEM_BASE_URL}/openclacky-${cn_version}.gem"
        local gem_file="/tmp/openclacky-${cn_version}.gem"
        print_info "Downloading openclacky-${cn_version}.gem..."
        curl -fsSL "$gem_url" -o "$gem_file"
        target="$gem_file"
        source_args=(--source "$CN_RUBYGEMS_URL")
    else
        target="openclacky"
    fi

    # macOS system Ruby 2.6 has a buggy gem resolver that fails on rouge 4.x.
    # Pre-install a 2.6-compatible rouge to avoid resolver failure.
    local ruby_ver; ruby_ver=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null)
    if [[ "$ruby_ver" == 2.6.* ]]; then
        print_warning "Ruby 2.6 detected — pinning rouge 3.30.0 first"
        gem install rouge -v 3.30.0 --no-document "${source_args[@]}" || { print_error "gem install rouge failed"; return 1; }
    fi

    if gem install "$target" --no-document "${source_args[@]}"; then
        print_success "${DISPLAY_NAME} installed successfully!"
        return 0
    fi

    print_error "gem install failed"; return 1
}

# --------------------------------------------------------------------------
# Parse CLI args
# --------------------------------------------------------------------------
parse_args() {
    for arg in "$0" "$@"; do
        case "$arg" in
            --brand-name=*) BRAND_NAME="${arg#--brand-name=}" ;;
            --command=*)    BRAND_COMMAND="${arg#--command=}"  ;;
        esac
    done
    DISPLAY_NAME="${BRAND_NAME:-OpenClacky}"
}

# --------------------------------------------------------------------------
# Brand wrapper setup
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

    assert_supported_os "Please install Ruby >= 2.6.0 manually and run: gem install openclacky"

    if [ "$OS" = "Linux" ]; then
        setup_apt_mirror
    fi

    ensure_ruby  || { print_error "Could not install a compatible Ruby"; exit 1; }
    install_via_gem && { setup_brand; show_post_install_info; exit 0; }
    print_error "Failed to install ${DISPLAY_NAME}"; exit 1
}

main "$@"
