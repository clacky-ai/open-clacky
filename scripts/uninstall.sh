#!/bin/bash
# OpenClacky Uninstallation Script
# This script removes OpenClacky from your system

set -e

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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# --------------------------------------------------------------------------
# Load brand config from ~/.clacky/brand.yml
# --------------------------------------------------------------------------
BRAND_NAME=""
BRAND_COMMAND=""
DISPLAY_NAME="OpenClacky"

load_brand() {
    local brand_file="$HOME/.clacky/brand.yml"
    if [ -f "$brand_file" ]; then
        BRAND_NAME=$(grep 'product_name:' "$brand_file" | sed 's/product_name: *"//' | sed 's/"//' | tr -d '[:space:]') || true
        BRAND_COMMAND=$(grep 'package_name:' "$brand_file" | sed 's/package_name: *"//' | sed 's/"//' | tr -d '[:space:]') || true
        [ -n "$BRAND_NAME" ] && DISPLAY_NAME="$BRAND_NAME"
    fi
}

# Check if OpenClacky is installed
check_installation() {
    if command_exists clacky || command_exists openclacky; then
        return 0
    fi
    if [ -n "$BRAND_COMMAND" ] && command_exists "$BRAND_COMMAND"; then
        return 0
    fi
    return 1
}

# Uninstall via gem
uninstall_gem() {
    if command_exists gem; then
        if gem list -i openclacky >/dev/null 2>&1; then
            print_step "Uninstalling via RubyGems..."
            gem uninstall openclacky -x
            return 0
        fi
    fi
    return 1
}

# Remove brand wrapper binary
remove_brand() {
    if [ -n "$BRAND_COMMAND" ]; then
        local clacky_bin dir
        clacky_bin=$(command -v openclacky 2>/dev/null || true)
        if [ -n "$clacky_bin" ]; then
            dir=$(dirname "$clacky_bin")
            if [ -f "$dir/$BRAND_COMMAND" ]; then
                rm -f "$dir/$BRAND_COMMAND"
                print_success "Brand wrapper removed: $dir/$BRAND_COMMAND"
            fi
        fi
    fi
}

# Restore original gemrc if we backed it up during install
restore_gemrc() {
    if [ -f "$HOME/.gemrc_clackybak" ]; then
        if [ -f "$HOME/.gemrc" ]; then
            rm -f "$HOME/.gemrc"
        fi
        mv "$HOME/.gemrc_clackybak" "$HOME/.gemrc"
        print_success "gem source restored from backup"
    fi
}

# Remove configuration files
remove_config() {
    CONFIG_DIR="$HOME/.clacky"

    if [ -d "$CONFIG_DIR" ]; then
        print_warning "Configuration directory found: $CONFIG_DIR"
        read -p "$(echo -e ${YELLOW}?${NC}) Remove configuration files (including API keys)? [y/N] " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$CONFIG_DIR"
            print_success "Configuration removed"
        else
            print_info "Configuration preserved at: $CONFIG_DIR"
        fi
    fi
}

# Main uninstallation
main() {
    load_brand

    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo -e "║   🗑️  ${DISPLAY_NAME} Uninstallation                     ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    if ! check_installation; then
        print_warning "${DISPLAY_NAME} does not appear to be installed"
        exit 0
    fi

    # Remove brand wrapper first (needs openclacky still in PATH)
    remove_brand

    # Uninstall openclacky gem
    if ! uninstall_gem; then
        print_error "Could not automatically uninstall ${DISPLAY_NAME}"
        print_info "You may need to uninstall manually:"
        echo "  gem uninstall openclacky"
        echo "  rm -rf ~/.clacky"
        exit 1
    fi

    print_success "${DISPLAY_NAME} uninstalled successfully"

    # Restore original gemrc
    restore_gemrc

    # Ask about config removal
    remove_config

    echo ""
    print_success "Uninstallation complete!"
    print_info "Thank you for using ${DISPLAY_NAME} 👋"
    echo ""
}

main
