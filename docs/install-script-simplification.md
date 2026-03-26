# Install Script Simplification Plan

## Background

We now support Ruby >= 2.6.0 (down from 3.1.0). This opens the door to significantly
simplifying the install script by leveraging the system Ruby that ships with older macOS versions.

## Current Flow (Heavy)

```
install.sh
  → detect_network_region
  → install_macos_dependencies
      → Homebrew (+ openssl@3, libyaml, gmp build deps)
      → mise (Ruby version manager)
      → Ruby 3 (via mise)
      → Node 22 (via mise, for chrome-devtools-mcp)
  → gem install openclacky
  → install_chrome_devtools_mcp (npm install -g)
```

## Target Flow (Simplified)

```
check_ruby >= 2.6?
  ├── YES → gem install openclacky ✅  (done, zero extra deps)
  └── NO  → check CLT exists (xcode-select -p)
              ├── YES → mise install ruby → gem install ✅
              └── NO  → print clear instructions, exit:
                          Option 1: xcode-select --install  (then re-run installer)
                          Option 2: brew install ruby        (if brew already exists)
```

## Key Decisions

### Ruby version threshold: 3.1 → 2.6
- macOS 10.15 Catalina: Ruby 2.6.3 ✅
- macOS 11 Big Sur: Ruby 2.6.8 ✅
- macOS 12+ Monterey and above: no system Ruby (Apple removed it)

### Homebrew: removed from happy path
- Only Homebrew's build deps (openssl@3, libyaml, gmp) were needed to compile Ruby via mise
- If system Ruby exists, none of these are needed
- Homebrew itself is NOT installed by the script anymore

### mise: fallback only
- Only invoked when system Ruby is absent (macOS 12+)
- Requires Xcode CLT to be present first (for compiling Ruby)
- No longer used to install Node

### Node / chrome-devtools-mcp: removed from install.sh
- Browser automation is an optional feature
- Move Node installation guidance into the `browser-setup` skill
- `clacky browser setup` handles Node + chrome-devtools-mcp installation

## Xcode CLT Handling (Deferred)

Brew uses a clever trick to install CLT silently (no GUI popup):

```bash
# Creates a placeholder file that triggers softwareupdate to list CLT
touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

# Find the CLT package label
clt_label=$(softwareupdate -l | grep "Command Line Tools" | ...)

# Silent install — no GUI!
sudo softwareupdate -i "${clt_label}"
```

However this still requires `sudo` (root password). Given that:
- macOS 12+ users who lack CLT are rare (any git/Xcode/Homebrew usage installs it)
- Silent CLT install downloads hundreds of MB

The current plan is to **not auto-install CLT**, and instead print clear instructions
asking the user to run `xcode-select --install` and re-run the installer.

We can revisit adopting Homebrew's `softwareupdate` approach in the future if
the "no CLT" case proves common enough.

## Files to Change

| File | Change |
|------|--------|
| `scripts/install.sh` | Ruby threshold 3.1 → 2.6; remove Homebrew install; remove Node/npm install; simplify macOS deps function |
| `README.md` | Ruby badge and requirements: >= 3.1.0 → >= 2.6.0 |
| `docs/HOW-TO-USE.md` | Requirements: Ruby >= 3.1 → >= 2.6 |
| `docs/HOW-TO-USE-CN.md` | Same as above |
| `homebrew/openclacky.rb` | `depends_on "ruby@3.3"` → remove or update |
