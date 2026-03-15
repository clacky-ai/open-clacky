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

# ---------------------------------------------------------------------------
# Network pre-flight check
#
# Probes a set of URLs that the installer must reach.  For each one we record
# whether the host is reachable and how long it took.  If any critical host
# is slow (> SLOW_THRESHOLD_MS ms) or unreachable we assume the user is
# behind the Great Firewall and print mirror / proxy suggestions.
# ---------------------------------------------------------------------------
SLOW_THRESHOLD_SEC=3     # seconds — anything slower is flagged as "slow"
NETWORK_OK=true          # set to false if any critical host fails

# Probe a single URL; echoes the round-trip time in seconds, or "timeout".
_probe_url() {
    local url="$1"
    local timeout_sec=5
    local start end elapsed http_code

    start=$(date +%s)
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$timeout_sec" \
        --max-time "$timeout_sec" \
        "$url" 2>/dev/null) || true
    end=$(date +%s)
    elapsed=$(( end - start ))

    if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
        echo "timeout"
    else
        echo "$elapsed"
    fi
}

# Run the full pre-flight check and print a human-readable report.
check_network() {
    print_step "Network pre-flight check..."

    # critical = must be reachable for install to succeed
    local CRITICAL_HOSTS=(
        "https://rubygems.org"
        "https://mise.jdx.dev"
        "https://raw.githubusercontent.com"
    )

    local any_slow=false
    local any_fail=false

    for url in "${CRITICAL_HOSTS[@]}"; do
        # Map URL to a human-readable label (no associative arrays for bash 3 compat)
        local label
        case "$url" in
            *rubygems.org*)           label="RubyGems (gem install)" ;;
            *mise.jdx.dev*)           label="mise installer" ;;
            *raw.githubusercontent.com*) label="GitHub raw content" ;;
            *)                        label="$url" ;;
        esac
        local result
        result=$(_probe_url "$url")

        if [ "$result" = "timeout" ]; then
            print_warning "✗ UNREACHABLE  ${label} (${url})"
            any_fail=true
            NETWORK_OK=false
        elif [ "$result" -gt "$SLOW_THRESHOLD_SEC" ] 2>/dev/null; then
            print_warning "⚡ SLOW (${result}s)  ${label} (${url})"
            any_slow=true
            NETWORK_OK=false
        else
            print_success "✓ OK (${result}s)  ${label}"
        fi
    done

    if [ "$any_fail" = true ] || [ "$any_slow" = true ]; then
        echo ""
        print_warning "Network issues detected — you may be in mainland China or behind a firewall."
        echo ""
        echo "  ┌─ How to fix ──────────────────────────────────────────────────────────┐"
        echo "  │                                                                       │"
        echo "  │  Option 1 — Enable a VPN, then re-run this script.                  │"
        echo "  │                                                                       │"
        echo "  │  Option 2 — Set a proxy and re-run:                                  │"
        echo "  │     export https_proxy=http://127.0.0.1:7890                         │"
        echo "  │     export http_proxy=http://127.0.0.1:7890                          │"
        echo "  │     curl -fsSL https://openclacky.com/install.sh | bash              │"
        echo "  │                                                                       │"
        echo "  └───────────────────────────────────────────────────────────────────────┘"
        echo ""

        if [ "$any_fail" = true ]; then
            read -p "  Network problems found. Continue anyway? [y/N] " CONTINUE_REPLY
            CONTINUE_REPLY="${CONTINUE_REPLY:-N}"
            if [[ ! $CONTINUE_REPLY =~ ^[Yy]$ ]]; then
                echo ""
                print_info "Installation cancelled. Fix the network issues above and try again."
                exit 1
            fi
        else
            print_info "Proceeding despite slow network — installation may take longer than usual."
        fi
    else
        print_success "All network checks passed!"
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

    print_info "Installing OpenClacky gem..."
    gem install openclacky --no-document

    if [ $? -eq 0 ]; then
        print_success "OpenClacky installed successfully via gem!"
        install_agent_browser
        return 0
    else
        print_error "Gem installation failed"
        return 1
    fi
}

