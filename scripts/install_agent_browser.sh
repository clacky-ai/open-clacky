#!/bin/bash
# Install or upgrade agent-browser (browser automation tool)
# Can be sourced by install.sh or run standalone (e.g. from Ruby via shell)
#
# Exit codes:
#   0 — success (installed/upgraded)
#   1 — failure (npm not found or install failed)

set -e

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

command_exists() { command -v "$1" >/dev/null 2>&1; }

print_step "Installing agent-browser..."

# Try to find npm; if missing, attempt to install Node.js via mise
if ! command_exists npm; then
    mise_bin=""
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
    print_error "agent-browser installation failed: Node.js/npm not found."
    print_info "Please run: mise install node@22 && mise use -g node@22 && npm install -g agent-browser"
    exit 1
fi

print_info "Running: npm install -g agent-browser"
if npm install -g agent-browser > /dev/null 2>&1; then
    version=$(agent-browser --version 2>/dev/null | awk '{print $NF}')
    print_success "agent-browser ${version} installed/updated"
else
    print_error "agent-browser installation failed."
    print_info "To install manually: npm install -g agent-browser"
    exit 1
fi

print_info "Installing Playwright Chromium..."
if npx playwright install chromium > /dev/null 2>&1; then
    print_success "Playwright Chromium installed"
else
    print_error "Playwright Chromium installation failed."
    print_info "To install manually: npx playwright install chromium"
    exit 1
fi
