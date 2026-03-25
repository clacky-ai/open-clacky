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
SLOW_THRESHOLD_MS=2500
NETWORK_REGION="global"
USE_CN_MIRRORS=false
DEFAULT_RUBYGEMS_URL="https://rubygems.org"
GITHUB_RAW_BASE_URL="https://raw.githubusercontent.com"
HOMEBREW_INSTALL_SCRIPT_URL="${GITHUB_RAW_BASE_URL}/Homebrew/install/HEAD/install.sh"
OPENCLACKY_INSTALL_SCRIPT_URL="${GITHUB_RAW_BASE_URL}/clacky-ai/openclacky/main/scripts/install.sh"
TUNA_MIRROR_BASE_URL="https://mirrors.tuna.tsinghua.edu.cn"
CN_CDN_BASE_URL="https://oss.1024code.com"
DEFAULT_MISE_INSTALL_URL="https://mise.run"
CN_MISE_INSTALL_URL="${CN_CDN_BASE_URL}/mise.sh"
CN_RUBY_PRECOMPILED_URL="${CN_CDN_BASE_URL}/ruby/ruby-{version}.{platform}.tar.gz"
MISE_INSTALL_URL="$DEFAULT_MISE_INSTALL_URL"
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

detect_network_region() {
    print_step "Network pre-flight check..."

    local tuna_result cdn_result mise_result rubygems_result github_result
    local tuna_good=false
    local cdn_good=false
    local upstream_good=false

    tuna_result=$(_probe_url "$TUNA_MIRROR_BASE_URL")
    cdn_result=$(_probe_url "$CN_MISE_INSTALL_URL")
    mise_result=$(_probe_url "$DEFAULT_MISE_INSTALL_URL")
    rubygems_result=$(_probe_url "$DEFAULT_RUBYGEMS_URL")
    github_result=$(_probe_url "$GITHUB_RAW_BASE_URL")

    _print_probe_result "Tsinghua mirror" "$tuna_result"
    _print_probe_result "Clacky CDN" "$cdn_result"
    _print_probe_result "mise installer" "$mise_result"
    _print_probe_result "RubyGems" "$rubygems_result"
    _print_probe_result "GitHub raw content" "$github_result"

    if ! _is_slow_or_unreachable "$tuna_result"; then
        tuna_good=true
    fi

    if ! _is_slow_or_unreachable "$cdn_result"; then
        cdn_good=true
    fi

    # "global" here means strategy fallback, not guaranteed global reachability.
    # Treat upstream as healthy if at least one core endpoint is reachable and fast enough.
    if ! _is_slow_or_unreachable "$mise_result" || \
       ! _is_slow_or_unreachable "$rubygems_result" || \
       ! _is_slow_or_unreachable "$github_result"; then
        upstream_good=true
    fi

    if [ "$tuna_good" = true ] && [ "$cdn_good" = true ]; then
        NETWORK_REGION="china"
        USE_CN_MIRRORS=true
        MISE_INSTALL_URL="$CN_MISE_INSTALL_URL"
        RUBY_VERSION_SPEC="ruby@3.4.8"
        print_info "Using optimized installation sources for this network environment."
    else
        NETWORK_REGION="global"
        USE_CN_MIRRORS=false
        MISE_INSTALL_URL="$DEFAULT_MISE_INSTALL_URL"
        RUBY_VERSION_SPEC="ruby@3"
        print_info "Detected global network. Using default upstream sources."
    fi

    if [ "$tuna_good" = false ] || [ "$cdn_good" = false ]; then
        print_warning "Domestic mirrors are unavailable or too slow. Falling back to default upstream sources."
    fi

    if [ "$upstream_good" = false ]; then
        print_warning "Default upstream sources are also unreachable or too slow. Installation may fail; check your network, proxy, or VPN settings."
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
}

