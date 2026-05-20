# apt.sh — apt package manager helpers (Ubuntu/Debian)
# Depends-On: colors.sh network.sh
# Requires-Vars: $DISTRO $USE_CN_MIRRORS $CN_ALIYUN_MIRROR
# Sets-Vars: (none)
# Include via: @include lib/apt.sh

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
