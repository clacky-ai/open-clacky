#!/bin/bash
# install_system_deps.sh — install system-level build tools
# Generated from scripts/build/src/install_system_deps.sh.cc — DO NOT EDIT DIRECTLY
#
# macOS : Xcode Command Line Tools + Homebrew
# Linux : build-essential + python3 + git + curl (apt, Ubuntu/Debian)

set -e

@include lib/colors.sh
@include lib/os.sh
@include lib/shell.sh
@include lib/network.sh
@include lib/apt.sh
@include lib/brew.sh
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
    print_step "Installing Linux build dependencies..."

    detect_network_region
    setup_apt_mirror
    sudo apt-get install -y build-essential git curl python3
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
