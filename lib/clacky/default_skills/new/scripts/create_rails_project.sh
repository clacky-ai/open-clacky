#!/bin/bash
# Create Rails Project Script
# This script creates a new Rails 7.x project from the rails-template-7x-starter template
# Run this script in an empty directory

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

# Check if current directory is empty
check_current_directory() {
    print_step "Checking current directory..."

    local current_dir=$(pwd)
    print_info "Working in: $current_dir"

    # Check if directory is empty (silently continue if not)
    if [ "$(ls -A .)" ]; then
        print_warning "Current directory is not empty - continuing anyway"
    else
        print_success "Current directory is empty"
    fi
}

# Clone template to current directory
clone_template() {
    print_step "Cloning Rails template..."

    # Create temporary directory
    local temp_dir=$(mktemp -d)
    print_info "Using temporary directory: $temp_dir"

    # Clone template to temp directory
    print_info "Downloading template from GitHub..."
    if git clone https://github.com/clacky-ai/rails-template-7x-starter.git "$temp_dir" >/dev/null 2>&1; then
        print_success "Template cloned successfully"
    else
        print_error "Failed to clone template"
        rm -rf "$temp_dir"
        exit 1
    fi

    # Move all files to current directory
    print_info "Moving files to current directory..."
    mv "$temp_dir"/* "$temp_dir"/.* . 2>/dev/null || true

    # Delete .git directory
    rm -rf .git

    # Clean up temp directory
    rm -rf "$temp_dir"
    print_success "Template files copied to current directory"

    # Initialize new git repository
    print_info "Initializing git repository..."
    git init > /dev/null 2>&1
    git add . > /dev/null 2>&1
    git commit -m "Initial commit from rails-template-7x-starter" > /dev/null 2>&1
    print_success "Git repository initialized"
}

# Add x86_64-linux platform to Gemfile.lock for Railway deployment
# Railway always builds on x86_64-linux; local dev (macOS/Windows) may not include it.
prepare_linux_platform() {
    print_step "Preparing Gemfile.lock for Linux deployment (Railway)..."

    if [ ! -f "Gemfile.lock" ]; then
        print_warning "Gemfile.lock not found yet — skipping platform prep (will be handled at deploy time)"
        return 0
    fi

    # Idempotent: skip if already present
    if grep -q "x86_64-linux" Gemfile.lock; then
        print_success "x86_64-linux platform already present in Gemfile.lock"
        return 0
    fi

    if command -v bundle > /dev/null 2>&1; then
        if bundle lock --add-platform x86_64-linux > /dev/null 2>&1; then
            git add Gemfile.lock > /dev/null 2>&1
            git commit -m "chore: add x86_64-linux platform for Railway deployment" > /dev/null 2>&1
            print_success "Added x86_64-linux platform to Gemfile.lock"
        else
            print_warning "Could not add Linux platform to Gemfile.lock (will be handled at deploy time)"
        fi
    else
        print_warning "bundler not found — skipping platform prep (will be handled at deploy time)"
    fi
}

# Check and install environment dependencies
check_environment() {
    print_step "Checking environment dependencies..."

    local installer="$HOME/.clacky/scripts/install_rails_deps.sh"
    if [ ! -f "$installer" ]; then
        print_warning "install_rails_deps.sh not found at $installer"
        print_info "Please ensure Ruby 3.3+, Node.js 22+, and PostgreSQL are installed"
        return 1
    fi

    if bash "$installer"; then
        print_success "Environment ready"
        return 0
    else
        print_error "Environment setup failed"
        return 1
    fi
}

# Run project setup
run_project_setup() {
    print_step "Running project setup..."

    if [ ! -f "./bin/setup" ]; then
        print_error "bin/setup not found"
        return 1
    fi

    chmod +x ./bin/setup

    if ./bin/setup; then
        print_success "Project setup completed"
        return 0
    else
        print_error "Project setup failed"
        return 1
    fi
}

# Main function
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║   🚀 Rails 7.x Project Creator                           ║"
    echo "║                                                           ║"
    echo "║   Creating your new Rails project...                     ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    # Check current directory
    check_current_directory

    # Clone template
    if ! clone_template; then
        exit 1
    fi

    # Check environment
    if ! check_environment; then
        print_error "Please fix environment issues and run ./bin/setup manually"
        exit 1
    fi

    # Run project setup
    if ! run_project_setup; then
        print_error "Setup failed. You can try running './bin/setup' manually"
        exit 1
    fi

    # Prepare Gemfile.lock for Railway Linux deployment (idempotent)
    prepare_linux_platform

    # Project is ready
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║   ✨ Project Setup Complete!                             ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    print_success "Rails project created and configured successfully"
    echo ""
}

# Run main
main