install_ruby_via_mise() {
    print_info "Installing Ruby 3 via mise..."

    if [ "$USE_CN_MIRRORS" = true ]; then
        ~/.local/bin/mise settings ruby.compile=false
        ~/.local/bin/mise settings ruby.precompiled_url="$CN_RUBY_PRECOMPILED_URL"
    else
        ~/.local/bin/mise settings unset ruby.compile >/dev/null 2>&1 || true
        ~/.local/bin/mise settings unset ruby.precompiled_url >/dev/null 2>&1 || true
    fi

    if ~/.local/bin/mise use -g "$RUBY_VERSION_SPEC"; then
        # Reload mise in the current bash process
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

    if [ "$USE_CN_MIRRORS" = true ]; then
        print_info "Detected mainland/restricted network on macOS"
        print_info "Skipping Homebrew and build dependencies because Ruby will be installed from precompiled binaries"
    else
        # Install Homebrew (it will automatically install Xcode Command Line Tools if needed)
        print_info "Checking Homebrew installation..."
        if ! command_exists brew; then
            print_info "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL "$HOMEBREW_INSTALL_SCRIPT_URL")"

            # Add Homebrew to PATH
            echo 'export PATH="/opt/homebrew/bin:$PATH"' >> ~/.zshrc
            export PATH="/opt/homebrew/bin:$PATH"

            print_success "Homebrew installed successfully"
        else
            print_success "Homebrew already installed"
        fi

        # Install build dependencies for the default upstream Ruby toolchain path
        print_info "Installing build dependencies..."
        if brew install openssl@3 libyaml gmp rust; then
            print_success "Build dependencies installed"
        else
            print_error "Failed to install build dependencies"
            return 1
        fi
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
        print_info "Configuring apt mirror (Tsinghua)..."
        local codename="${VERSION_CODENAME:-jammy}"
        local mirror_base="${TUNA_MIRROR_BASE_URL}/ubuntu/"
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
    if sudo apt install -y build-essential rustc libssl-dev libyaml-dev zlib1g-dev libgmp-dev git; then
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
suggest_ruby_installation() {
    print_step "Ruby Installation Options"
    echo ""

    if [ "$OS" = "macOS" ]; then
        print_info "Automatic Installation (Recommended)"
        echo "  This script can automatically install Ruby and dependencies for you."
        echo "  Uses mise - a fast, polyglot tool version manager."
        echo ""
        read -p "Would you like to install Ruby and dependencies automatically? [Y/n] " REPLY
        echo ""
        REPLY="${REPLY:-Y}"
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            install_macos_dependencies
            return $?
        fi
        echo ""
        print_info "Manual Installation with mise:"
        echo "  # Install Homebrew (it will install Xcode Command Line Tools automatically)"
        echo "  /bin/bash -c \"\$(curl -fsSL ${HOMEBREW_INSTALL_SCRIPT_URL})\""
        echo ""
        echo "  # Install dependencies"
        echo "  brew install openssl@3 libyaml gmp rust"
        echo ""
        echo "  # Install mise"
        echo "  curl https://mise.run | sh"
        echo "  echo 'eval \"\$(~/.local/bin/mise activate bash)\"' >> ~/.zshrc"
        echo ""
        echo "  # Install Ruby 3"
        echo "  mise use -g ruby@3"

    elif [ "$OS" = "Linux" ]; then
        if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
            print_info "Automatic Installation (Recommended)"
            echo "  This script can automatically install Ruby and dependencies for you."
            echo "  Uses mise - a fast, polyglot tool version manager."
            echo ""
            read -p "Would you like to install Ruby and dependencies automatically? [Y/n] " REPLY
            echo ""
            REPLY="${REPLY:-Y}"
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                install_ubuntu_dependencies
                return $?
            fi
            echo ""
            print_info "Manual Installation with mise (Ubuntu/Debian):"
            echo "  # Update and install dependencies"
            echo "  sudo apt update"
            echo "  sudo apt install -y build-essential rustc libssl-dev libyaml-dev zlib1g-dev libgmp-dev git"
            echo ""
            echo "  # Install mise"
            echo "  curl https://mise.run | sh"
            echo "  echo 'eval \"\$(~/.local/bin/mise activate bash)\"' >> ~/.bashrc"
            echo ""
            echo "  # Install Ruby 3"
            echo "  mise use -g ruby@3"
        else
            print_info "Manual Installation with mise (Other Linux):"
            echo "  # Install build dependencies (adjust for your distribution)"
            echo "  # Fedora/RHEL:"
            echo "  sudo dnf install -y gcc make openssl-devel libyaml-devel zlib-devel gmp-devel git rust"
            echo ""
            echo "  # Install mise"
            echo "  curl https://mise.run | sh"
            echo "  echo 'eval \"\$(~/.local/bin/mise activate bash)\"' >> ~/.bashrc"
            echo ""
            echo "  # Install Ruby 3"
            echo "  mise use -g ruby@3"
        fi

    elif [ "$OS" = "Windows" ]; then
        print_info "Windows Subsystem for Linux (WSL) Installation (Recommended)"
        echo "  ${DISPLAY_NAME} requires a Unix-like environment. We recommend using WSL."
        echo ""
        echo "  1. Open PowerShell or Windows Command Prompt in administrator mode"
        echo "  2. Install WSL with Ubuntu 24.04:"
        echo ""
        echo "     wsl --install --distribution Ubuntu-24.04"
        echo ""
        echo "  3. Restart your computer if prompted"
        echo "  4. Launch Ubuntu from the Start menu"
        echo "  5. Run this installation script again inside Ubuntu:"
        echo ""
        echo "     curl -fsSL ${OPENCLACKY_INSTALL_SCRIPT_URL} | bash"
        echo ""
        print_info "Learn more about WSL: https://learn.microsoft.com/en-us/windows/wsl/install"
    fi

    echo ""
    print_info "After installing Ruby, run this script again or use:"
    echo "  gem install openclacky"
    echo ""
    print_info "Learn more about mise: https://mise.jdx.dev"
}

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

    echo ""
    echo "${DISPLAY_NAME} Installation"
    echo ""

    detect_os
    detect_shell
    detect_network_region

    # Strategy 1: Check Ruby and install via gem
    if check_ruby; then
        if install_via_gem; then
            setup_brand
            show_post_install_info
            exit 0
        fi
    fi

    # Strategy 2: Install Ruby on macOS/Ubuntu or suggest options
    if [ "$OS" = "macOS" ] || [ "$OS" = "Linux" ]; then
        print_warning "Ruby not found or version too old"
        echo ""
        if suggest_ruby_installation; then
            # Try installing via gem after Ruby installation
            if install_via_gem; then
                setup_brand
                show_post_install_info
                exit 0
            else
                print_error "Failed to install ${DISPLAY_NAME}"
                exit 1
            fi
        else
            # User declined or installation failed
            print_info "Ruby installation was not completed"
            print_info "Please install Ruby manually and run: gem install openclacky"
            print_info "For more information, visit: https://github.com/clacky-ai/openclacky"
            exit 1
        fi
    else
        print_error "Could not install ${DISPLAY_NAME} automatically"
        echo ""
        suggest_ruby_installation
        echo ""
        print_info "For more information, visit: https://github.com/clacky-ai/openclacky"
        exit 1
    fi
}

# Install agent-browser (browser automation tool)
# This step is optional — failures are silently skipped with a hint.
install_chrome_devtools_mcp() {
    print_step "Installing chrome-devtools-mcp..."

    # 尝试找到 npm；如果没有，通过 mise 安装 Node.js
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
