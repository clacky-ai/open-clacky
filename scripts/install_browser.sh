#!/bin/bash
# Install Node.js (via mise) and chrome-devtools-mcp for browser automation.
# This script is copied to ~/.clacky/scripts/ on first run and invoked by
# the browser-setup skill when chrome-devtools-mcp is not yet installed.

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

# --------------------------------------------------------------------------
# Network region detection (quick — only probes google + baidu)
# --------------------------------------------------------------------------
SLOW_THRESHOLD_MS=5000
USE_CN_MIRRORS=false
DEFAULT_NPM_REGISTRY="https://registry.npmjs.org"
CN_NPM_REGISTRY="https://registry.npmmirror.com"
CN_NODE_MIRROR_URL="https://cdn.npmmirror.com/binaries/node/"
DEFAULT_MISE_INSTALL_URL="https://mise.run"
CN_MISE_INSTALL_URL="https://oss.1024code.com/mise.sh"
MISE_INSTALL_URL="$DEFAULT_MISE_INSTALL_URL"
NPM_REGISTRY_URL="$DEFAULT_NPM_REGISTRY"
NODE_MIRROR_URL=""

_probe_url() {
    local url="$1"
    local out
    out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
        --connect-timeout 5 --max-time 5 "$url" 2>/dev/null) || true
    local http_code="${out%% *}"
    local total_time="${out#* }"
    if [ -z "$http_code" ] || [ "$http_code" = "000" ] || [ "$http_code" = "$out" ]; then
        echo "timeout"; return
    fi
    awk -v s="$total_time" 'BEGIN { printf "%d", s * 1000 }'
}

_is_slow() {
    local r="$1"
    [ "$r" = "timeout" ] && return 0
    [ "$r" -ge "$SLOW_THRESHOLD_MS" ] 2>/dev/null
}

detect_network_region() {
    print_step "Detecting network region..."
    local google baidu
    google=$(_probe_url "https://www.google.com")
    baidu=$(_probe_url "https://www.baidu.com")

    if ! _is_slow "$google"; then
        print_info "Region: global"
    elif ! _is_slow "$baidu"; then
        print_info "Region: china — switching to CN mirrors"
        USE_CN_MIRRORS=true
        MISE_INSTALL_URL="$CN_MISE_INSTALL_URL"
        NPM_REGISTRY_URL="$CN_NPM_REGISTRY"
        NODE_MIRROR_URL="$CN_NODE_MIRROR_URL"
    else
        print_warning "Region: unknown — using global defaults"
    fi
}

# --------------------------------------------------------------------------
# Ensure mise is available
# --------------------------------------------------------------------------
_mise_bin() {
    if command_exists mise; then echo "mise"
    elif [ -x "$HOME/.local/bin/mise" ]; then echo "$HOME/.local/bin/mise"
    else echo ""
    fi
}

ensure_mise() {
    local mise
    mise=$(_mise_bin)
    if [ -n "$mise" ]; then
        print_success "mise already installed"
        export PATH="$HOME/.local/bin:$PATH"
        eval "$("$mise" activate bash 2>/dev/null)" 2>/dev/null || true
        return 0
    fi

    print_info "Installing mise..."
    if curl -fsSL "$MISE_INSTALL_URL" | sh; then
        export PATH="$HOME/.local/bin:$PATH"
        eval "$(~/.local/bin/mise activate bash 2>/dev/null)" 2>/dev/null || true
        print_success "mise installed"
    else
        print_warning "mise install failed — will rely on system Node if available"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Ensure Node.js >= 20 via mise
# --------------------------------------------------------------------------
ensure_node() {
    print_step "Checking Node.js..."

    # Already have a good node?
    if command_exists node; then
        local ver
        ver=$(node --version 2>/dev/null | sed 's/v//')
        local major="${ver%%.*}"
        if [ "${major:-0}" -ge 20 ] 2>/dev/null; then
            print_success "Node.js v${ver} — OK"
            return 0
        else
            print_warning "Node.js v${ver} is too old (need >=20), will install via mise"
        fi
    fi

    # Install via mise
    if ! ensure_mise; then
        print_error "Cannot install Node.js: mise unavailable and no suitable node found"
        return 1
    fi

    local mise
    mise=$(_mise_bin)

    if [ "$USE_CN_MIRRORS" = true ] && [ -n "$NODE_MIRROR_URL" ]; then
        "$mise" settings node.mirror_url="$NODE_MIRROR_URL" 2>/dev/null || true
        print_info "Node mirror → ${NODE_MIRROR_URL}"
    fi

    print_info "Installing Node.js 22 via mise..."
    "$mise" install node@22 >/dev/null 2>&1 || true
    "$mise" use -g node@22 >/dev/null 2>&1 || true
    eval "$("$mise" activate bash 2>/dev/null)" 2>/dev/null || true

    if command_exists node; then
        print_success "Node.js $(node --version) installed"
    else
        print_error "Node.js installation failed"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Install / update chrome-devtools-mcp
# --------------------------------------------------------------------------
install_chrome_devtools_mcp() {
    print_step "Installing chrome-devtools-mcp..."

    # Set npm registry
    if [ "$USE_CN_MIRRORS" = true ]; then
        npm config set registry "$NPM_REGISTRY_URL" 2>/dev/null || true
        print_info "npm registry → ${NPM_REGISTRY_URL}"
    fi

    if npm install -g chrome-devtools-mcp@latest 2>/dev/null; then
        print_success "chrome-devtools-mcp $(chrome-devtools-mcp --version 2>/dev/null) installed"
    else
        print_error "chrome-devtools-mcp installation failed"
        print_info "Try manually: npm install -g chrome-devtools-mcp@latest"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    echo ""
    echo "Browser Automation Setup"
    echo "========================"

    detect_network_region
    ensure_node   || exit 1
    install_chrome_devtools_mcp || exit 1

    echo ""
    print_success "Done. Browser automation is ready."
    echo ""
}

main "$@"
