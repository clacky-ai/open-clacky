# network.sh — network region detection, mirror variables, URL probing
# Depends-On: colors.sh
# Requires-Vars: (none)
# Sets-Vars: $USE_CN_MIRRORS $NETWORK_REGION $CN_CDN_BASE_URL $CN_ALIYUN_MIRROR $CN_RUBYGEMS_URL $CN_NODE_MIRROR_URL $CN_NPM_REGISTRY $CN_MISE_INSTALL_URL $CN_RUBY_PRECOMPILED_URL $MISE_INSTALL_URL $NODE_MIRROR_URL $NPM_REGISTRY_URL $RUBY_VERSION_SPEC $DEFAULT_RUBYGEMS_URL $DEFAULT_MISE_INSTALL_URL $DEFAULT_NPM_REGISTRY
# Include via: @include lib/network.sh

# --------------------------------------------------------------------------
# Mirror variables — overridden by detect_network_region()
# --------------------------------------------------------------------------
SLOW_THRESHOLD_MS=5000
NETWORK_REGION="global"   # china | global | unknown
USE_CN_MIRRORS=false

GITHUB_RAW_BASE_URL="https://raw.githubusercontent.com"
DEFAULT_RUBYGEMS_URL="https://rubygems.org"
DEFAULT_NPM_REGISTRY="https://registry.npmjs.org"
DEFAULT_MISE_INSTALL_URL="https://mise.run"

CN_CDN_BASE_URL="https://oss.1024code.com"
CN_ALIYUN_MIRROR="https://mirrors.aliyun.com"
CN_MISE_INSTALL_URL="${CN_CDN_BASE_URL}/mise.sh"
CN_RUBY_PRECOMPILED_URL="${CN_CDN_BASE_URL}/ruby/ruby-{version}.{platform}.tar.gz"
CN_RUBYGEMS_URL="${CN_ALIYUN_MIRROR}/rubygems/"
CN_NPM_REGISTRY="https://registry.npmmirror.com"
CN_NODE_MIRROR_URL="https://cdn.npmmirror.com/binaries/node/"
CN_GEM_BASE_URL="${CN_CDN_BASE_URL}/openclacky"
CN_GEM_LATEST_URL="${CN_GEM_BASE_URL}/latest.txt"

# Active values (set by detect_network_region)
MISE_INSTALL_URL="$DEFAULT_MISE_INSTALL_URL"
RUBYGEMS_INSTALL_URL="$DEFAULT_RUBYGEMS_URL"
NPM_REGISTRY_URL="$DEFAULT_NPM_REGISTRY"
NODE_MIRROR_URL=""          # empty = mise default (nodejs.org)
RUBY_VERSION_SPEC="ruby@3"  # CN mode pins to a specific precompiled build

# --------------------------------------------------------------------------
# Internal probe helpers
# --------------------------------------------------------------------------

# Probe a single URL; echoes round-trip time in ms, or "timeout"
_probe_url() {
    local url="$1"
    local out http_code total_time
    out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
        --connect-timeout 5 --max-time 5 "$url" 2>/dev/null) || true
    http_code="${out%% *}"
    total_time="${out#* }"
    if [ -z "$http_code" ] || [ "$http_code" = "000" ] || [ "$http_code" = "$out" ]; then
        echo "timeout"; return
    fi
    awk -v s="$total_time" 'BEGIN { printf "%d", s * 1000 }'
}

# Returns 0 (true) if result is slow or unreachable
_is_slow_or_unreachable() {
    local r="$1"
    [ "$r" = "timeout" ] && return 0
    [ "${r:-9999}" -ge "$SLOW_THRESHOLD_MS" ] 2>/dev/null
}

_format_probe_time() {
    local r="$1"
    [ "$r" = "timeout" ] && echo "timeout" && return
    awk -v ms="$r" 'BEGIN { printf "%.1fs", ms / 1000 }'
}

_print_probe_result() {
    local label="$1" result="$2"
    if [ "$result" = "timeout" ]; then
        print_warning "UNREACHABLE  ${label}"
    elif _is_slow_or_unreachable "$result"; then
        print_warning "SLOW ($(_format_probe_time "$result"))  ${label}"
    else
        print_success "OK ($(_format_probe_time "$result"))  ${label}"
    fi
}

# Probe URL up to max_retries times; returns first fast result or last result
_probe_url_with_retry() {
    local url="$1" max="${2:-2}" result
    for _ in $(seq 1 "$max"); do
        result=$(_probe_url "$url")
        ! _is_slow_or_unreachable "$result" && { echo "$result"; return 0; }
    done
    echo "$result"
}

# --------------------------------------------------------------------------
# detect_network_region — sets USE_CN_MIRRORS and active mirror variables
# --------------------------------------------------------------------------
detect_network_region() {
    print_step "Network pre-flight check..."
    echo ""

    local google_result baidu_result
    google_result=$(_probe_url "https://www.google.com")
    baidu_result=$(_probe_url "https://www.baidu.com")

    _print_probe_result "google.com" "$google_result"
    _print_probe_result "baidu.com"  "$baidu_result"

    local google_ok=false baidu_ok=false
    ! _is_slow_or_unreachable "$google_result" && google_ok=true
    ! _is_slow_or_unreachable "$baidu_result"  && baidu_ok=true

    if [ "$google_ok" = true ]; then
        NETWORK_REGION="global"
        print_success "Region: global"
    elif [ "$baidu_ok" = true ]; then
        NETWORK_REGION="china"
        print_success "Region: china"
    else
        NETWORK_REGION="unknown"
        print_warning "Region: unknown (both unreachable)"
    fi
    echo ""

    if [ "$NETWORK_REGION" = "china" ]; then
        local cdn_result mirror_result
        cdn_result=$(_probe_url_with_retry "$CN_MISE_INSTALL_URL")
        mirror_result=$(_probe_url_with_retry "$CN_RUBYGEMS_URL")

        _print_probe_result "CN CDN (mise/Ruby)" "$cdn_result"
        _print_probe_result "Aliyun (gem)"       "$mirror_result"

        local cdn_ok=false mirror_ok=false
        ! _is_slow_or_unreachable "$cdn_result"    && cdn_ok=true
        ! _is_slow_or_unreachable "$mirror_result" && mirror_ok=true

        if [ "$cdn_ok" = true ] || [ "$mirror_ok" = true ]; then
            USE_CN_MIRRORS=true
            MISE_INSTALL_URL="$CN_MISE_INSTALL_URL"
            RUBYGEMS_INSTALL_URL="$CN_RUBYGEMS_URL"
            NPM_REGISTRY_URL="$CN_NPM_REGISTRY"
            NODE_MIRROR_URL="$CN_NODE_MIRROR_URL"
            RUBY_VERSION_SPEC="ruby@3.4.8"
            print_info "CN mirrors applied"
        else
            print_warning "CN mirrors unreachable — falling back to global sources"
        fi
    else
        local rubygems_result mise_result
        rubygems_result=$(_probe_url_with_retry "$DEFAULT_RUBYGEMS_URL")
        mise_result=$(_probe_url_with_retry "$DEFAULT_MISE_INSTALL_URL")

        _print_probe_result "RubyGems" "$rubygems_result"
        _print_probe_result "mise.run" "$mise_result"

        _is_slow_or_unreachable "$rubygems_result" && print_warning "RubyGems is slow/unreachable."
        _is_slow_or_unreachable "$mise_result"     && print_warning "mise.run is slow/unreachable."

        USE_CN_MIRRORS=false
        RUBY_VERSION_SPEC="ruby@3"
    fi

    echo ""
}
