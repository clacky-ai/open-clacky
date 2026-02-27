#!/bin/bash
# OpenClacky Installation Script
# This script automatically detects your system and installs OpenClacky

set -e

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

    print_info "Installing OpenClacky gem..."
    gem install openclacky

    if [ $? -eq 0 ]; then
        print_success "OpenClacky installed successfully via gem!"
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
    print_info "Installing mise..."
    if ! command_exists mise; then
        if curl https://mise.run | sh; then
            # Add mise to shell
            if [ -f ~/.zshrc ]; then
                echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.zshrc
            fi
            if [ -f ~/.bash_profile ]; then
                echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bash_profile
            fi

            export PATH="$HOME/.local/bin:$PATH"
            eval "$(~/.local/bin/mise activate bash)"

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
        # Reload mise
        eval "$(~/.local/bin/mise activate bash)"
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

    # Install mise for Ruby version management
    print_info "Installing mise..."
    if ! command_exists mise; then
        if curl https://mise.run | sh; then
            # Add mise to shell
            if [ -f ~/.bashrc ]; then
                echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
            fi

            export PATH="$HOME/.local/bin:$PATH"
            eval "$(~/.local/bin/mise activate bash)"

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
        # Reload mise
        eval "$(~/.local/bin/mise activate bash)"
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
        read -p "Would you like to install Ruby and dependencies automatically? (y/n) " -n 1 -r
        echo ""
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
            read -p "Would you like to install Ruby and dependencies automatically? (y/n) " -n 1 -r
            echo ""
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

# Main installation logic
main() {
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

    # Strategy 1: Check Ruby and install via gem
    if check_ruby; then
        if install_via_gem; then
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

# Post-installation information
show_post_install_info() {
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
    echo "   openclacky"
    echo "   > /config"
    echo ""
    print_info "2. Create a new project:"
    echo "   > /new your-project-name"
    echo ""
    print_info "3. Get help:"
    echo "   > /help"
    echo ""
    print_success "Happy coding! 🚀"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "  ⚠️  ${YELLOW}IMPORTANT: Please restart your terminal${NC}"
    echo ""
    echo -e "  After restarting, type: ${GREEN}openclacky${NC}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Run main installation
main
