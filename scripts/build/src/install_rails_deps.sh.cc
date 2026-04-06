#!/bin/bash
# install_rails_deps.sh — install Ruby 3.3+ and Node.js 22+ via mise, and PostgreSQL for Rails development
# Generated from scripts/build/src/install_rails_deps.sh.cc — DO NOT EDIT DIRECTLY
#
# Usage:
#   bash install_rails_deps.sh               # install ruby + node + postgres
#   bash install_rails_deps.sh ruby          # ruby only
#   bash install_rails_deps.sh node          # node only
#   bash install_rails_deps.sh postgres      # postgres only

set -e

INSTALL_TARGET="${1:-all}"  # all | ruby | node | postgres

@include lib/colors.sh
@include lib/os.sh
@include lib/shell.sh
@include lib/network.sh
@include lib/apt.sh
@include lib/brew.sh
@include lib/mise.sh
@include lib/gem.sh

# --------------------------------------------------------------------------
# Ruby: install via mise and configure gem source
# --------------------------------------------------------------------------
install_ruby() {
    print_step "Installing Ruby via mise..."

    ensure_mise || return 1
    install_ruby_via_mise || return 1

    # Configure gem source for CN users
    configure_gem_source

    # Reinstall openclacky in the new Ruby environment
    "${MISE_BIN:-mise}" exec -- gem install openclacky --no-document \
        && print_success "openclacky reinstalled" \
        || print_warning "Could not reinstall openclacky — run manually: gem install openclacky --no-document"
}

# --------------------------------------------------------------------------
# Node: install via mise and configure npm registry
# --------------------------------------------------------------------------
install_node() {
    print_step "Installing Node.js via mise..."

    ensure_mise || return 1
    install_node_via_mise || return 1

    if [ "$USE_CN_MIRRORS" = true ] && command_exists npm; then
        npm config set registry "$NPM_REGISTRY_URL" 2>/dev/null || true
        print_info "npm registry → ${NPM_REGISTRY_URL}"
    fi
}

# --------------------------------------------------------------------------
# PostgreSQL: install server + client via brew (macOS) or apt (Linux/WSL)
# --------------------------------------------------------------------------
install_postgres() {
    print_step "Installing PostgreSQL..."

    if is_macos; then
        ensure_homebrew || return 1
        brew install postgresql
        brew services start postgresql

    elif is_linux_apt; then
        setup_apt_mirror
        sudo apt-get install -y postgresql libpq-dev \
            libssl-dev libreadline-dev zlib1g-dev libyaml-dev libffi-dev
        sudo systemctl enable --now postgresql || true
    fi

    print_success "PostgreSQL installed"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║   🔧 Rails Dependencies Installer                        ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    detect_shell
    detect_network_region

    # On macOS, Homebrew is required — if missing, guide the user to install_full.sh
    if is_macos && ! command_exists brew; then
        local install_cmd
        if [ "$USE_CN_MIRRORS" = true ]; then
            install_cmd='/bin/bash -c "$(curl -sSL https://oss.1024code.com/scripts/install_full.sh)"'
        else
            install_cmd='/bin/bash -c "$(curl -sSL https://raw.githubusercontent.com/clacky-ai/openclacky/main/scripts/install_full.sh)"'
        fi
        echo ""
        print_error "Homebrew is not installed — it is required to continue."
        echo ""
        echo "  Homebrew installation requires your sudo password and interactive confirmation"
        echo "  — it cannot be run automatically by the AI agent."
        echo ""
        echo "  Please open a new terminal window and run the full installer:"
        echo ""
        echo "    ${install_cmd}"
        echo ""
        echo "  This will install Homebrew, Ruby, Node.js, and all required dependencies."
        echo "  Once done, come back and try again."
        echo ""
        exit 1
    fi

    # Run system deps script if available
    local sys_deps="$HOME/.clacky/scripts/install_system_deps.sh"
    [ -f "$sys_deps" ] && { bash "$sys_deps" || print_warning "System deps install had warnings — continuing"; }

    case "$INSTALL_TARGET" in
        ruby)     install_ruby     || exit 1 ;;
        node)     install_node     || exit 1 ;;
        postgres) install_postgres || exit 1 ;;
        *)
            install_ruby     || exit 1
            install_node     || exit 1
            install_postgres || exit 1
            ;;
    esac

    echo ""
    print_success "Done. Please re-source your shell or open a new terminal if paths changed."
    echo ""
}

main "$@"