# Install dependencies and Ruby on macOS
install_macos_dependencies() {
    print_step "Installing macOS dependencies and Ruby..."
    echo ""

    # Install Homebrew (it will automatically install Xcode Command Line Tools if needed)
    print_info "Checking Homebrew installation..."
    if ! command_exists brew; then
        print_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        # Add Homebrew to PATH
        echo 'export PATH="/opt/homebrew/bin:$PATH"' >> ~/.zshrc
        export PATH="/opt/homebrew/bin:$PATH"

        print_success "Homebrew installed successfully"
    else
        print_success "Homebrew already installed"
    fi

    # Install build dependencies
    print_info "Installing build dependencies..."
    if brew install openssl@3 libyaml gmp rust; then
        print_success "Build dependencies installed"
    else
        print_error "Failed to install build dependencies"
        return 1
    fi

    # Install mise for Ruby version management
    # Detect current shell before configuring mise
    detect_shell

    print_info "Installing mise..."
    if ! command_exists mise; then
        if curl https://mise.run | sh; then
            # Add mise activation to the current shell's rc file
            local mise_init_line='eval "$(~/.local/bin/mise activate '"$CURRENT_SHELL"')"'
            if [ -f "$SHELL_RC" ]; then
                echo "$mise_init_line" >> "$SHELL_RC"
            else
                echo "$mise_init_line" > "$SHELL_RC"
            fi
            print_info "Added mise activation to $SHELL_RC"

            export PATH="$HOME/.local/bin:$PATH"
            eval "$(~/.local/bin/mise activate $CURRENT_SHELL)"

            print_success "mise installed successfully"
        else
            print_error "Failed to install mise"
            return 1
        fi
    else
        print_success "mise already installed"
    fi

    # Install Ruby 3 via mise
    print_info "Installing Ruby 3 via mise..."
    if ~/.local/bin/mise use -g ruby@3; then
        # Reload mise using the current shell
        eval "$(~/.local/bin/mise activate $CURRENT_SHELL)"
        print_success "Ruby 3 installed successfully"
    else
        print_error "Failed to install Ruby 3"
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

    # Install mise for Ruby version management
    print_info "Installing mise..."
    if ! command_exists mise; then
        if curl https://mise.run | sh; then
            # Add mise activation to the current shell's rc file
            local mise_init_line='eval "$(~/.local/bin/mise activate '"$CURRENT_SHELL"')"'
            if [ -f "$SHELL_RC" ]; then
                echo "$mise_init_line" >> "$SHELL_RC"
            else
                echo "$mise_init_line" > "$SHELL_RC"
            fi
            print_info "Added mise activation to $SHELL_RC"

            export PATH="$HOME/.local/bin:$PATH"
            eval "$(~/.local/bin/mise activate $CURRENT_SHELL)"

            print_success "mise installed successfully"
        else
            print_error "Failed to install mise"
            return 1
        fi
    else
        print_success "mise already installed"
    fi

    # Install Ruby 3 via mise
    print_info "Installing Ruby 3 via mise..."
    if ~/.local/bin/mise use -g ruby@3; then
        # Reload mise using the current shell
        eval "$(~/.local/bin/mise activate $CURRENT_SHELL)"
        print_success "Ruby 3 installed successfully"
    else
        print_error "Failed to install Ruby 3"
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
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
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
        echo "  OpenClacky requires a Unix-like environment. We recommend using WSL."
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
        echo "     curl -fsSL https://raw.githubusercontent.com/clacky-ai/open-clacky/main/scripts/install.sh | bash"
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
brand_name: "${BRAND_NAME}"
brand_command: "${BRAND_COMMAND}"
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
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║   🤖 OpenClacky Installation Script                      ║"
    echo "║                                                           ║"
    echo "║   AI Agent CLI with Tool Use Capabilities                ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    detect_os
    check_network

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
                print_error "Failed to install OpenClacky gem"
                exit 1
            fi
        else
            # User declined or installation failed
            print_info "Ruby installation was not completed"
            print_info "Please install Ruby manually and run: gem install openclacky"
            print_info "For more information, visit: https://github.com/clacky-ai/open-clacky"
            exit 1
        fi
    else
        print_error "Could not install OpenClacky automatically"
        echo ""
        suggest_ruby_installation
        echo ""
        print_info "For more information, visit: https://github.com/clacky-ai/open-clacky"
        exit 1
    fi
}

# Install agent-browser (browser automation tool)
# This step is optional — failures are silently skipped with a hint.
install_agent_browser() {
    print_step "Installing agent-browser (optional)..."

    # Try to find npm; if missing, attempt to install Node.js via mise
    if ! command_exists npm; then
        if command_exists mise || [ -x "$HOME/.local/bin/mise" ]; then
            print_info "Installing Node.js via mise..."
            "$HOME/.local/bin/mise" install node@22 > /dev/null 2>&1 || true
            "$HOME/.local/bin/mise" use -g node@22 > /dev/null 2>&1 || true
            # Reload mise so node/npm are on PATH
            eval "$("$HOME/.local/bin/mise" activate bash 2>/dev/null)" 2>/dev/null || true
        fi
    fi

    if ! command_exists npm; then
        print_warning "agent-browser skipped (Node.js/npm not found)."
        print_info "To enable browser automation later:"
        print_info "  mise install node@22 && mise use -g node@22 && npm install -g agent-browser"
        return 0
    fi

    if command_exists agent-browser; then
        print_success "agent-browser already installed"
        return 0
    fi

    print_info "Running: npm install -g agent-browser"
    if npm install -g agent-browser > /dev/null 2>&1; then
        print_success "agent-browser installed"
    else
        print_warning "agent-browser installation failed — skipping."
        print_info "To install manually later: npm install -g agent-browser"
    fi

    return 0
}

# Post-installation information
show_post_install_info() {
    local cmd="${BRAND_COMMAND:-openclacky}"

    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║   ✨ OpenClacky Installed Successfully!                   ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    print_step "Quick Start Guide:"
    echo ""
    print_info "1. Configure your API key:"
    echo "   $cmd"
    echo "   > /config"
    echo ""
    print_info "2. Start (Terminal / CLI mode):"
    echo "   $cmd"
    echo ""
    print_info "3. Start (Web UI mode):"
    echo "   $cmd server"
    echo "   Then open http://localhost:7070 in your browser"
    echo ""
    print_info "4. Create a new project:"
    echo "   > /new your-project-name"
    echo ""
    print_info "5. Get help:"
    echo "   > /help"
    echo ""
    print_success "Happy coding! 🚀"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "  ${RED}IMPORTANT: Please restart your terminal${NC}"
    echo ""
    echo -e "  After restarting, type: ${GREEN}$cmd${NC}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Run main installation
main "$@"
